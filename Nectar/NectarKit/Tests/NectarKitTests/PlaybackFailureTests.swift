import Foundation
import Testing
@testable import NectarKit

@Suite("Playback failure")
struct PlaybackFailureTests {

    private let transcode = PlaybackDecision(strategy: .hls, streamPath: "/s.m3u8", playMethod: "Transcode", reason: "video_codec")
    private let direct = PlaybackDecision(strategy: .direct, streamPath: "/f", playMethod: "DirectPlay", reason: nil)

    @Test func nectarUnreachableAtDecideSaysSoAndCanBeRetried() {
        let failure = PlaybackFailure.explain(.decide, error: URLError(.cannotConnectToHost), decision: nil)
        #expect(failure.why == "Couldn't reach nectar.")
        #expect(failure.detail == "NSURLErrorDomain \(URLError.Code.cannotConnectToHost.rawValue)")
        #expect(failure.retryable)
    }

    @Test func aTitleNectarNoLongerHasCantBeRetried() {
        let failure = PlaybackFailure.explain(.decide, error: NectarSessionError.unexpectedStatus(404), decision: nil)
        #expect(failure.why == "It isn't in the library any more.")
        #expect(failure.detail == "HTTP 404")
        #expect(!failure.retryable)
    }

    @Test func nectarFailingOnItsSideCanBeRetried() {
        let failure = PlaybackFailure.explain(.decide, error: NectarSessionError.unexpectedStatus(503), decision: nil)
        #expect(failure.why == "nectar ran into a problem.")
        #expect(failure.detail == "HTTP 503")
        #expect(failure.retryable)
    }

    @Test func anotherRefusalCantBeRetried() {
        let failure = PlaybackFailure.explain(.decide, error: NectarSessionError.unexpectedStatus(403), decision: nil)
        #expect(failure.why == "nectar couldn't send this title.")
        #expect(!failure.retryable)
    }

    @Test func beingSignedOutCantBeRetried() {
        let failure = PlaybackFailure.explain(.decide, error: NectarSessionError.signedOut, decision: nil)
        #expect(failure.why == "This TV was signed out of nectar.")
        #expect(!failure.retryable)
    }

    @Test func noFirstFrameOnATranscodeSaysWhyItWasConverting() {
        let failure = PlaybackFailure.explain(.noFirstFrame, error: nil, decision: transcode)
        #expect(failure.why == "nectar didn't start sending it in time (converting it: the TV can't play this video codec).")
        #expect(failure.detail == nil)
        #expect(failure.retryable)
    }

    @Test func noFirstFrameOnADirectPlayIsPlain() {
        #expect(PlaybackFailure.explain(.noFirstFrame, error: nil, decision: direct).why == "nectar didn't start sending it in time.")
    }

    @Test func aFormatTheTVCantOpenSaysTheTVCantPlayItAndCantBeRetried() {
        let error = NSError(domain: "AVFoundationErrorDomain", code: -11828)
        let failure = PlaybackFailure.explain(.player, error: error, decision: direct)
        #expect(failure.why == "The TV can't play this file.")
        #expect(failure.detail == "AVFoundationErrorDomain -11828")
        #expect(!failure.retryable)
    }

    @Test func theStreamStoppingIsNotTheTVsFaultAndCanBeRetried() {
        let failure = PlaybackFailure.explain(.player, error: URLError(.networkConnectionLost), decision: transcode)
        #expect(failure.why == "The stream stopped arriving from nectar.")
        #expect(failure.retryable)
    }

    @Test func anUnknownPlayerErrorHasNoWhyButKeepsItsCodeAndCanBeRetried() {
        let failure = PlaybackFailure.explain(.player, error: NSError(domain: "CoreMediaErrorDomain", code: -12939), decision: transcode)
        #expect(failure.why == nil)
        #expect(failure.detail == "CoreMediaErrorDomain -12939")
        #expect(failure.retryable)
    }

    @Test func theUnderlyingErrorNamesTheCode() {
        let underlying = NSError(domain: "CoreMediaErrorDomain", code: -12642)
        let error = NSError(domain: "AVFoundationErrorDomain", code: -11800, userInfo: [NSUnderlyingErrorKey: underlying])
        #expect(PlaybackFailure.explain(.player, error: error, decision: direct).detail == "AVFoundationErrorDomain -11800 · CoreMediaErrorDomain -12642")
    }

    @Test func theHeadlineIsOneWordingWithNoFullStop() {
        #expect(PlaybackFailure.headline == "Couldn't play this title")
    }
}
