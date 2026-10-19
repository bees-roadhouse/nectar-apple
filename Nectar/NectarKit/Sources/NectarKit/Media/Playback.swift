import Foundation

/// What this device can play, as nectar's decide endpoint wants to hear it.
///
/// Honesty is the point: nectar picks direct play, a copy into HLS, or a transcode from this, so
/// claiming HEVC on a device without a hardware decoder buys a stutter, and leaving it out on one
/// that has it buys a needless transcode (#4: never a video transcode for HEVC on the Apple TV).
public struct PlaybackCapabilities: Equatable, Sendable {
    public var containers: [String]
    public var videoCodecs: [String]
    public var audioCodecs: [String]
    public var hlsVideoCodecs: [String]
    public var hlsAudioCodecs: [String]
    public var maxBitrate: Int?

    public init(containers: [String], videoCodecs: [String], audioCodecs: [String], hlsVideoCodecs: [String], hlsAudioCodecs: [String], maxBitrate: Int? = nil) {
        self.containers = containers
        self.videoCodecs = videoCodecs
        self.audioCodecs = audioCodecs
        self.hlsVideoCodecs = hlsVideoCodecs
        self.hlsAudioCodecs = hlsAudioCodecs
        self.maxBitrate = maxBitrate
    }

    /// AVPlayer on tvOS. HEVC only when the hardware decodes it: true on an Apple TV 4K, false in the simulator.
    public static func avPlayer(hevcHardwareDecode: Bool) -> PlaybackCapabilities {
        let video = hevcHardwareDecode ? ["h264", "hevc"] : ["h264"]
        return PlaybackCapabilities(
            containers: ["mp4", "m4v", "mov"],
            videoCodecs: video,
            audioCodecs: ["aac", "ac3", "eac3", "alac", "flac", "mp3"],
            hlsVideoCodecs: video,
            hlsAudioCodecs: ["aac", "ac3", "eac3"]
        )
    }
}

/// The body of `POST /api/v1/streaming/{id}/decide`.
struct DecideBody: Encodable, Sendable {
    struct Codecs: Encodable, Sendable {
        let video: [String]
        let audio: [String]
    }

    let containers: [String]
    let codecs: Codecs
    let hlsCodecs: Codecs
    let maxBitrate: Int?
    let startOffset: Int?

    init(_ capabilities: PlaybackCapabilities, startOffset: Double?) {
        containers = capabilities.containers
        codecs = Codecs(video: capabilities.videoCodecs, audio: capabilities.audioCodecs)
        hlsCodecs = Codecs(video: capabilities.hlsVideoCodecs, audio: capabilities.hlsAudioCodecs)
        maxBitrate = capabilities.maxBitrate
        // nectar takes whole seconds; resuming a second early beats a second late.
        self.startOffset = startOffset.map { max(Int($0.rounded(.down)), 0) }
    }

    enum CodingKeys: String, CodingKey {
        case containers
        case codecs
        case hlsCodecs = "hls_codecs"
        case maxBitrate = "max_bitrate"
        case startOffset = "start_offset"
    }
}

/// nectar's answer: what to open, and how it got there.
public struct PlaybackDecision: Decodable, Equatable, Sendable {

    public enum Strategy: String, Decodable, Sendable {
        case direct
        case hls
    }

    public let strategy: Strategy
    /// Root-relative; open it with ``NectarSession/mediaURL(_:)``.
    public let streamPath: String
    /// `DirectPlay`, `DirectStream` (video copied into HLS) or `Transcode`.
    public let playMethod: String?
    /// Why it isn't the tier above (`video_codec`, `container`, `bitrate_cap`, …).
    public let reason: String?
    public let durationSeconds: Double?
    /// Where the stream actually starts: an HLS copy starts on a keyframe, so it can be before what was asked.
    public let startOffsetSeconds: Double

    public init(strategy: Strategy, streamPath: String, playMethod: String? = nil, reason: String? = nil, durationSeconds: Double? = nil, startOffsetSeconds: Double = 0) {
        self.strategy = strategy
        self.streamPath = streamPath
        self.playMethod = playMethod
        self.reason = reason
        self.durationSeconds = durationSeconds
        self.startOffsetSeconds = startOffsetSeconds
    }

    enum CodingKeys: String, CodingKey {
        case strategy
        case streamPath = "stream_url"
        case playMethod = "play_method"
        case reason
        case durationSeconds = "duration_seconds"
        case startOffsetSeconds = "start_offset_seconds"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        strategy = try c.decode(Strategy.self, forKey: .strategy)
        streamPath = try c.decode(String.self, forKey: .streamPath)
        playMethod = try c.decodeIfPresent(String.self, forKey: .playMethod)
        reason = try c.decodeIfPresent(String.self, forKey: .reason)
        durationSeconds = try c.decodeIfPresent(Double.self, forKey: .durationSeconds)
        startOffsetSeconds = try c.decodeIfPresent(Double.self, forKey: .startOffsetSeconds) ?? 0
    }

    /// Where to seek once the player is ready. A direct file starts at zero, so seek to the resume
    /// point; an HLS stream already starts at `startOffsetSeconds`, so seek by what's left over.
    public func seek(toResumeAt resume: Double) -> Double {
        switch strategy {
        case .direct: max(resume, 0)
        case .hls: max(resume - startOffsetSeconds, 0)
        }
    }
}

struct ProgressBody: Encodable, Sendable {
    /// Whole seconds: nectar's ProgressBody is `z.number().int()`, and a fraction is a 422.
    let positionSeconds: Int
    let paused: Bool?
    let completed: Bool?

    enum CodingKeys: String, CodingKey {
        case positionSeconds = "position_seconds"
        case paused
        case completed
    }
}

extension NectarSession {

    /// Ask nectar how this device should play an item, starting at `startOffset` seconds.
    public func decide(_ itemID: String, capabilities: PlaybackCapabilities, startOffset: Double?) async throws -> PlaybackDecision {
        let data = try await post("api/v1/streaming/\(itemID)/decide", json: DecideBody(capabilities, startOffset: startOffset))
        return try JSONDecoder().decode(PlaybackDecision.self, from: data)
    }

    /// Save where this user is (`POST /api/v1/media/{id}/progress`). nectar keeps `completed` once set.
    public func reportProgress(_ itemID: String, positionSeconds: Double, paused: Bool? = nil, completed: Bool? = nil) async throws {
        _ = try await post("api/v1/media/\(itemID)/progress", json: ProgressBody(positionSeconds: positionSeconds.isFinite ? max(Int(positionSeconds.rounded(.down)), 0) : 0, paused: paused, completed: completed))
    }
}
