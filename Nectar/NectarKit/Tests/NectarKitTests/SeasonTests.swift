import Foundation
import Testing
@testable import NectarKit

private actor Server: HTTPTransport {
    private let body: String
    private(set) var paths: [String] = []

    init(_ body: String) {
        self.body = body
    }

    nonisolated func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        try await answer(request)
    }

    private func answer(_ request: URLRequest) -> (Data, HTTPURLResponse) {
        paths.append(request.url!.path)
        return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}

private func session(_ transport: Server) -> NectarSession {
    NectarSession(
        baseURL: URL(string: "https://nectar.test")!,
        tokenEndpoint: URL(string: "https://nectar.test/token")!,
        clientID: "nectar-tv",
        store: InMemoryTokenStore(TokenSet(accessToken: "jwt-1", tokenType: "Bearer", expiresIn: nil, refreshToken: "r1")),
        transport: transport
    )
}

/// An episode as the children route sends it.
private func episode(_ season: Int?, _ number: Int?, watched: Bool = false, at progress: Double = 0) -> String {
    let id = "s\(season.map(String.init) ?? "x")e\(number.map(String.init) ?? "x")"
    return #"{"id":"\#(id)","episode_number":\#(number.map(String.init) ?? "null"),"season_number":\#(season.map(String.init) ?? "null"),"title":"Episode \#(id)","overview":null,"runtime_seconds":"2700","air_date":null,"watched":\#(watched),"progress_seconds":\#(progress),"thumb_url":"/api/v1/images/t-\#(id)"}"#
}

private func seasons(_ list: [(Int?, [String])]) -> String {
    #"{"seasons":["# + list.map { number, eps in #"{"season_number":\#(number.map(String.init) ?? "null"),"episodes":[\#(eps.joined(separator: ","))]}"# }.joined(separator: ",") + "]}"
}

private func load(_ body: String) async throws -> [Season] {
    try await session(Server(body)).children(of: "series1")
}

@Suite("Seasons and episodes")
struct SeasonTests {

    @Test func childrenComeGroupedAndInOrder() async throws {
        let server = Server(seasons([(1, [episode(1, 1), episode(1, 2)]), (2, [episode(2, 1)]), (nil, [episode(nil, nil)])]))
        let list = try await session(server).children(of: "series1")
        #expect(await server.paths == ["/api/v1/media/series1/children"])
        #expect(list.map(\.number) == [1, 2, nil])
        #expect(list[0].episodes.map(\.id) == ["s1e1", "s1e2"])
        #expect(list[0].title == "Season 1" && list[2].title == "Other episodes")
        #expect(list[0].episodes[0].runtimeSeconds == 2700, "a numeric column can arrive as a string")
        #expect(list[0].episodes[0].label == "E1 · Episode s1e1")
    }

    @Test func nothingWatchedStartsAtTheFirstEpisode() async throws {
        let next = Season.nextUp(in: try await load(seasons([(1, [episode(1, 1), episode(1, 2)])])))
        #expect(next?.episode.id == "s1e1" && next?.resume == nil)
    }

    @Test func anEpisodeInProgressIsResumed() async throws {
        let list = try await load(seasons([(1, [episode(1, 1, watched: true), episode(1, 2, at: 734), episode(1, 3)])]))
        let next = Season.nextUp(in: list)
        #expect(next?.episode.id == "s1e2")
        #expect(next?.resume == 734)
    }

    @Test func afterTheLastWatchedComesTheNextAcrossSeasons() async throws {
        let list = try await load(seasons([(1, [episode(1, 1, watched: true), episode(1, 2, watched: true)]), (2, [episode(2, 1), episode(2, 2)])]))
        let next = Season.nextUp(in: list)
        #expect(next?.episode.id == "s2e1" && next?.resume == nil)
    }

    @Test func theFurthestAlongCountsNotTheFirstGap() async throws {
        // Skipped an episode, then watched further on: carry on from there, not from the gap.
        let list = try await load(seasons([(1, [episode(1, 1, watched: true), episode(1, 2), episode(1, 3, watched: true), episode(1, 4)])]))
        #expect(Season.nextUp(in: list)?.episode.id == "s1e4")
    }

    @Test func specialsAreNeverNextUp() async throws {
        // nectar sorts season 0 first; a fresh series still starts at S1 E1.
        let fresh = try await load(seasons([(0, [episode(0, 1)]), (1, [episode(1, 1), episode(1, 2)])]))
        #expect(Season.nextUp(in: fresh)?.episode.id == "s1e1")
        let finishedSeason = try await load(seasons([(0, [episode(0, 1)]), (1, [episode(1, 1, watched: true)]), (2, [episode(2, 1)])]))
        #expect(Season.nextUp(in: finishedSeason)?.episode.id == "s2e1")
        #expect(fresh[0].title == "Specials")
        let unnumbered = try await load(seasons([(nil, [episode(nil, nil)])]))
        #expect(unnumbered[0].title == "Other episodes", "not a second Specials")
    }

    @Test func allWatchedHasNothingNext() async throws {
        let list = try await load(seasons([(1, [episode(1, 1, watched: true)])]))
        #expect(Season.nextUp(in: list) == nil)
    }

    @Test func anEpisodePlaysAsItsOwnCardFromWhereItStopped() async throws {
        let list = try await load(seasons([(2, [episode(2, 4, at: 90)])]))
        let card = list[0].episodes[0].card(series: "Severance")
        #expect(card.itemType == "episode" && card.seriesTitle == "Severance")
        #expect(card.seasonNumber == 2 && card.episodeNumber == 4)
        #expect(card.progressSeconds == 90)
        #expect(card.posterPath == "/api/v1/images/t-s2e4")
        let watched = try await load(seasons([(2, [episode(2, 4, watched: true, at: 2690)])]))
        #expect(watched[0].episodes[0].card(series: "Severance").progressSeconds == nil, "a watched episode starts over")
    }
}
