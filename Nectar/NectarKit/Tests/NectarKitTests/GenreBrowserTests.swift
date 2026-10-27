import Foundation
import Testing
@testable import NectarKit

@Suite("Genre titles state")
@MainActor
struct GenreBrowserTests {
    private func browser(_ server: DirectoryServer) -> GenreBrowser {
        GenreBrowser(
            session: NectarSession(baseURL: URL(string: "https://nectar.test")!, tokenEndpoint: URL(string: "https://nectar.test/token")!, clientID: "test", store: InMemoryTokenStore(TokenSet(accessToken: "test", tokenType: "Bearer", expiresIn: nil, refreshToken: nil)), transport: server),
            genre: "Drama"
        )
    }

    private func page(_ ids: [String], total: Int) -> String {
        let items = ids.map { #"{"id":"\#($0)","item_type":"movie","title":"Title \#($0)"}"# }.joined(separator: ",")
        return #"{"items":[\#(items)],"total":\#(total)}"#
    }

    @Test func appendFailureKeepsRowsAndRetryAsksForTheSameOffset() async {
        let server = DirectoryServer()
        let model = browser(server)
        let first = Task { await model.start() }
        await server.observed(":0")
        await server.reply(":0", page(["a", "b"], total: 4))
        await first.value
        let append = Task { await model.loadMore() }
        await server.observed(":2")
        await server.reply(":2", #"{"error":"unavailable"}"#, status: 503)
        await append.value
        #expect(model.cards.map(\.id) == ["a", "b"] && model.failed && model.more && !model.failedReset)
        let retry = Task { await model.load(reset: model.failedReset) }
        await server.waiting(":2")
        await server.reply(":2", page(["c", "d"], total: 4))
        await retry.value
        #expect(model.cards.map(\.id) == ["a", "b", "c", "d"])
        #expect(!model.failed && !model.more && !model.loading)
    }

    @Test func aLateOldPageCannotReplaceTheReloadedGenre() async {
        let server = DirectoryServer()
        let model = browser(server)
        let first = Task { await model.start() }
        await server.observed(":0")
        await server.reply(":0", page(["a", "b"], total: 4))
        await first.value
        let append = Task { await model.loadMore() }
        await server.observed(":2")
        let reload = Task { await model.load(reset: true) }
        await server.waiting(":0")
        await server.reply(":0", page(["new"], total: 1))
        await reload.value
        await server.reply(":2", page(["stale"], total: 4))
        await append.value
        #expect(model.cards.map(\.id) == ["new"] && model.total == 1 && !model.loading && !model.failed)
    }

    @Test func aTitleRepeatedOnALaterPageIsShownOnce() async {
        let server = DirectoryServer()
        let model = browser(server)
        let first = Task { await model.start() }
        await server.observed(":0")
        await server.reply(":0", page(["a", "b"], total: 4))
        await first.value
        let second = Task { await model.loadMore() }
        await server.observed(":2")
        await server.reply(":2", page(["b", "c"], total: 4))
        await second.value
        #expect(model.cards.map(\.id) == ["a", "b", "c"])
    }

    @Test func returningToAGenreKeepsItsPages() async {
        let server = DirectoryServer()
        let model = browser(server)
        let first = Task { await model.start() }
        await server.observed(":0")
        await server.reply(":0", page(["a"], total: 1))
        await first.value
        await server.immediatelyReply(page(["x"], total: 1))
        await model.start()
        #expect(model.cards.map(\.id) == ["a"])
        #expect(await server.requestCount == 1)
    }

    /// Capping on #181: a pull to refresh keeps the old titles until the new first page lands, and a failed one keeps them.
    @Test func aRefreshKeepsItsTitlesInFlightAndWhenItFails() async {
        let server = DirectoryServer()
        let model = browser(server)
        let first = Task { await model.start() }
        await server.observed(":0")
        await server.reply(":0", page(["a", "b"], total: 2))
        await first.value
        let refresh = Task { await model.load(reset: true) }
        await server.waiting(":0")
        #expect(model.cards.map(\.id) == ["a", "b"], "the titles stay while the refresh is in flight")
        #expect(model.refreshing && model.loading, "a refresh over shown titles asks for no placeholders")
        await server.reply(":0", #"{"error":"unavailable"}"#, status: 503)
        await refresh.value
        #expect(model.cards.map(\.id) == ["a", "b"] && model.failed && model.failedReset && !model.refreshing)
    }
}
