import Foundation
import NectarKit
import UIKit

/// Where the app is: deciding, signing in on this TV, signed in, or unable to reach nectar.
@MainActor
@Observable
final class AppModel {

    enum State {
        case starting
        case signingIn(SignInModel)
        case signedIn(NectarUser, HomeModel)
        /// Signed in, as far as we know, but nectar didn't answer. Retry, never the sign-in code.
        case unreachable
    }

    /// nectar's public address. Its discovery document names the device and token endpoints.
    static let server = URL(string: ProcessInfo.processInfo.environment["NECTAR_SERVER"] ?? "https://nectar.beesroadhouse.com")!
    static let clientID = "nectar-tv"

    private(set) var state: State = .starting

    private let store = KeychainTokenStore(server: AppModel.server)
    private var session: NectarSession?

    func start() async {
        guard case .starting = state else { return }
        await resume()
    }

    func retry() async {
        guard case .unreachable = state else { return }
        state = .starting
        await resume()
    }

    /// Picks up a stored sign-in. Only nectar refusing it leads to the sign-in code (#19).
    private func resume() async {
        var resumed: NectarSession?
        let check = await LaunchCheck.run(
            hasTokens: store.tokens != nil,
            discover: { try await DeviceFlowClient(issuer: Self.server, clientID: Self.clientID, deviceName: "").discover().token },
            currentUser: { [session, store] tokenEndpoint in
                let candidate = session ?? NectarSession(baseURL: Self.server, tokenEndpoint: tokenEndpoint, clientID: Self.clientID, store: store, client: .thisTV)
                resumed = candidate
                return try await candidate.currentUser()
            }
        )
        switch check {
        case let .signedIn(user):
            guard let resumed else { return beginSignIn() }
            session = resumed
            state = .signedIn(user, home(resumed))
        case .signedOut:
            beginSignIn()
        case .unreachable:
            state = .unreachable
        }
    }

    func signOut() {
        Task { await session?.signOut() }
        store.save(nil)
        beginSignIn()
    }

    private func beginSignIn() {
        let flow = DeviceFlowClient(issuer: Self.server, clientID: Self.clientID, deviceName: UIDevice.current.name)
        let signIn = SignInModel(flow: flow) { [weak self] tokens, endpoints in
            await self?.finishSignIn(tokens, tokenEndpoint: endpoints.token)
        }
        state = .signingIn(signIn)
        signIn.run()
    }

    private func finishSignIn(_ tokens: TokenSet, tokenEndpoint: URL) async {
        store.save(tokens)
        let session = NectarSession(baseURL: Self.server, tokenEndpoint: tokenEndpoint, clientID: Self.clientID, store: store, client: .thisTV)
        self.session = session
        if let user = try? await session.currentUser() {
            state = .signedIn(user, home(session))
        } else {
            beginSignIn()
        }
    }

    private func home(_ session: NectarSession) -> HomeModel {
        HomeModel(session: session) { [weak self] in self?.signOut() }
    }
}

extension ClientInfo {
    /// This Apple TV, as nectar names it in sessions and activity: its own name, its vendor id (stable while
    /// the app stays installed), and the app's version. Launched by the developer's tools with
    /// `NECTAR_TEST_RUN` set, every request says it's a test (nectar-apple#59).
    @MainActor
    static var thisTV: ClientInfo {
        ClientInfo(
            client: "Nectar TV",
            device: UIDevice.current.name,
            deviceID: UIDevice.current.identifierForVendor?.uuidString ?? "unknown",
            version: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0",
            isTestRun: ProcessInfo.processInfo.environment["NECTAR_TEST_RUN"] != nil
        )
    }
}
