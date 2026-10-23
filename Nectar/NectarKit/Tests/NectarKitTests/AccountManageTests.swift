import Foundation
import Testing
@testable import NectarKit

private actor Server: HTTPTransport {
    private let answers: [String: (Int, String)]
    private(set) var requests: [URLRequest] = []

    init(_ answers: [String: (Int, String)]) {
        self.answers = answers
    }

    nonisolated func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        try await answer(request)
    }

    private func answer(_ request: URLRequest) throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        let key = "\(request.httpMethod ?? "GET") \(request.url!.path)"
        guard let (status, body) = answers[key] else { throw URLError(.fileDoesNotExist) }
        return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }
}

private func session(_ transport: Server, store: InMemoryTokenStore = InMemoryTokenStore(TokenSet(accessToken: "jwt-1", tokenType: "Bearer", expiresIn: nil, refreshToken: "r1"))) -> NectarSession {
    NectarSession(
        baseURL: URL(string: "https://nectar.test")!,
        tokenEndpoint: URL(string: "https://nectar.test/token")!,
        clientID: "nectar-ios",
        store: store,
        transport: transport
    )
}

private func body(_ request: URLRequest?) throws -> [String: Any] {
    try #require(JSONSerialization.jsonObject(with: request?.httpBody ?? Data()) as? [String: Any])
}

@Suite("Managing the account (#165)")
struct AccountManageTests {

    /// A wrong current password is nectar's 401. It must be said in words, and must not refresh the token or sign the
    /// app out, which is what the usual 401 handling does.
    @Test func aWrongCurrentPasswordIsAnAnswerNotASignOut() async throws {
        let server = Server(["PUT /api/v1/users/me/password": (401, #"{"error":"unauthorized"}"#)])
        let store = InMemoryTokenStore(TokenSet(accessToken: "jwt-1", tokenType: "Bearer", expiresIn: nil, refreshToken: "r1"))
        await #expect(throws: NectarSessionError.refused(401, "The current password isn't right.")) {
            try await session(server, store: store).changePassword(current: "wrong", new: "a-long-new-password")
        }
        #expect(await server.requests.count == 1)
        #expect(await server.requests.first?.url?.path == "/api/v1/users/me/password")
        #expect(store.tokens?.accessToken == "jwt-1")
        let sent = try body(await server.requests.first)
        #expect(sent["current_password"] as? String == "wrong" && sent["new_password"] as? String == "a-long-new-password")
    }

    /// nectar #830: the device that changed the password keeps going on the pair it's handed back.
    @Test func aPasswordChangeKeepsThisDeviceOnItsNewPair() async throws {
        let server = Server(["PUT /api/v1/users/me/password": (200, #"{"ok":true,"token":"jwt-2","device":{"access_token":"jwt-2","refresh_token":"r2","expires_in":900}}"#)])
        let store = InMemoryTokenStore(TokenSet(accessToken: "jwt-1", tokenType: "Bearer", expiresIn: nil, refreshToken: "r1"))
        #expect(try await session(server, store: store).changePassword(current: "old-password-long", new: "a-long-new-password"))
        #expect(store.tokens?.accessToken == "jwt-2" && store.tokens?.refreshToken == "r2")
    }

    /// Before #830 the answer has no pair: everything was revoked, and the app signs in again.
    @Test func aPasswordChangeWithoutAPairMeansSigningInAgain() async throws {
        let server = Server(["PUT /api/v1/users/me/password": (200, #"{"ok":true,"token":"web-jwt"}"#)])
        let store = InMemoryTokenStore(TokenSet(accessToken: "jwt-1", tokenType: "Bearer", expiresIn: nil, refreshToken: "r1"))
        #expect(try await session(server, store: store).changePassword(current: "old-password-long", new: "a-long-new-password") == false)
        #expect(store.tokens?.refreshToken == "r1")
    }

    @Test func aWrongCurrentPasswordSaysSoInNectarsWords() async throws {
        let server = Server(["PUT /api/v1/users/me/password": (400, #"{"error":"the current password is wrong"}"#)])
        await #expect(throws: NectarSessionError.refused(400, "the current password is wrong")) {
            try await session(server).changePassword(current: "wrong", new: "a-long-new-password")
        }
    }

    @Test func aRefusalCarriesNectarsWords() async throws {
        let server = Server(["DELETE /api/v1/users/me/identities/keycloak": (400, #"{"error":"This is the account's only way in."}"#)])
        await #expect(throws: NectarSessionError.refused(400, "This is the account's only way in.")) {
            try await session(server).unlink(provider: "keycloak")
        }
    }

    @Test func renamingSendsTheName() async throws {
        let server = Server(["PATCH /api/v1/auth/devices/d1": (200, #"{"ok":true,"device_name":"Nate's iPhone"}"#)])
        let kept = try await session(server).rename(device: "d1", to: "Nate's iPhone")
        #expect(kept == "Nate's iPhone")
        #expect(try body(await server.requests.last)["name"] as? String == "Nate's iPhone")
    }

    @Test func providersAreMarkedWithThisAccountsLinks() async throws {
        let server = Server([
            "GET /api/v1/settings/setup-status": (200, #"{"providers":[{"id":"keycloak","name":"Roadhouse","account_url":"https://id.test/realms/r/account/#/security/signingin"},{"id":"google","name":"Google","account_url":null}]}"#),
            "GET /api/v1/users/me/identities": (200, #"{"identities":[{"provider_id":"keycloak"}]}"#),
        ])
        let providers = try await session(server).signInProviders()
        #expect(providers == [
            SignInProvider(id: "keycloak", name: "Roadhouse", linked: true, accountURL: URL(string: "https://id.test/realms/r/account/#/security/signingin")),
            SignInProvider(id: "google", name: "Google", linked: false),
        ])
    }

    @Test func aNewCredentialAcceptsTheRiskShown() async throws {
        let server = Server(["POST /api/v1/users/me/jellyfin-credentials": (200, #"{"id":"c1","username":"nate-infuse","password":"once-only"}"#)])
        let made = try await session(server).createJellyfinCredential(label: "Infuse", riskVersion: "2026-10-17")
        #expect(made == NewJellyfinCredential(id: "c1", username: "nate-infuse", password: "once-only"))
        let sent = try body(await server.requests.last)
        #expect(sent["label"] as? String == "Infuse" && sent["accept_risk"] as? Bool == true && sent["risk_version"] as? String == "2026-10-17")
    }

    @Test func approvingSendsTheCode() async throws {
        let server = Server(["POST /api/v1/auth/device": (200, #"{"code":"ABCD-EFGH","status":"approved"}"#)])
        #expect(try await session(server).decide(code: "ABCD-EFGH", approve: true) == "approved")
        let sent = try body(await server.requests.last)
        #expect(sent["code"] as? String == "ABCD-EFGH" && sent["approve"] as? Bool == true)
    }

    @Test func theNewPreferenceFieldsReadAndWrite() {
        var p = Preferences(document: Data(#"{"locale":"en-US","time_zone":"America/New_York","max_streaming_bitrate":40000000,"theme":"dark"}"#.utf8))
        #expect(p.locale == "en-US" && p.timeZone == "America/New_York" && p.maxStreamingBitrate == 40_000_000)
        p.maxStreamingBitrate = nil
        p.timeZone = "Europe/London"
        #expect(p.maxStreamingBitrate == nil && p.timeZone == "Europe/London")
        let all = (try? JSONSerialization.jsonObject(with: p.data) as? [String: Any]) ?? [:]
        #expect(all["theme"] as? String == "dark")
        #expect(all["max_streaming_bitrate"] is NSNull)
    }
}
