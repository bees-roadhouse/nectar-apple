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

    public init(why: String?, detail: String?) {
        self.why = why
        self.detail = detail
    }

    /// AVFoundation's codes for a file the TV can't open or decode: format not recognised, failed to parse,
    /// decode failed, decoder not found.
    private static let unplayable: Set<Int> = [-11828, -11829, -11821, -11833]

    public static func explain(_ stage: Stage, error: Error?, decision: PlaybackDecision?) -> PlaybackFailure {
        PlaybackFailure(why: why(stage, error, decision), detail: error.flatMap(detail))
    }

    private static func why(_ stage: Stage, _ error: Error?, _ decision: PlaybackDecision?) -> String? {
        switch stage {
        case .decide:
            switch error {
            case NectarSessionError.unexpectedStatus?: return "nectar couldn't send this title"
            case NectarSessionError.signedOut?: return "This TV was signed out of nectar"
            case let error? where (error as NSError).domain == NSURLErrorDomain: return "Couldn't reach nectar"
            default: return nil
            }
        case .noFirstFrame:
            let base = "nectar didn't start sending it in time"
            guard let decision, decision.playMethod == "Transcode", let code = decision.reason, !code.isEmpty else { return base }
            return "\(base) (converting it: \(PlaybackInfo.reason(code)))"
        case .player:
            guard let error = error as NSError? else { return nil }
            if error.domain == NSURLErrorDomain { return "The stream stopped arriving from nectar" }
            if error.domain == "AVFoundationErrorDomain", unplayable.contains(error.code) { return "The TV can't play this file" }
            return nil
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
