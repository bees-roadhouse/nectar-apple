import Foundation
import Testing
@testable import NectarKit

/// Answers by path, counts calls, and can hold refreshes open so concurrent 401s overlap.
private actor RoutedTransport: HTTPTransport {

    private var routes: [String: [(Int, String)]]
    private(set) var calls: [String: Int] = [:]
    private(set) var seenAuthorization: [String] = []
    private(set) var refreshBodies: [String] = []

    init(_ routes: [String: [(Int, String)]]) {
        self.routes = routes
    }

    nonisolated func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        try await answer(request)
    }

    private func answer(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let path = request.url!.path
        calls[path, default: 0] += 1
        if let header = request.value(forHTTPHeaderField: "Authorization") { seenAuthorization.append(header) }
        if path == "/token" {
            refreshBodies.append(String(decoding: request.httpBody ?? Data(), as: UTF8.self))
            try await Task.sleep(for: .milliseconds(50))
        }
        guard var queue = routes[path], !queue.isEmpty else { throw URLError(.fileDoesNotExist) }
        let (status, body) = queue.count > 1 ? queue.removeFirst() : queue[0]
        routes[path] = queue
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        return (Data(body.utf8), response)
    }
}

private let issuer = URL(string: "https://nectar.test")!
private let tokenURL = URL(string: "https://nectar.test/token")!
private let me = #"{"id":"u1","username":"pia","email":null,"is_admin":true}"#
private let rotated = #"{"access_token":"jwt-2","token_type":"Bearer","expires_in":86400,"refresh_token":"r2"}"#

private func session(_ transport: RoutedTransport, _ store: InMemoryTokenStore) -> NectarSession {
    NectarSession(baseURL: issuer, tokenEndpoint: tokenURL, clientID: "nectar-tv", store: store, transport: transport)
}

@Suite("Signed-in session")
struct SessionTests {

    @Test func sendsTheAccessTokenAsBearer() async throws {
        let store = InMemoryTokenStore(TokenSet(accessToken: "jwt-1", tokenType: "Bearer", expiresIn: nil, refreshToken: "r1"))
        let transport = RoutedTransport(["/api/v1/users/me": [(200, me)]])
        let user = try await session(transport, store).currentUser()
        #expect(user == NectarUser(id: "u1", username: "pia", isAdmin: true))
        #expect(await transport.seenAuthorization == ["Bearer jwt-1"])
    }

    @Test func refreshesOnceOn401ThenRetriesWithTheRotatedToken() async throws {
        let store = InMemoryTokenStore(TokenSet(accessToken: "jwt-1", tokenType: "Bearer", expiresIn: nil, refreshToken: "r1"))
        let transport = RoutedTransport([
            "/api/v1/users/me": [(401, "{}"), (200, me)],
            "/token": [(200, rotated)],
        ])
        _ = try await session(transport, store).currentUser()
        #expect(await transport.seenAuthorization == ["Bearer jwt-1", "Bearer jwt-2"])
        #expect(store.tokens?.refreshToken == "r2")
        let body = await transport.refreshBodies.first ?? ""
        #expect(body.contains("grant_type=refresh_token"))
        #expect(body.contains("refresh_token=r1"))
        #expect(body.contains("client_id=nectar-tv"))
    }

    @Test func concurrent401sShareOneRefresh() async throws {
        let store = InMemoryTokenStore(TokenSet(accessToken: "jwt-1", tokenType: "Bearer", expiresIn: nil, refreshToken: "r1"))
        let transport = RoutedTransport([
            "/api/v1/users/me": [(401, "{}"), (401, "{}"), (401, "{}"), (200, me)],
            "/token": [(200, rotated)],
        ])
        let nectar = session(transport, store)
        async let a = nectar.currentUser()
        async let b = nectar.currentUser()
        async let c = nectar.currentUser()
        _ = try await (a, b, c)
        #expect(await transport.calls["/token"] == 1)
    }

    @Test func rejectedRefreshSignsOut() async throws {
        let store = InMemoryTokenStore(TokenSet(accessToken: "jwt-1", tokenType: "Bearer", expiresIn: nil, refreshToken: "r1"))
        let transport = RoutedTransport([
            "/api/v1/users/me": [(401, "{}")],
            "/token": [(400, #"{"error":"invalid_grant"}"#)],
        ])
        await #expect(throws: NectarSessionError.signedOut) {
            try await session(transport, store).currentUser()
        }
        #expect(store.tokens == nil)
    }

    @Test func aWebViewGetsTheCurrentTokenAndAFreshOneOnlyForTheStaleOne() async throws {
        // The iPhone app's web views take their token from the session, which owns the one refresh (#156).
        let store = InMemoryTokenStore(TokenSet(accessToken: "jwt-1", tokenType: "Bearer", expiresIn: nil, refreshToken: "r1"))
        let transport = RoutedTransport(["/token": [(200, rotated)]])
        let nectar = session(transport, store)
        #expect(try await nectar.webToken() == "jwt-1")
        #expect(await transport.calls["/token"] == nil, "no refresh for a token nobody refused")
        #expect(try await nectar.webToken(replacing: "jwt-1") == "jwt-2")
        #expect(try await nectar.webToken(replacing: "jwt-1") == "jwt-2", "a second view refused with the old one gets the new")
        #expect(await transport.calls["/token"] == 1)
    }

    @Test func noTokensMeansSignedOut() async throws {
        let transport = RoutedTransport([:])
        await #expect(throws: NectarSessionError.signedOut) {
            try await session(transport, InMemoryTokenStore(nil)).currentUser()
        }
        #expect(await transport.calls.isEmpty)
    }
}
