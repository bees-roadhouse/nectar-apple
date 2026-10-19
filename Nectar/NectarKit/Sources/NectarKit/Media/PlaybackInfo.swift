import CoreGraphics
import Foundation

/// What the file itself is, as the item route describes it (`GET /api/v1/media/{id}`): for Playback info (#82).
public struct PlaybackSource: Decodable, Equatable, Sendable {

    public struct AudioTrack: Decodable, Equatable, Sendable {
        public let streamIndex: Int
        public let codec: String?
        public let language: String?
        public let title: String?
        public let channels: Int?
        public let channelLayout: String?
        public let isDefault: Bool

        public init(streamIndex: Int, codec: String?, language: String?, title: String?, channels: Int?, channelLayout: String?, isDefault: Bool) {
            self.streamIndex = streamIndex
            self.codec = codec
            self.language = language
            self.title = title
            self.channels = channels
            self.channelLayout = channelLayout
            self.isDefault = isDefault
        }

        enum CodingKeys: String, CodingKey {
            case codec, language, title, channels
            case streamIndex = "stream_index"
            case channelLayout = "channel_layout"
            case isDefault = "is_default"
        }
    }

    public let container: String?
    public let videoCodec: String?
    public let resolution: String?
    public let hdr: String?
    /// Bits per second.
    public let bitrate: Double?
    public let sizeBytes: Double?
    public let audioTracks: [AudioTrack]

    public init(container: String?, videoCodec: String?, resolution: String?, hdr: String?, bitrate: Double?, sizeBytes: Double?, audioTracks: [AudioTrack]) {
        self.container = container
        self.videoCodec = videoCodec
        self.resolution = resolution
        self.hdr = hdr
        self.bitrate = bitrate
        self.sizeBytes = sizeBytes
        self.audioTracks = audioTracks
    }

    private enum Keys: String, CodingKey {
        case container, resolution, bitrate
        case videoCodec = "video_codec"
        case primaryVideoCodec = "primary_video_codec"
        case primaryVideoResolution = "primary_video_resolution"
        case primaryVideoHDR = "primary_video_hdr"
        case sizeBytes = "size_bytes"
        case audioTracks = "audio_tracks"
    }

    /// The file's own columns first, then the primary stream's, which the scanner fills when the file's are empty.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        container = try? c.decodeIfPresent(String.self, forKey: .container)
        videoCodec = ((try? c.decodeIfPresent(String.self, forKey: .videoCodec)) ?? nil)
            ?? ((try? c.decodeIfPresent(String.self, forKey: .primaryVideoCodec)) ?? nil)
        resolution = ((try? c.decodeIfPresent(String.self, forKey: .resolution)) ?? nil)
            ?? ((try? c.decodeIfPresent(String.self, forKey: .primaryVideoResolution)) ?? nil)
        hdr = (try? c.decodeIfPresent(String.self, forKey: .primaryVideoHDR)) ?? nil
        bitrate = c.lenientDouble(.bitrate)
        sizeBytes = c.lenientDouble(.sizeBytes)
        audioTracks = ((try? c.decodeIfPresent([AudioTrack].self, forKey: .audioTracks)) ?? nil) ?? []
    }
}

/// The Playback tab in the player's info panel (#82): how nectar is sending this title and why, what the file
/// is, the audio track it picked, and what's arriving now. Lines with nothing to say are left out.
public enum PlaybackInfo {

    public struct Line: Equatable, Identifiable, Sendable {
        public let label: String
        public let value: String
        public var id: String { label }
    }

