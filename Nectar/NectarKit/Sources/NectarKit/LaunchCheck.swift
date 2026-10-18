import Foundation

/// What a launch found: who is signed in, that nobody is, or that nectar couldn't be asked.
///
/// Only nectar refusing the session means signed out. No network, a 5xx, or a deploy mid-roll
/// means unreachable: the tokens are still good, so the app offers a retry, not the sign-in code.
public enum LaunchCheck: Equatable, Sendable {
    case signedIn(NectarUser)
    case signedOut
    case unreachable

    /// - Parameters:
    ///   - hasTokens: whether the store holds a token pair at all.
    ///   - discover: nectar's token endpoint, from its discovery document.
    ///   - currentUser: `/api/v1/users/me` through a session built on that endpoint.
    public static func run(
        isolation: isolated (any Actor)? = #isolation,
        hasTokens: Bool,
        discover: () async throws -> URL,
        currentUser: (URL) async throws -> NectarUser
    ) async -> LaunchCheck {
        guard hasTokens else { return .signedOut }
        do {
            let tokenEndpoint = try await discover()
            return .signedIn(try await currentUser(tokenEndpoint))
        } catch {
            return classify(error)
        }
    }

    static func classify(_ error: Error) -> LaunchCheck {
        error as? NectarSessionError == .signedOut ? .signedOut : .unreachable
    }
}
