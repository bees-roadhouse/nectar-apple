import Foundation
import NectarKit
import UIKit

/// Where the app is: deciding, signing in on this TV, or signed in.
@MainActor
@Observable
final class AppModel {

    enum State {
        case starting
        case signingIn(SignInModel)
        case signedIn(NectarUser, HomeModel)
    }

    /// nectar's public address. Its discovery document names the device and token endpoints.
    static let server = URL(string: ProcessInfo.processInfo.environment["NECTAR_SERVER"] ?? "https://nectar.beesroadhouse.com")!
    static let clientID = "nectar-tv"

    private(set) var state: State = .starting

    private let store = KeychainTokenStore(server: AppModel.server)
    private var session: NectarSession?

    func start() async {
        guard case .starting = state else { return }

        if store.tokens != nil, let session = try? await makeSession(), let user = try? await session.currentUser() {
            state = .signedIn(user, home(session))
            return
        }
        beginSignIn()
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
        let session = NectarSession(baseURL: Self.server, tokenEndpoint: tokenEndpoint, clientID: Self.clientID, store: store)
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

    private func makeSession() async throws -> NectarSession {
        if let session { return session }
        let endpoints = try await DeviceFlowClient(issuer: Self.server, clientID: Self.clientID, deviceName: "").discover()
        let session = NectarSession(baseURL: Self.server, tokenEndpoint: endpoints.token, clientID: Self.clientID, store: store)
        self.session = session
        return session
    }
}