    public static func lines(decision: PlaybackDecision, source: PlaybackSource?, observedBitrate: Double?, presentation: CGSize?,
                             locale: Locale = .current) -> [Line] {
        var lines = [Line(label: "Playing as", value: playingAs(decision))]
        if let source {
            let file = [source.container?.uppercased(), source.videoCodec.map(codec), source.resolution, source.hdr.map(hdr),
                        source.bitrate.map(rate), source.sizeBytes.map(size)].compactMap { $0 }
            if !file.isEmpty {
                lines.append(Line(label: "Source", value: file.joined(separator: " · ")))
            }
            let track = source.audioTracks.first { $0.streamIndex == decision.audioStreamIndex }
                ?? source.audioTracks.first(where: \.isDefault) ?? source.audioTracks.first
            if let track {
                let language = track.language.flatMap { locale.localizedString(forLanguageCode: $0) } ?? track.language
                let audio = [language, track.codec.map(codec), channels(track), decision.audioReason.map(audioReason)].compactMap { $0 }
                lines.append(Line(label: "Audio", value: audio.joined(separator: " · ")))
            }
        }
        var stream = [decision.strategy == .hls ? "HLS" : "File"]
        if let observedBitrate, observedBitrate > 0 { stream.append("\(rate(observedBitrate)) now") }
        if let presentation, presentation.width > 0 { stream.append("\(Int(presentation.width))×\(Int(presentation.height))") }
        lines.append(Line(label: "Stream", value: stream.joined(separator: " · ")))
        return lines
    }

    /// "Direct play", "Remux" or "Transcode", the words the player's badge has always used.
    public static func method(_ decision: PlaybackDecision) -> String {
        switch decision.playMethod {
        case "DirectPlay": "Direct play"
        case "DirectStream": "Remux"
        case "Transcode": "Transcode"
        // The TV's own copy (#85): nectar wasn't asked how to send it.
        case PlaybackDecision.preloaded: "Pre-loaded"
        case let other?: other
        case nil: decision.strategy == .direct ? "Direct play" : "Streaming"
        }
    }

    static func playingAs(_ decision: PlaybackDecision) -> String {
        let method = method(decision)
        guard decision.playMethod != "DirectPlay", let code = decision.reason, !code.isEmpty else { return method }
        return "\(method) · \(reason(code))"
    }

    /// nectar's decide reasons, in words; one it adds later is shown as it wrote it.
    public static func reason(_ code: String) -> String {
        switch code {
        case "container": "the TV doesn't play this container directly"
        case "video_codec": "the TV can't play this video codec"
        case "audio_codec": "the TV can't play this audio codec"
        case "bitrate_cap": "over the bitrate limit"
        case "quality_selected": "a lower quality was chosen"
        case "subtitle_burn": "subtitles burned into the picture"
        case "audio_track_selected": "another audio track was chosen"
        case "no_keyframe_index": "no trusted keyframe index yet"
        case "dolby_vision_profile": "a Dolby Vision profile the TV can't play"
        default: code
        }
    }

    static func codec(_ name: String) -> String {
        switch name.lowercased() {
        case "h264", "avc": "H.264"
        case "hevc", "h265": "HEVC"
        case "eac3": "E-AC-3"
        case "ac3": "AC-3"
        case "truehd": "TrueHD"
        case "opus": "Opus"
        default: name.uppercased()
        }
    }

    static func hdr(_ name: String) -> String {
        let n = name.lowercased()
        if n.contains("dolby") || n.contains("dovi") { return "Dolby Vision" }
        if n.contains("hdr10plus") || n.contains("hdr10+") { return "HDR10+" }
        if n.contains("hdr10") { return "HDR10" }
        if n.contains("hlg") { return "HLG" }
        return name
    }

    static func rate(_ bitsPerSecond: Double) -> String {
        bitsPerSecond >= 1_000_000
            ? String(format: "%.1f Mbps", bitsPerSecond / 1_000_000)
            : "\(Int((bitsPerSecond / 1000).rounded())) kbps"
    }

    static func size(_ bytes: Double) -> String {
        String(format: "%.1f GB", bytes / 1_000_000_000)
    }

    static func channels(_ track: PlaybackSource.AudioTrack) -> String? {
        if let layout = track.channelLayout, let core = layout.split(separator: "(").first, core.contains(".") {
            return String(core)
        }
        return switch track.channels {
        case 1?: "Mono"
        case 2?: "Stereo"
        case 6?: "5.1"
        case 8?: "7.1"
        case let n?: "\(n) ch"
        case nil: nil
        }
    }

    static func audioReason(_ reason: AudioReason) -> String {
        switch reason {
        case .requested: "chosen"
        case .originalLanguage: "the original language"
        case .preferredLanguage: "your playback language"
        case .fileDefault: "the file's default"
        case .first: "the first track"
        case let .other(raw): raw
        }
    }
}
