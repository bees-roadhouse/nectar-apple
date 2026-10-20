import Foundation

/// A subtitle track a title carries or sits beside, as `GET /api/v1/media/{id}/subtitles` lists it (#97).
public struct SubtitleTrack: Decodable, Equatable, Identifiable, Sendable {

    /// Where the track comes from. Unknown kinds are kept, not refused.
    public enum Kind: Equatable, Sendable, Decodable {
        /// Inside the file: nectar keys it by `stream_index`.
        case embedded
        /// A file beside the video: keyed by its id.
        case external
        /// Transcribed by nectar (Whisper).
        case generated
        case other(String)

        public init(from decoder: Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            self = switch raw {
            case "embedded": .embedded
            case "external": .external
            case "generated": .generated
            default: .other(raw)
            }
        }
    }

    /// `embedded-{index}` for an embedded track, else the subtitle's own id.
    public let id: String
    public let kind: Kind
    public let streamIndex: Int?
    public let language: String
    public let format: String
    /// What a menu shows; nectar names the track's HLS rendition the same (nectar#601).
    public let label: String
    public let isDefault: Bool
    public let isForced: Bool
    public let canSidecar: Bool
    public let canBurn: Bool
    /// The WebVTT, root-relative: text tracks only.
    public let path: String?

    /// An image track (PGS, VobSub): AVPlayer can't draw pictures as subtitles, so nectar burns it in.
    public var burnOnly: Bool {
        !canSidecar && canBurn
    }

    public init(
        id: String,
        kind: Kind,
        streamIndex: Int? = nil,
        language: String = "",
        format: String = "",
        label: String,
        isDefault: Bool = false,
        isForced: Bool = false,
        canSidecar: Bool = true,
        canBurn: Bool = true,
        path: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.streamIndex = streamIndex
        self.language = language
        self.format = format
        self.label = label
        self.isDefault = isDefault
        self.isForced = isForced
        self.canSidecar = canSidecar
        self.canBurn = canBurn
        self.path = path
    }

    enum CodingKeys: String, CodingKey {
        case id
        case kind
        case streamIndex = "stream_index"
        case language
        case format
        case label
        case isDefault = "is_default"
        case isForced = "is_forced"
        case canSidecar = "can_sidecar"
        case canBurn = "can_burn"
        case path = "url"
    }
}

/// One of AVKit's subtitle options, as the app reads it from the stream's legible group: what's needed
/// to find the person's default among nectar's renditions (#97).
public struct SubtitleOption: Equatable, Sendable {
    public let name: String
    public let language: String?
    public let forced: Bool

    public init(name: String, language: String?, forced: Bool) {
        self.name = name
        self.language = language
        self.forced = forced
    }
}

extension SubtitleTrack {

    /// This track's rendition among AVKit's options: the same name first (nectar names a rendition after its
    /// track), else the same language and forced flag. Nil for an image track, which has no rendition.
    public func option(among options: [SubtitleOption]) -> Int? {
        guard canSidecar else { return nil }
        if let named = options.firstIndex(where: { $0.name == label }) { return named }
        guard let language = Self.baseLanguage(language) else { return nil }
        return options.firstIndex { Self.baseLanguage($0.language ?? "") == language && $0.forced == isForced }
    }

    /// A "More subtitles" row (Capping's spec on #97): the language in the person's locale, then only SDH,
    /// Forced or Commentary. Never the codec or the stream index: an admin sees those in Playback info.
    public func menuTitle(locale: Locale = .current) -> String {
        guard let code = Self.baseLanguage(language), let name = locale.localizedString(forLanguageCode: code) else { return label }
        let text = label.lowercased()
        let qualifier: String? = if text.contains("commentary") {
            "Commentary"
        } else if isForced {
            "Forced"
        } else if text.contains("sdh") || text.contains("hearing") {
            "SDH"
        } else {
            nil
        }
        return qualifier.map { "\(name) · \($0)" } ?? name
    }

    /// "en", "eng" and "en-US" are one language; an empty or undetermined tag is none.
    static func baseLanguage(_ tag: String) -> String? {
        let tag = tag.trimmingCharacters(in: .whitespaces).lowercased()
        guard !tag.isEmpty, tag != "und" else { return nil }
        let code = Locale.Language(identifier: tag).languageCode
        return code?.identifier(.alpha2) ?? code?.identifier
    }
}

/// The subtitle a player asks decide for: `subtitle` in its body.
public struct SubtitleChoice: Encodable, Equatable, Sendable {

