import Foundation
@testable import NectarKit
import Testing

private let itemJSON = #"""
{"item":{"id":"a","item_type":"movie","title":"Arrival","container":"mkv","video_codec":null,"primary_video_codec":"hevc",
 "resolution":null,"primary_video_resolution":"2160p","primary_video_hdr":"dolby_vision","bitrate":"42100000","size_bytes":58300000000,
 "audio_tracks":[{"stream_index":1,"codec":"eac3","language":"eng","title":null,"channels":6,"channel_layout":"5.1(side)","is_default":true},
                 {"stream_index":2,"codec":"aac","language":"fra","title":"Commentary","channels":2,"channel_layout":"stereo","is_default":false}]},
 "progress":null}
"""#

private let english = Locale(identifier: "en_US")

struct PlaybackInfoTests {

    @Test func theItemCarriesWhatTheFileIs() throws {
        let source = try JSONDecoder().decode(ItemDetail.self, from: Data(itemJSON.utf8)).source
        #expect(source.container == "mkv")
        #expect(source.videoCodec == "hevc")
        #expect(source.resolution == "2160p")
        #expect(source.hdr == "dolby_vision")
        #expect(source.bitrate == 42_100_000)
        #expect(source.audioTracks.map(\.streamIndex) == [1, 2])
    }

    @Test func aTranscodeSaysWhyInPlainWords() throws {
        let source = try JSONDecoder().decode(ItemDetail.self, from: Data(itemJSON.utf8)).source
        let decision = PlaybackDecision(strategy: .hls, streamPath: "/s.m3u8", playMethod: "Transcode", reason: "no_keyframe_index",
                                        audioReason: .preferredLanguage, audioStreamIndex: 1)
        let lines = PlaybackInfo.lines(decision: decision, source: source, observedBitrate: 18_240_000, presentation: CGSize(width: 3840, height: 2160), locale: english)
        #expect(lines.map(\.label) == ["Playing as", "Source", "Audio", "Stream"])
        #expect(lines[0].value == "Transcode · no trusted keyframe index yet")
        #expect(lines[1].value == "MKV · HEVC · 2160p · Dolby Vision · 42.1 Mbps · 58.3 GB")
        #expect(lines[2].value == "English · E-AC-3 · 5.1 · your playback language")
        #expect(lines[3].value == "HLS · 18.2 Mbps now · 3840×2160")
    }

    @Test func directPlayNeedsNoReasonAndTheChosenTrackIsTheOneShown() {
        let source = PlaybackSource(container: "mp4", videoCodec: "h264", resolution: "1080p", hdr: nil, bitrate: 850_000, sizeBytes: nil, audioTracks: [
            .init(streamIndex: 1, codec: "aac", language: "eng", title: nil, channels: 2, channelLayout: nil, isDefault: true),
            .init(streamIndex: 2, codec: "ac3", language: "fra", title: nil, channels: 6, channelLayout: nil, isDefault: false),
        ])
        let decision = PlaybackDecision(strategy: .direct, streamPath: "/d", playMethod: "DirectPlay", audioReason: .requested, audioStreamIndex: 2)
        let lines = PlaybackInfo.lines(decision: decision, source: source, observedBitrate: nil, presentation: nil, locale: english)
        #expect(lines[0].value == "Direct play")
        #expect(lines[1].value == "MP4 · H.264 · 1080p · 850 kbps")
        #expect(lines[2].value == "French · AC-3 · 5.1 · chosen")
        #expect(lines[3].value == "File")
    }

    @Test func anUnknownReasonOrCodecIsShownAsNectarWroteIt() {
        let decision = PlaybackDecision(strategy: .hls, streamPath: "/s", playMethod: "DirectStream", reason: "something_new")
        let lines = PlaybackInfo.lines(decision: decision, source: nil, observedBitrate: nil, presentation: nil, locale: english)
        #expect(lines.map(\.label) == ["Playing as", "Stream"])
        #expect(lines[0].value == "Remux · something_new")
        #expect(PlaybackInfo.reason("container") == "the TV doesn't play this container directly")
        #expect(PlaybackInfo.codec("xvid") == "XVID")
    }
}
