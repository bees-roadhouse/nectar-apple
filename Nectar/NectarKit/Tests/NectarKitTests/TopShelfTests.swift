import Foundation
@testable import NectarKit
import Testing

struct TopShelfFeedTests {

    /// Stands in for `NectarSession.resolve(_:pixelWidth:)`, so the width asked for shows in the URL.
    private let resolve: (String?, Double) -> URL? = { path, width in
        path.flatMap { URL(string: "https://nectar.test\($0)/w\(Int(width))") }
    }

    private func card(_ id: String, type: String = "movie", title: String? = nil, poster: String? = nil, backdrop: String? = nil,
                      runtime: Double? = nil, progress: Double? = nil, series: String? = nil, season: Int? = nil, episode: Int? = nil) -> MediaCard {
        MediaCard(id: id, itemType: type, title: title ?? id, seriesTitle: series, runtimeSeconds: runtime, seasonNumber: season, episodeNumber: episode,
                  posterPath: poster, backdropPath: backdrop, progressSeconds: progress)
    }

    @Test func continueWatchingIsWideWithProgressAndResumesOnEitherButton() throws {
        let feed = TopShelfFeed.make(
            watching: [card("arrival", backdrop: "/api/v1/images/b1", runtime: 6960, progress: 1740)],
            recent: [], resolve: resolve
        )
        let item = try #require(feed.watching.first)
        #expect(item.title == "arrival")
        #expect(item.image?.absoluteString == "https://nectar.test/api/v1/images/b1/w960")
        #expect(item.progress == 0.25)
        #expect(item.open == NectarLink.play("arrival").url)
        #expect(item.play == NectarLink.play("arrival").url)
    }

    @Test func anEpisodeIsNamedBySeriesAndNumberAndFallsBackToItsPoster() throws {
        let feed = TopShelfFeed.make(
            watching: [card("ep", type: "episode", title: "Offred", poster: "/api/v1/images/p1", series: "The Handmaid's Tale", season: 1, episode: 1)],
            recent: [], resolve: resolve
        )
        let item = try #require(feed.watching.first)
        #expect(item.title == "The Handmaid's Tale · S1 E1")
        #expect(item.image?.absoluteString == "https://nectar.test/api/v1/images/p1/w960")
        #expect(item.progress == nil)
    }

    @Test func newIsPostersOfFilmsAndSeriesNotAlreadyBeingWatched() {
        let feed = TopShelfFeed.make(
            watching: [card("arrival")],
            recent: [card("arrival"), card("dune", poster: "/api/v1/images/d"), card("house", type: "series"), card("album", type: "album")],
            resolve: resolve
        )
        #expect(feed.new.map(\.id) == ["dune", "house"])
        #expect(feed.new.first?.image?.absoluteString == "https://nectar.test/api/v1/images/d/w480")
        #expect(feed.new.allSatisfy { $0.progress == nil })
    }

    @Test func aFilmPlaysFromTheShelfButASeriesOpensItsEpisodes() throws {
        let feed = TopShelfFeed.make(watching: [], recent: [card("dune"), card("house", type: "series")], resolve: resolve)
        let film = try #require(feed.new.first { $0.id == "dune" })
        let series = try #require(feed.new.first { $0.id == "house" })
        #expect(film.open == NectarLink.item("dune").url)
        #expect(film.play == NectarLink.play("dune").url)
        #expect(series.open == NectarLink.item("house").url)
        #expect(series.play == NectarLink.item("house").url)
    }

    @Test func eachSectionKeepsTen() {
        let many = (0 ..< 25).map { card("m\($0)") }
        let feed = TopShelfFeed.make(watching: Array(many.prefix(15)), recent: Array(many.suffix(15)), resolve: resolve)
        #expect(feed.watching.count == 10)
        #expect(feed.new.count == 10)
        #expect(feed.new.first?.id == "m15")
    }

    @Test func nothingWatchedOrNewIsEmpty() {
        #expect(TopShelfFeed.make(watching: [], recent: [card("album", type: "album")], resolve: resolve).isEmpty)
        #expect(!TopShelfFeed.make(watching: [card("a")], recent: [], resolve: resolve).isEmpty)
    }

    @Test func theFeedSurvivesTheTripThroughTheKeychainAsJSON() throws {
        let feed = TopShelfFeed.make(
            watching: [card("arrival", backdrop: "/api/v1/images/b1", runtime: 100, progress: 50)],
            recent: [card("dune", poster: "/api/v1/images/d")], resolve: resolve
        )
        let back = try JSONDecoder().decode(TopShelfFeed.self, from: try JSONEncoder().encode(feed))
        #expect(back == feed)
        #expect(back.watching.count == 1 && back.new.count == 1)
    }
}
