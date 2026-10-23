import Foundation
import NectarKit
import UIKit

/// Where the iPhone app is: deciding, signing in on this phone, signed in, or unable to reach nectar (#156). The TV's
/// `AppModel`, less the links and Siri, which come with later slices.
@MainActor
@Observable
final class PhoneModel {

    enum State {
        case starting
        case signingIn(SignInModel)
        case signedIn(NectarSession)
        /// Signed in, as far as we know, but nectar didn't answer. Retry, never the sign-in code.
        case unreachable
    }

    /// nectar's public address. Its discovery document names the device and token endpoints.
    static let server = URL(string: ProcessInfo.processInfo.environment["NECTAR_SERVER"] ?? "https://nectar.beesroadhouse.com")!
    /// The iOS shell's device-grant client until nectar registers `nectar-ios` (asked of Forage, 2026-10-23).
    static let clientID = "nectar-ipad"

    private(set) var state: State = .starting
    private let store = KeychainTokenStore(server: PhoneModel.server)

    func start() async {
        guard case .starting = state else { return }
        await resume()
    }

    func retry() async {
        guard case .unreachable = state else { return }
        state = .starting
        await resume()
    }

    /// Picks up a stored sign-in. Only nectar refusing it leads to the sign-in code.
    private func resume() async {
        var resumed: NectarSession?
        let check = await LaunchCheck.run(
            hasTokens: store.tokens != nil,
            discover: { try await DeviceFlowClient(issuer: Self.server, clientID: Self.clientID, deviceName: "").discover().token },
            currentUser: { [store] tokenEndpoint in
                let candidate = NectarSession(baseURL: Self.server, tokenEndpoint: tokenEndpoint, clientID: Self.clientID, store: store, client: .thisPhone)
                resumed = candidate
                return try await candidate.currentUser()
            }
        )
        switch check {
        case .signedIn:
            guard let resumed else { return beginSignIn() }
            state = .signedIn(resumed)
        case .signedOut:
            beginSignIn()
        case .unreachable:
            state = .unreachable
        }
    }

    /// The session is over, from the web (Sign out, a refused token) or from here: back to the code screen.
    func signOut() {
        if case let .signedIn(session) = state {
            Task { await session.signOut() }
        }
        store.save(nil)
        beginSignIn()
    }

    private func beginSignIn() {
        let flow = DeviceFlowClient(issuer: Self.server, clientID: Self.clientID, deviceName: "Nectar on \(UIDevice.current.model)")
        let signIn = SignInModel(flow: flow) { [weak self] tokens, endpoints in
            await self?.finishSignIn(tokens, tokenEndpoint: endpoints.token)
        }
        state = .signingIn(signIn)
        signIn.run()
    }

    private func finishSignIn(_ tokens: TokenSet, tokenEndpoint: URL) async {
        store.save(tokens)
        state = .signedIn(NectarSession(baseURL: Self.server, tokenEndpoint: tokenEndpoint, clientID: Self.clientID, store: store, client: .thisPhone))
    }
}

extension ClientInfo {
    /// This phone, as nectar names it in sessions and activity.
    @MainActor
    static var thisPhone: ClientInfo {
        ClientInfo(
            client: "Nectar for \(UIDevice.current.model)",
            device: UIDevice.current.name,
            deviceID: UIDevice.current.identifierForVendor?.uuidString ?? "unknown",
            version: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0",
            isTestRun: ProcessInfo.processInfo.environment["NECTAR_TEST_RUN"] != nil
        )
    }
}
