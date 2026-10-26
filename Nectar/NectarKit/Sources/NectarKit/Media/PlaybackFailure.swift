import Foundation

/// Why a title didn't play, as the TV's failed screen says it (#93, Capping's review of #92): one line in the
/// household's words when the cause is known, and the raw domain and code for admins only, never as the headline.
public struct PlaybackFailure: Equatable, Sendable {

    /// Where the start gave up.
    public enum Stage: Sendable {
        /// Asking nectar how to play it.
        case decide
        /// The player was waiting and no first frame came in time (#91).
        case noFirstFrame
        /// AVPlayer failed the item.
        case player
    }

    /// The one wording everywhere, with no full stop.
    public static let headline = "Couldn't play this title"

    /// One line of why, or `nil` when the TV can't tell.
    public let why: String?
    /// The error's domain and code, and its underlying error's: for admins.
    public let detail: String?
    /// Whether trying again could go differently (Capping, #141). A title nectar no longer has, a file the TV can't
    /// play, or a signed-out TV would only fail the same way, so the screen offers Back alone.
    public let retryable: Bool

    public init(why: String?, detail: String?, retryable: Bool) {
        self.why = why
        self.detail = detail
        self.retryable = retryable
    }

    /// AVFoundation's codes for a file the TV can't open or decode: format not recognised, failed to parse,
    /// decode failed, decoder not found.
    private static let unplayable: Set<Int> = [-11828, -11829, -11821, -11833]

    public static func explain(_ stage: Stage, error: Error?, decision: PlaybackDecision?) -> PlaybackFailure {
        let (why, retryable) = reason(stage, error, decision)
        return PlaybackFailure(why: why, detail: error.flatMap(detail), retryable: retryable)
    }

    /// The why line, a sentence with its full stop as Apple's descriptions have one, and whether a retry can help.
    private static func reason(_ stage: Stage, _ error: Error?, _ decision: PlaybackDecision?) -> (String?, Bool) {
        switch stage {
        case .decide:
            switch error {
            case NectarSessionError.unexpectedStatus(404)?: return ("It isn't in the library any more.", false)
            case let NectarSessionError.unexpectedStatus(status)? where status >= 500: return ("nectar ran into a problem.", true)
            case NectarSessionError.unexpectedStatus?: return ("nectar couldn't send this title.", false)
            case NectarSessionError.signedOut?: return ("This TV was signed out of nectar.", false)
            case let error? where (error as NSError).domain == NSURLErrorDomain: return ("Couldn't reach nectar.", true)
            default: return (nil, true)
            }
        case .noFirstFrame:
            let base = "nectar didn't start sending it in time"
            guard let decision, decision.playMethod == "Transcode", let code = decision.reason, !code.isEmpty else { return ("\(base).", true) }
            return ("\(base) (converting it: \(PlaybackInfo.reason(code))).", true)
        case .player:
            guard let error = error as NSError? else { return (nil, true) }
            if error.domain == NSURLErrorDomain { return ("The stream stopped arriving from nectar.", true) }
            if error.domain == "AVFoundationErrorDomain", unplayable.contains(error.code) { return ("The TV can't play this file.", false) }
            return (nil, true)
        }
    }

    private static func detail(_ error: Error) -> String {
        if case let NectarSessionError.unexpectedStatus(status) = error { return "HTTP \(status)" }
        let error = error as NSError
        let own = "\(error.domain) \(error.code)"
        guard let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError else { return own }
        return "\(own) · \(underlying.domain) \(underlying.code)"
    }
}
