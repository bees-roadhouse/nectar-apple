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
    /// Bumped for each `nectar://` link followed while signed in, to rebuild the signed-in app (see `NectarTVApp`).
    private(set) var linkGeneration = 0
    /// A link that arrived before anyone was signed in (a cold launch from a link, #78).
    private var pendingLink: NectarLink?

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
            signedIn(user, resumed)
        case .signedOut:
            beginSignIn()
        case .unreachable:
            state = .unreachable
        }
    }

    /// A `nectar://` link: followed now when someone is signed in, or once they are.
    func open(_ url: URL) {
        guard let link = NectarLink(url: url) else { return }
        guard case let .signedIn(_, home) = state else {
            pendingLink = link
            return
        }
        home.follow(link)
        linkGeneration += 1
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
            signedIn(user, session)
        } else {
            beginSignIn()
        }
    }

    private func signedIn(_ user: NectarUser, _ session: NectarSession) {
        let home = HomeModel(session: session) { [weak self] in self?.signOut() }
        if let pendingLink {
            home.follow(pendingLink)
            self.pendingLink = nil
        }
        state = .signedIn(user, home)
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
