import Foundation
import Testing
@testable import NectarKit

/// Answers 401 to the first API call so a refresh happens, then 200; keeps every request.
private actor Recorder: HTTPTransport {
    private(set) var requests: [URLRequest] = []
    private var apiCalls = 0

    nonisolated func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        try await answer(request)
    }

    private func answer(_ request: URLRequest) throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        let url = request.url!
        if url.path == "/token" {
            return (Data(#"{"access_token":"jwt-2","token_type":"Bearer","expires_in":3600,"refresh_token":"r2"}"#.utf8),
                    HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        apiCalls += 1
        let status = apiCalls == 1 ? 401 : 200
        return (Data(#"{"id":"u1","username":"nate","is_admin":true}"#.utf8), HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }
}

private func session(_ transport: Recorder, client: ClientInfo?) -> NectarSession {
    NectarSession(
        baseURL: URL(string: "https://nectar.test")!,
        tokenEndpoint: URL(string: "https://nectar.test/token")!,
        clientID: "nectar-tv",
        store: InMemoryTokenStore(TokenSet(accessToken: "jwt-1", tokenType: "Bearer", expiresIn: nil, refreshToken: "r1")),
        transport: transport,
        client: client
    )
}

private let tv = ClientInfo(client: "Nectar TV", device: "Master Bedroom TV (2)", deviceID: "A1B2", version: "0.1.0")

@Suite("Client headers")
struct ClientInfoTests {

    @Test func everyRequestNamesTheClientIncludingTheRefresh() async throws {
        let transport = Recorder()
        _ = try await session(transport, client: tv).currentUser()
        let requests = await transport.requests
        #expect(requests.map(\.url!.path) == ["/api/v1/users/me", "/token", "/api/v1/users/me"], "401, refresh, retry")
        for request in requests {
            #expect(request.value(forHTTPHeaderField: "X-Nectar-Client") == "Nectar TV")
            #expect(request.value(forHTTPHeaderField: "X-Nectar-Device") == "Master Bedroom TV (2)")
            #expect(request.value(forHTTPHeaderField: "X-Nectar-Device-Id") == "A1B2")
            #expect(request.value(forHTTPHeaderField: "X-Nectar-Version") == "0.1.0")
            #expect(request.value(forHTTPHeaderField: "X-Nectar-Test") == nil, "a real launch isn't a test")
        }
        #expect(requests[2].value(forHTTPHeaderField: "Authorization") == "Bearer jwt-2", "the token is still the bearer, not a MediaBrowser header")
    }

    @Test func aTestRunSaysSo() async throws {
        let transport = Recorder()
        let tagged = ClientInfo(client: "Nectar TV", device: "TV", deviceID: "A1B2", version: "0.1.0", isTestRun: true)
        _ = try await session(transport, client: tagged).currentUser()
        #expect(await transport.requests.allSatisfy { $0.value(forHTTPHeaderField: "X-Nectar-Test") == "1" })
    }

    @Test func withoutClientInfoNothingIsAdded() async throws {
        let transport = Recorder()
        _ = try await session(transport, client: nil).currentUser()
        #expect(await transport.requests.allSatisfy { $0.value(forHTTPHeaderField: "X-Nectar-Client") == nil })
    }
}
