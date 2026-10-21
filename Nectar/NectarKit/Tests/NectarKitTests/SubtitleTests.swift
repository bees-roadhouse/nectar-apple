import Foundation
import Testing
@testable import NectarKit

/// Answers by path and keeps every request.
private actor PathTransport: HTTPTransport {

    private let answers: [String: (Int, String)]
    private(set) var requests: [URLRequest] = []

    init(_ answers: [String: (Int, String)]) {
        self.answers = answers
    }

    nonisolated func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        try await answer(request)
    }

    private func answer(_ request: URLRequest) throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        guard let (status, body) = answers[request.url!.path] else { throw URLError(.fileDoesNotExist) }
        return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }
}

private func session(_ transport: PathTransport) -> NectarSession {
    NectarSession(
        baseURL: URL(string: "https://nectar.test")!,
        tokenEndpoint: URL(string: "https://nectar.test/token")!,
        clientID: "nectar-tv",
        store: InMemoryTokenStore(TokenSet(accessToken: "jwt-1", tokenType: "Bearer", expiresIn: nil, refreshToken: "r1")),
        transport: transport
    )
}

private func json(_ data: Data?) throws -> [String: Any] {
    let data = try #require(data)
    return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
}

/// Shaped as nectar's routes/subtitles.ts lists them: an external file, an embedded text track, an
/// embedded PGS track (no `url`: it can only be burned in), and a kind nectar may add later.
private let list = #"""
{"subtitles":[
 {"id":"5b6e1c2a-0d3f-4f7e-9a51-0c8d2e3f4a5b","kind":"external","language":"en","format":"srt","source":"file",
  "label":"English","is_default":false,"is_forced":false,"can_sidecar":true,"can_burn":true,
  "url":"/api/v1/media/f2d8/subtitles/5b6e1c2a-0d3f-4f7e-9a51-0c8d2e3f4a5b"},
 {"id":"embedded-3","kind":"embedded","stream_index":3,"language":"en","format":"subrip","source":"embedded",
  "label":"English (Forced)","is_default":false,"is_forced":true,"can_sidecar":true,"can_burn":true,
  "url":"/api/v1/media/f2d8/subtitles/embedded/3"},
 {"id":"embedded-4","kind":"embedded","stream_index":4,"language":"","format":"hdmv_pgs_subtitle","source":"embedded",
  "label":"Track 4","is_default":true,"is_forced":false,"can_sidecar":false,"can_burn":true},
 {"id":"x1","kind":"translated","language":"fr","format":"vtt","source":"ai","label":"French",
  "is_default":false,"is_forced":false,"can_sidecar":true,"can_burn":true,"url":"/api/v1/media/f2d8/subtitles/x1"}
]}
"""#

private let decideAnswer = #"""
{"strategy":"hls","stream_url":"/api/v1/streaming/f2d8/hls/copy-a2-acopy/stream.m3u8","play_method":"DirectStream",
 "reason":"subtitle_burn","selected":{"quality":"original","subtitle_stream_index":4},
 "duration_seconds":3420,"start_offset_seconds":0,
 "subtitle_default":{"stream_index":3,"reason":"forced"}}