    public enum Mode: String, Encodable, Sendable {
        case off
        case sidecar
        case burn
        case auto
    }

    public let mode: Mode
    public let streamIndex: Int?
    public let subtitleID: String?

    public init(mode: Mode, streamIndex: Int?, subtitleID: String?) {
        self.mode = mode
        self.streamIndex = streamIndex
        self.subtitleID = subtitleID
    }

    /// No subtitle, said outright: a burned stream turned off, even when the person's default is an image track.
    public static let off = SubtitleChoice(mode: .off, streamIndex: nil, subtitleID: nil)

    /// The track drawn into the picture: how an image track plays at all.
    public static func burn(_ track: SubtitleTrack) -> SubtitleChoice {
        SubtitleChoice(mode: .burn, track)
    }

    /// The track as text beside the picture.
    public static func sidecar(_ track: SubtitleTrack) -> SubtitleChoice {
        SubtitleChoice(mode: .sidecar, track)
    }

    /// nectar keys an embedded track by its stream index and any other by its id, and refuses one it can't find.
    private init(mode: Mode, _ track: SubtitleTrack) {
        self.mode = mode
        streamIndex = track.kind == .embedded ? track.streamIndex : nil
        subtitleID = track.kind == .embedded ? nil : track.id
    }

    enum CodingKeys: String, CodingKey {
        case mode
        case streamIndex = "stream_index"
        case subtitleID = "subtitle_id"
    }
}

/// What the TV does with the person's default at start (#97, Capping's spec): the default does the work, so
/// nobody has to open a menu. Their language as a text track is AVKit's rendition; as an image track only
/// (common on Blu-ray rips, where English is PGS), it's burned in from the first frame.
public enum SubtitleStart: Equatable, Sendable {
    case none
    case rendition(SubtitleTrack)
    /// Burn it with a second decide: a nectar older than #627.
    case burn(SubtitleTrack)
    /// nectar burned it already, in the answer to the first decide (#627, the TV's `bitmap: false`).
    case burned(SubtitleTrack)

    /// The plan for a decision: a track nectar already burned is taken as is; otherwise the person's default.
    public static func plan(_ decision: PlaybackDecision, _ tracks: [SubtitleTrack]) -> SubtitleStart {
        if decision.reason == "subtitle_burn" {
            let track = tracks.first { track in
                if let index = decision.subtitleStreamIndex { return track.kind == .embedded && track.streamIndex == index }
                return decision.subtitleID == track.id
            }
            if let track { return .burned(track) }
        }
        return plan(decision.subtitleDefault, tracks)
    }

    /// `subtitle_default` names an embedded stream; nil, or a track the list doesn't have, leaves it to AVKit.
    public static func plan(_ fallback: SubtitleDefault?, _ tracks: [SubtitleTrack]) -> SubtitleStart {
        guard let fallback, let track = tracks.first(where: { $0.kind == .embedded && $0.streamIndex == fallback.streamIndex }) else { return .none }
        if track.canSidecar { return .rendition(track) }
        return track.canBurn ? .burn(track) : .none
    }
}

/// The subtitle nectar would show this person for a title, by their My Account mode and language
/// (decide's `subtitle_default`, nectar #407 and #560).
public struct SubtitleDefault: Decodable, Equatable, Sendable {

    /// Why this track. Unknown reasons are kept, not refused.
    public enum Reason: Equatable, Sendable, Decodable {
        /// The person's mode is "always".
        case always
        /// The audio isn't in their subtitle language.
        case audioNotInLanguage
        /// The audio is in their language: only the forced lines (foreign dialogue).
        case forced
        case other(String)

        public init(from decoder: Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            self = switch raw {
            case "always": .always
            case "audio_not_in_language": .audioNotInLanguage
            case "forced": .forced
            default: .other(raw)
            }
        }
    }

    public let streamIndex: Int
    public let reason: Reason

    public init(streamIndex: Int, reason: Reason) {
        self.streamIndex = streamIndex
        self.reason = reason
    }

    enum CodingKeys: String, CodingKey {
        case streamIndex = "stream_index"
        case reason
    }
}

extension NectarSession {

    /// Every subtitle track a title carries or sits beside.
    public func subtitles(_ itemID: String) async throws -> [SubtitleTrack] {
        struct List: Decodable {
            let subtitles: [SubtitleTrack]
        }
        return try JSONDecoder().decode(List.self, from: try await get("api/v1/media/\(itemID)/subtitles")).subtitles
    }
}
