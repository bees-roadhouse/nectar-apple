import Foundation
import Testing
@testable import NectarKit

private let tokenURL = URL(string: "https://nectar.test/token")!
private let nate = NectarUser(id: "u1", username: "nate", isAdmin: true)

@Suite("Launch check")
struct LaunchCheckTests {

    @Test func storedTokensAndAnAnswerMeanSignedIn() async {
        let result = await LaunchCheck.run(hasTokens: true, discover: { tokenURL }, currentUser: { endpoint in
            #expect(endpoint == tokenURL)
            return nate
        })
        #expect(result == .signedIn(nate))
    }

    @Test func noTokensMeansSignedOutWithoutAskingNectar() async {
        let result = await LaunchCheck.run(
            hasTokens: false,
            discover: { Issue.record("discovery called without tokens"); return tokenURL },
            currentUser: { _ in Issue.record("users/me called without tokens"); return nate }
        )
        #expect(result == .signedOut)
    }

    @Test func aRefusedSessionMeansSignedOut() async {
        let result = await LaunchCheck.run(hasTokens: true, discover: { tokenURL }, currentUser: { _ in
            throw NectarSessionError.signedOut
        })
        #expect(result == .signedOut)
    }

    /// The 2026-10-18 case: a deploy answered 503 on discovery, and the app showed sign-in.
    @Test(arguments: [
        DeviceFlowError.unexpectedStatus(503) as Error,
        URLError(.notConnectedToInternet) as Error,
        URLError(.timedOut) as Error,
    ])
    func discoveryFailingMeansUnreachable(error: Error) async {
        let result = await LaunchCheck.run(hasTokens: true, discover: { throw error }, currentUser: { _ in nate })
        #expect(result == .unreachable)
    }

    @Test(arguments: [
        NectarSessionError.unexpectedStatus(502) as Error,
        NectarSessionError.unexpectedStatus(503) as Error,
        URLError(.networkConnectionLost) as Error,
    ])
    func usersMeFailingWithoutARefusalMeansUnreachable(error: Error) async {
        let result = await LaunchCheck.run(hasTokens: true, discover: { tokenURL }, currentUser: { _ in throw error })
        #expect(result == .unreachable)
    }
}
