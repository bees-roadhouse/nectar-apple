//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

import Foundation
import JellyfinAPI

/// How the server is delivering the item currently playing, cheapest first.
enum PlaybackDeliveryMode: Displayable {

    /// The original file, untouched.
    case directPlay
    /// Video and audio copied into a new container (e.g. MKV → HLS fMP4).
    case remux
    /// Video copied, audio re-encoded.
    case audioTranscode
    /// Video re-encoded.
    case transcode

    var displayTitle: String {
        switch self {
        case .directPlay:
            L10n.directPlay
        case .remux:
            L10n.remux
        case .audioTranscode:
            L10n.audioTranscoding
        case .transcode:
            L10n.transcode
        }
    }

    var systemImage: String {
        switch self {
        case .directPlay:
            "checkmark.circle"
        case .remux:
            "shippingbox"
        case .audioTranscode:
            "waveform"
        case .transcode:
            "exclamationmark.triangle"
        }
    }
}

extension MediaSourceInfo {

    /// The mode the server chose in `PlaybackInfo`, read before playback starts.
    ///
    /// Without a `TranscodingUrl` the client streams the original file. With one, the server's
    /// `TranscodeReasons` say what it had to change: any video reason means the video is re-encoded,
    /// audio reasons alone mean only the audio is, and anything else (container, codec tag) is a remux.
    var playbackDeliveryMode: PlaybackDeliveryMode {
        guard let transcodingURL else { return .directPlay }

        let reasons = URLComponents(string: transcodingURL)?
            .queryItems?
            .first { $0.name.caseInsensitiveCompare("TranscodeReasons") == .orderedSame }?
            .value?
            .split(separator: ",")
            .compactMap { TranscodeReason(rawValue: String($0)) } ?? []

        if reasons.contains(where: \.requiresVideoTranscode) {
            return .transcode
        }
        if reasons.contains(where: \.isAudioReason) {
            return .audioTranscode
        }
        return .remux
    }
}

private extension TranscodeReason {

    var requiresVideoTranscode: Bool {
        switch self {
        case .videoCodecNotSupported, .videoProfileNotSupported, .videoLevelNotSupported,
             .videoResolutionNotSupported, .videoBitDepthNotSupported, .videoFramerateNotSupported,
             .refFramesNotSupported, .anamorphicVideoNotSupported, .interlacedVideoNotSupported,
             .videoBitrateNotSupported, .videoRangeTypeNotSupported, .unknownVideoStreamInfo,
             .videoRotationNotSupported, .containerBitrateExceedsLimit, .subtitleCodecNotSupported:
            true
        default:
            false
        }
    }

    var isAudioReason: Bool {
        switch self {
        case .audioCodecNotSupported, .audioIsExternal, .secondaryAudioNotSupported,
             .audioChannelsNotSupported, .audioProfileNotSupported, .audioSampleRateNotSupported,
             .audioBitDepthNotSupported, .audioBitrateNotSupported, .unknownAudioStreamInfo:
            true
        default:
            false
        }
    }
}

extension SessionInfoDto {

    /// The mode the server reports for this session, or `nil` when nothing is playing.
    var playbackDeliveryMode: PlaybackDeliveryMode? {
        guard nowPlayingItem != nil, let playMethod = playState?.playMethod else { return nil }

        if playMethod == .directPlay {
            return .directPlay
        }

        guard let transcodingInfo else {
            return playMethod == .directStream ? .remux : .transcode
        }

        switch (transcodingInfo.isVideoDirect ?? false, transcodingInfo.isAudioDirect ?? false) {
        case (true, true):
            return .remux
        case (true, false):
            return .audioTranscode
        case (false, _):
            return .transcode
        }
    }
}
