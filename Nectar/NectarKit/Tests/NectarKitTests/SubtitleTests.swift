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