"""#

@Suite("Subtitles")
struct SubtitleTests {

    @Test func decodesEveryTrackTheTitleCarriesOrSitsBeside() async throws {
        let transport = PathTransport(["/api/v1/media/f2d8/subtitles": (200, list)])
        let tracks = try await session(transport).subtitles("f2d8")

        #expect(tracks.map(\.id) == ["5b6e1c2a-0d3f-4f7e-9a51-0c8d2e3f4a5b", "embedded-3", "embedded-4", "x1"])
        #expect(tracks[0].kind == .external && tracks[0].streamIndex == nil && tracks[0].label == "English")
        #expect(tracks[1].kind == .embedded && tracks[1].streamIndex == 3 && tracks[1].isForced)
        #expect(tracks[1].path == "/api/v1/media/f2d8/subtitles/embedded/3")
        #expect(tracks[3].kind == .other("translated"), "a kind nectar adds later still decodes")
    }

    @Test func anImageTrackCanOnlyBeBurnedIn() async throws {
        let transport = PathTransport(["/api/v1/media/f2d8/subtitles": (200, list)])
        let tracks = try await session(transport).subtitles("f2d8")

        #expect(tracks.filter(\.burnOnly).map(\.id) == ["embedded-4"])
        #expect(tracks[2].path == nil && tracks[2].isDefault)
    }

    @Test func aChosenTrackIsNamedTheWayNectarKeysIt() {
        let external = SubtitleTrack(id: "5b6e", kind: .external, label: "English")
        let embedded = SubtitleTrack(id: "embedded-4", kind: .embedded, streamIndex: 4, label: "Track 4")

        #expect(SubtitleChoice.burn(embedded) == SubtitleChoice(mode: .burn, streamIndex: 4, subtitleID: nil))
        #expect(SubtitleChoice.burn(external) == SubtitleChoice(mode: .burn, streamIndex: nil, subtitleID: "5b6e"))
        #expect(SubtitleChoice.sidecar(external) == SubtitleChoice(mode: .sidecar, streamIndex: nil, subtitleID: "5b6e"))
    }

    @Test func decidePostsTheChoiceAndLeavesItOutWhenThereIsNone() async throws {
        let transport = PathTransport(["/api/v1/streaming/f2d8/decide": (200, decideAnswer)])
        let tv = session(transport)
        let pgs = SubtitleTrack(id: "embedded-4", kind: .embedded, streamIndex: 4, label: "Track 4")
        _ = try await tv.decide("f2d8", capabilities: .avPlayer(hevcHardwareDecode: true), startOffset: 812.6, subtitle: .burn(pgs))
        _ = try await tv.decide("f2d8", capabilities: .avPlayer(hevcHardwareDecode: true), startOffset: nil)

        let requests = await transport.requests
        let chosen = try #require(try json(requests[0].httpBody)["subtitle"] as? [String: Any])
        #expect(chosen["mode"] as? String == "burn")
        #expect(chosen["stream_index"] as? Int == 4)
        #expect(chosen["subtitle_id"] == nil, "only the key nectar resolves is sent")
        #expect(try json(requests[1].httpBody)["subtitle"] == nil, "no choice leaves nectar's default in charge")
    }

    @Test func decodesWhatNectarBurnedAndThePersonsDefault() async throws {
        let transport = PathTransport(["/api/v1/streaming/f2d8/decide": (200, decideAnswer)])
        let decision = try await session(transport).decide("f2d8", capabilities: .avPlayer(hevcHardwareDecode: true), startOffset: nil)

        #expect(decision.subtitleStreamIndex == 4)
        #expect(decision.subtitleDefault == SubtitleDefault(streamIndex: 3, reason: .forced))
    }

    @Test func aDecisionFromBeforeSubtitlesStillDecodes() throws {
        let old = #"{"strategy":"direct","stream_url":"/api/v1/streaming/6f1c/direct","play_method":"DirectPlay","start_offset_seconds":0}"#
        let decision = try JSONDecoder().decode(PlaybackDecision.self, from: Data(old.utf8))

        #expect(decision.subtitleDefault == nil && decision.subtitleStreamIndex == nil && decision.subtitleID == nil)
    }

    @Test func anUnknownDefaultReasonIsKept() throws {
        let answer = #"{"strategy":"direct","stream_url":"/d","start_offset_seconds":0,"subtitle_default":{"stream_index":2,"reason":"hearing"}}"#
        let decision = try JSONDecoder().decode(PlaybackDecision.self, from: Data(answer.utf8))

        #expect(decision.subtitleDefault == SubtitleDefault(streamIndex: 2, reason: .other("hearing")))
    }
}

/// Which of AVKit's subtitle options is the person's default (#97): nectar names a track, AVKit lists renditions.
@Suite("Subtitle default")
struct SubtitleDefaultMatchTests {

    private let options = [
        SubtitleOption(name: "English", language: "en", forced: false),
        SubtitleOption(name: "English (Forced)", language: "en", forced: true),
        SubtitleOption(name: "Español", language: "es-419", forced: false),
    ]

    @Test func theSameNameWins() {
        let track = SubtitleTrack(id: "embedded-3", kind: .embedded, streamIndex: 3, language: "en", label: "English (Forced)", isForced: true)
        #expect(track.option(among: options) == 1)
    }

    @Test func withoutTheNameLanguageAndForcedDecide() {
        let forced = SubtitleTrack(id: "embedded-3", kind: .embedded, streamIndex: 3, language: "eng", label: "Signs", isForced: true)
        let full = SubtitleTrack(id: "embedded-2", kind: .embedded, streamIndex: 2, language: "en", label: "SDH", isForced: false)
        #expect(forced.option(among: options) == 1, "ISO 639-2 'eng' is the same language as 'en'")
        #expect(full.option(among: options) == 0)
    }

    @Test func aRegionalTagMatchesItsLanguage() {
        let spanish = SubtitleTrack(id: "embedded-5", kind: .embedded, streamIndex: 5, language: "spa", label: "Spanish")
        #expect(spanish.option(among: options) == 2)
    }

    @Test func noMatchingOptionMeansNoChoice() {
        let french = SubtitleTrack(id: "embedded-6", kind: .embedded, streamIndex: 6, language: "fr", label: "Français")
        #expect(french.option(among: options) == nil)
        #expect(SubtitleTrack(id: "x", kind: .external, label: "English", canSidecar: false).option(among: options) == nil,
                "an image track has no rendition: it can only be burned in")
    }
}

/// What the TV does with the person's default at start (#97, Capping's spec): the default does the work.
@Suite("Subtitle start")
struct SubtitleStartTests {

    private let tracks = [
        SubtitleTrack(id: "embedded-2", kind: .embedded, streamIndex: 2, language: "en", label: "English"),
        SubtitleTrack(id: "embedded-3", kind: .embedded, streamIndex: 3, language: "en", label: "English (Forced)", isForced: true, canSidecar: false),
        SubtitleTrack(id: "6b0f", kind: .external, language: "fr", label: "Français"),
    ]

    @Test func aTextDefaultIsAnAVKitRendition() {
        #expect(SubtitleStart.plan(SubtitleDefault(streamIndex: 2, reason: .always), tracks) == .rendition(tracks[0]))
    }

    @Test func anImageDefaultIsBurnedFromTheFirstFrame() {
        #expect(SubtitleStart.plan(SubtitleDefault(streamIndex: 3, reason: .forced), tracks) == .burn(tracks[1]))
    }

    @Test func noDefaultOrAnUnknownTrackLeavesItToAVKit() {
        #expect(SubtitleStart.plan(nil, tracks) == .none)
        #expect(SubtitleStart.plan(SubtitleDefault(streamIndex: 9, reason: .always), tracks) == .none)
    }

    @Test func offIsAnExplicitChoiceWithNoTrack() throws {
        let body = try JSONSerialization.jsonObject(with: JSONEncoder().encode(SubtitleChoice.off)) as? [String: Any]
        #expect(body?["mode"] as? String == "off")
        #expect(body?["stream_index"] == nil && body?["subtitle_id"] == nil)
    }
}

/// "More subtitles" rows: the language, and only SDH, Forced or Commentary after it.
@Suite("Subtitle menu names")
struct SubtitleMenuNameTests {

    private let english = Locale(identifier: "en_US")

    @Test func aLanguageIsNamedInThePersonsLocale() {
        let spanish = SubtitleTrack(id: "embedded-4", kind: .embedded, streamIndex: 4, language: "spa", label: "Track 4", canSidecar: false)
        #expect(spanish.menuTitle(locale: english) == "Spanish")
        #expect(spanish.menuTitle(locale: Locale(identifier: "fr_FR")) == "espagnol")
    }

    @Test func onlyTheThreeQualifiersAreShown() {
        let sdh = SubtitleTrack(id: "e5", kind: .embedded, streamIndex: 5, language: "eng", format: "hdmv_pgs_subtitle", label: "English SDH (PGS)", canSidecar: false)
        let forced = SubtitleTrack(id: "e6", kind: .embedded, streamIndex: 6, language: "en", label: "English (Forced)", isForced: true, canSidecar: false)
        let commentary = SubtitleTrack(id: "e7", kind: .embedded, streamIndex: 7, language: "en", label: "Director's Commentary", canSidecar: false)
        #expect(sdh.menuTitle(locale: english) == "English · SDH")
        #expect(forced.menuTitle(locale: english) == "English · Forced")
        #expect(commentary.menuTitle(locale: english) == "English · Commentary")
    }

    @Test func aTrackWithNoLanguageKeepsNectarsLabel() {
        let unknown = SubtitleTrack(id: "e8", kind: .embedded, streamIndex: 8, language: "", label: "Track 8", canSidecar: false)
        #expect(unknown.menuTitle(locale: english) == "Track 8")
    }
}

/// nectar#627: the TV says it can't draw bitmaps, and nectar burns a bitmap default in the same answer.
@Suite("Subtitle capabilities")
struct SubtitleCapabilityTests {

    private let tracks = [
        SubtitleTrack(id: "embedded-2", kind: .embedded, streamIndex: 2, language: "en", label: "English"),
        SubtitleTrack(id: "embedded-11", kind: .embedded, streamIndex: 11, language: "fr", label: "French", canSidecar: false),
        SubtitleTrack(id: "5b6e", kind: .external, language: "de", label: "Deutsch", canSidecar: false),
    ]

    @Test func everyDecideSaysAVPlayerCantDrawBitmaps() throws {
        let body = try JSONSerialization.jsonObject(with: JSONEncoder().encode(DecideBody(.avPlayer(hevcHardwareDecode: true), startOffset: nil))) as? [String: Any]
        #expect((body?["subtitle_capabilities"] as? [String: Bool])?["bitmap"] == false)
    }

    /// nectar-apple #111 (the contract on nectar#687): burns off says so, `burn: false`, and nectar then burns
    /// nothing for this player and explains a wanted subtitle it can't serve. Burns on says `burn: true`.
    @Test func decideSaysWhetherNectarMayBurn() throws {
        func capabilities(_ burns: Bool) throws -> [String: Bool]? {
            let body = try JSONSerialization.jsonObject(with: JSONEncoder().encode(DecideBody(.avPlayer(hevcHardwareDecode: true, burnsSubtitles: burns), startOffset: nil))) as? [String: Any]
            return body?["subtitle_capabilities"] as? [String: Bool]
        }
        #expect(try capabilities(false) == ["bitmap": false, "burn": false])
        #expect(try capabilities(true) == ["bitmap": false, "burn": true])
    }

    @Test func aDefaultNectarAlreadyBurnedIsTakenAsIs() {
        let embedded = PlaybackDecision(strategy: .hls, streamPath: "/s.m3u8", reason: "subtitle_burn", subtitleStreamIndex: 11)
        let external = PlaybackDecision(strategy: .hls, streamPath: "/s.m3u8", reason: "subtitle_burn", subtitleID: "5b6e")
        #expect(SubtitleStart.plan(embedded, tracks) == .burned(tracks[1]))
        #expect(SubtitleStart.plan(external, tracks) == .burned(tracks[2]))
    }

    @Test func otherwiseTheDefaultDecides() {
        let text = PlaybackDecision(strategy: .hls, streamPath: "/s.m3u8", reason: "container", subtitleDefault: SubtitleDefault(streamIndex: 2, reason: .always))
        let oldServer = PlaybackDecision(strategy: .hls, streamPath: "/s.m3u8", reason: "container", subtitleDefault: SubtitleDefault(streamIndex: 11, reason: .always))
        #expect(SubtitleStart.plan(text, tracks) == .rendition(tracks[0]))
        #expect(SubtitleStart.plan(oldServer, tracks) == .burn(tracks[1]), "a nectar without #627 still gets the burn, by a second decide")
    }
}

/// nectar#645: an image track OCR has read comes as its text twin, and a burn the box can't run in real time is
/// declined with a reason instead of handed out.
@Suite("OCR twins and declined burns")
struct SubtitleTwinTests {

    private let tracks = [
        SubtitleTrack(id: "embedded-4", kind: .embedded, streamIndex: 4, language: "eng", label: "English", canSidecar: false),
        SubtitleTrack(id: "9c1e", kind: .generated, streamIndex: 4, language: "eng", label: "English (OCR 93%)"),
    ]

    @Test func decodesTheTwinAndTheDeclinedBurn() throws {
        let answer = #"""
        {"strategy":"hls","stream_url":"/s.m3u8","play_method":"DirectStream","reason":"container","start_offset_seconds":0,
         "subtitle_default":{"stream_index":4,"reason":"always","codec":"hdmv_pgs_subtitle","subtitle_id":"9c1e"},
         "subtitle_declined":{"stream_index":4,"reason":"burn_too_slow","message":"burning subtitles into this 2160p picture means re-encoding it in software","ocr":"queued"}}
        """#
        let decision = try JSONDecoder().decode(PlaybackDecision.self, from: Data(answer.utf8))

        #expect(decision.subtitleDefault == SubtitleDefault(streamIndex: 4, reason: .always, subtitleID: "9c1e"))
        #expect(decision.subtitleDeclined == SubtitleDeclined(streamIndex: 4, reason: .burnTooSlow, message: "burning subtitles into this 2160p picture means re-encoding it in software", ocr: .queued))
    }

    @Test func unknownReasonsAndOutlooksAreKept() throws {
        let answer = #"{"strategy":"direct","stream_url":"/d","start_offset_seconds":0,"subtitle_declined":{"stream_index":4,"reason":"no_gpu","message":"m","ocr":"later"}}"#
        let declined = try #require(try JSONDecoder().decode(PlaybackDecision.self, from: Data(answer.utf8)).subtitleDeclined)

        #expect(declined.reason == .other("no_gpu"))
        #expect(declined.ocr == .other("later"))
    }

    @Test func anOCRdDefaultIsItsTextTwinNotABurn() {
        let decision = PlaybackDecision(strategy: .hls, streamPath: "/s.m3u8", reason: "container", subtitleDefault: SubtitleDefault(streamIndex: 4, reason: .always, subtitleID: "9c1e"))
        #expect(SubtitleStart.plan(decision, tracks) == .rendition(tracks[1]))
    }

    @Test func aTwinTheListDoesntHaveYetFallsBackToTheStream() {
        let decision = PlaybackDecision(strategy: .hls, streamPath: "/s.m3u8", reason: "container", subtitleDefault: SubtitleDefault(streamIndex: 4, reason: .always, subtitleID: "gone"))
        #expect(SubtitleStart.plan(decision, tracks) == .burn(tracks[0]))
    }

    @Test func aDeclinedBurnIsNeverBurnedBySecondDecide() {
        let declined = SubtitleDeclined(streamIndex: 4, reason: .burnTooSlow, message: "m", ocr: .queued)
        let decision = PlaybackDecision(strategy: .hls, streamPath: "/s.m3u8", reason: "container", subtitleDefault: SubtitleDefault(streamIndex: 4, reason: .always), subtitleDeclined: declined)
        #expect(SubtitleStart.plan(decision, tracks) == .declined(tracks[0], declined))
    }

    @Test func aDeclinedBurnOfATrackTheListLacksStillSaysSo() {
        let declined = SubtitleDeclined(streamIndex: 7, reason: .burnTooSlow, message: "m", ocr: .unreadable)
        let decision = PlaybackDecision(strategy: .hls, streamPath: "/s.m3u8", reason: "container", subtitleDeclined: declined)
        #expect(SubtitleStart.plan(decision, tracks) == .declined(nil, declined))
    }
}

/// nectar-apple #111, Nate 2026-10-21: "let's give the reason why we can't turn them on. we're informative and clear
/// not grey." One message per cause, from decide's `subtitle_unavailable` (the contract on nectar#687).
@Suite("Why a subtitle can't be shown")
struct SubtitleUnavailableTests {

    private let english = Locale(identifier: "en_US")

    private func unavailable(_ reason: String, ocr: String? = nil, eta: Int? = nil, burn: String? = nil, language: String = "eng") throws -> SubtitleUnavailable {
        var object: [String: Any] = ["language": language, "stream_index": 3, "reason": reason]
        object["ocr"] = ocr ?? NSNull()
        object["ocr_eta_seconds"] = eta ?? NSNull()
        object["burn"] = burn ?? NSNull()
        return try JSONDecoder().decode(SubtitleUnavailable.self, from: JSONSerialization.data(withJSONObject: object))
    }

    @Test func theAgreedShapeDecodes() throws {
        let json = #"{"strategy":"hls","stream_url":"/s.m3u8","subtitle_unavailable":{"language":"eng","stream_index":3,"reason":"ocr_failed","ocr":"unreadable","ocr_eta_seconds":null,"burn":"too_slow"}}"#
        let decision = try JSONDecoder().decode(PlaybackDecision.self, from: Data(json.utf8))
        #expect(decision.subtitleUnavailable == SubtitleUnavailable(language: "eng", streamIndex: 3, reason: .ocrFailed, ocr: .unreadable, burn: .tooSlow))
    }

    @Test func unknownCodesAreKeptNotRefused() throws {
        let u = try unavailable("teleported", ocr: "dreaming", burn: "maybe")
        #expect(u.reason == .other("teleported"))
        #expect(u.ocr == .other("dreaming"))
        #expect(u.burn == .other("maybe"))
        #expect(u.message(locale: english) == "Couldn't turn on English subtitles.", "an unknown reason gets the plain line")
        #expect(u.isFailure)
    }

    @Test func noTrackSaysThereIsNone() throws {
        let u = try unavailable("no_track")
        #expect(u.message(locale: english) == "This film has no English subtitles.")
        #expect(u.message(noun: "episode", locale: english) == "This episode has no English subtitles.")
        #expect(!u.isFailure, "a fact about the film, not something that went wrong")
    }

    @Test func beingReadSaysWhenItWillBeReady() throws {
        let later = try unavailable("ocr_pending", ocr: "queued")
        #expect(later.message(locale: english) == "English subtitles for this film are pictures, and nectar is still reading them into text. They'll be ready next time you play it.")
        #expect(!later.isFailure)
        let soon = try unavailable("ocr_pending", ocr: "running", eta: 290)
        #expect(soon.message(locale: english) == "English subtitles for this film are pictures, and nectar is still reading them into text. They should be ready in about 5 minutes.")
        let now = try unavailable("ocr_pending", ocr: "running", eta: 20)
        #expect(now.message(locale: english) == "English subtitles for this film are pictures, and nectar is still reading them into text. They should be ready in a minute or so.")
    }

    @Test func unreadableSaysWhyItIsntBurnedEither() throws {
        let off = try unavailable("ocr_failed", ocr: "unreadable", burn: "off")
        #expect(off.message(locale: english) == "English subtitles for this film are pictures that nectar couldn't read into text, and this TV can't show pictures as subtitles yet.")
        let tooSlow = try unavailable("ocr_failed", ocr: "failed", burn: "too_slow")
        #expect(tooSlow.message(locale: english) == "English subtitles for this film are pictures that nectar couldn't read into text, and this film is too large to draw them in as it plays.")
        #expect(off.isFailure && tooSlow.isFailure)
    }

    @Test func ocrOffSaysWhyItIsntBurned() throws {
        let off = try unavailable("burn_off", ocr: "off", burn: "off")
        #expect(off.message(locale: english) == "English subtitles for this film are pictures, and nectar isn't set up to read them into text, so this TV can't show them yet.")
        let tooSlow = try unavailable("burn_too_slow", ocr: "off", burn: "too_slow")
        #expect(tooSlow.message(locale: english) == "English subtitles for this film are pictures, and this film is too large for nectar to draw them in as it plays.")
    }

    @Test func aLanguageNectarCantNameStillReads() throws {
        let u = try unavailable("no_track", language: "und")
        #expect(u.message(locale: english) == "This film has no subtitles in your language.")
        let pending = try unavailable("ocr_pending", ocr: "queued", language: "")
        #expect(pending.message(locale: english).hasPrefix("Subtitles for this film are pictures"))
    }

    /// nectar#687 slice 1: the default can be any text track. A sidecar (stream_index 1000+) or a Whisper track
    /// (stream_index -1) is named by subtitle_id, which the TV resolves first, against the subtitle list's ids.
    @Test func aSidecarOrWhisperDefaultResolvesBySubtitleID() {
        let sidecar = SubtitleTrack(id: "7230c98d", kind: .external, streamIndex: 1000, language: "en", label: "English")
        let whisper = SubtitleTrack(id: "w-41", kind: .generated, language: "en", label: "English (Generated)")
        let image = SubtitleTrack(id: "embedded-3", kind: .embedded, streamIndex: 3, language: "en", label: "English (burn-in)", canSidecar: false)
        let tracks = [image, sidecar, whisper]
        #expect(SubtitleStart.plan(SubtitleDefault(streamIndex: 1000, reason: .always, subtitleID: "7230c98d"), tracks) == .rendition(sidecar))
        #expect(SubtitleStart.plan(SubtitleDefault(streamIndex: -1, reason: .always, subtitleID: "w-41"), tracks) == .rendition(whisper))
        #expect(SubtitleStart.plan(SubtitleDefault(streamIndex: 3, reason: .always), tracks) == .burn(image), "an embedded default still keys on stream_index")
    }

    @Test func thePlanTellsTheReasonBeforeAnyDefault() {
        let u = SubtitleUnavailable(language: "eng", streamIndex: 11, reason: .ocrPending, ocr: .queued)
        let decision = PlaybackDecision(strategy: .hls, streamPath: "/s.m3u8", reason: "container", subtitleUnavailable: u)
        #expect(SubtitleStart.plan(decision, []) == .unavailable(u))
    }
}
