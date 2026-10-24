import Foundation
import Testing
@testable import NectarKit

/// Controls replies at the HTTP seam, including a server that ignores cancellation.
private actor DirectoryServer: HTTPTransport {
    private var pending: [String: CheckedContinuation<(Data, HTTPURLResponse), Error>] = [:]
    private var requests: [String: URLRequest] = [:]
    private var observers: [String: CheckedContinuation<Void, Never>] = [:]

    nonisolated func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        try await accept(request)
    }
    private func accept(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
        let key = (query.first { $0.name == "search" }?.value ?? "") + ":" + (query.first { $0.name == "offset" }?.value ?? "0")
        requests[key] = request
        observers.removeValue(forKey: key)?.resume()
        return try await withCheckedThrowingContinuation { pending[key] = $0 }
    }
    func observed(_ key: String) async {
        if requests[key] != nil { return }
        await withCheckedContinuation { observers[key] = $0 }
    }
    func waiting(_ key: String) async {
        if pending[key] != nil { return }
        await withCheckedContinuation { observers[key] = $0 }
    }
    func reply(_ key: String, _ body: String, status: Int = 200) {
        let request = requests[key]!
        pending.removeValue(forKey: key)!.resume(returning: (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!))
    }
}

@Suite("People directory state")
@MainActor
struct PeopleBrowserTests {
    private func browser(_ server: DirectoryServer) -> PeopleBrowser {
        PeopleBrowser(session: NectarSession(baseURL: URL(string: "https://nectar.test")!, tokenEndpoint: URL(string: "https://nectar.test/token")!, clientID: "test", store: InMemoryTokenStore(TokenSet(accessToken: "test", tokenType: "Bearer", expiresIn: nil, refreshToken: nil)), transport: server))
    }

    @Test func aLateOldSearchCannotReplaceTheNewQuery() async {
        let server = DirectoryServer()
        let model = browser(server)
        model.query = "old"
        let old = Task { await model.search(debounce: false) }
        await server.observed("old:0")
        model.query = "new"
        let new = Task { await model.search(debounce: false) }
        await server.observed("new:0")
        await server.reply("new:0", #"{"people":[{"id":"new","name":"New result","credit_count":2}],"total":1}"#)
        await new.value
        await server.reply("old:0", #"{"people":[{"id":"old","name":"Stale result","credit_count":99}],"total":77}"#)
        await old.value
        #expect(model.people.map(\.id) == ["new"])
        #expect(model.total == 1 && model.query == "new" && !model.loading && !model.failed)
    }

    @Test func appendFailureKeepsRowsAndRetryUsesTheSameOffset() async {
        let server = DirectoryServer()
        let model = browser(server)
        let first = Task { await model.search(debounce: false) }
        await server.observed(":0")
        await server.reply(":0", #"{"people":[{"id":"p1","name":"First","credit_count":9}],"total":2}"#)
        await first.value
        let append = Task { await model.loadMore() }
        await server.observed(":1")
        await server.reply(":1", #"{"error":"unavailable"}"#, status: 503)
        await append.value
        #expect(model.people.map(\.id) == ["p1"] && model.failed && model.more)
        let retry = Task { await model.loadMore() }
        await server.waiting(":1")
        await server.reply(":1", #"{"people":[{"id":"p2","name":"Second","credit_count":2}],"total":2}"#)
        await retry.value
        #expect(model.people.map(\.id) == ["p1", "p2"])
        #expect(!model.failed && !model.more && !model.loading)
    }
}
