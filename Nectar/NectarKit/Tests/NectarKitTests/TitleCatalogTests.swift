import Foundation
@testable import NectarKit
import Testing

/// Answers `/api/v1/media` by `type` and `offset`, as nectar pages it, and records what was asked.
private actor PagedLibrary: HTTPTransport {
    private let films: [String]
    private let series: [String]
    private(set) var asked: [String] = []

    init(films: Int, series: Int) {
        self.films = (0 ..< films).map { "f\($0)" }
        self.series = (0 ..< series).map { "s\($0)" }
    }

    nonisolated func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        try await answer(request)
    }

    private func answer(_ request: URLRequest) throws -> (Data, HTTPURLResponse) {
        let items = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let value = { (name: String) in items.first { $0.name == name }?.value }
        let type = value("type") ?? "", offset = Int(value("offset") ?? "0") ?? 0, limit = Int(value("limit") ?? "60") ?? 60
        asked.append("\(type)@\(offset)/\(limit)")
        let all = type == "movie" ? films : series
        let page = all.dropFirst(offset).prefix(limit).map { id in
            #"{"id":"\#(id)","item_type":"\#(type)","title":"Title \#(id)","year":2020}"#
        }
        let body = #"{"items":[\#(page.joined(separator: ","))],"total":\#(all.count)}"#
        return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}

private func session(_ transport: PagedLibrary) -> NectarSession {
    NectarSession(
        baseURL: URL(string: "https://nectar.test")!,
        tokenEndpoint: URL(string: "https://nectar.test/token")!,
        clientID: "nectar-tv",
        store: InMemoryTokenStore(TokenSet(accessToken: "jwt-1", tokenType: "Bearer", expiresIn: nil, refreshToken: "r1")),
        transport: transport
    )
}

private func title(_ id: String, _ name: String, year: Int? = nil, type: String = "movie") -> TitleCatalog.Title {
    TitleCatalog.Title(id: id, title: name, year: year, itemType: type)
}

struct TitleCatalogTests {

    @Test(arguments: [
        ("The Handmaid's Tale", "handmaids tale"),
        ("Spider-Man: Brand New Day", "spider man brand new day"),
        ("Amélie", "amelie"),
        ("Fast & Furious", "fast and furious"),
        ("  THE   Matrix ", "matrix"),
        ("The", "the"),
        ("WALL·E", "wall e"),
    ])
    func spokenAndWrittenTitlesNormalizeAlike(_ written: String, _ expected: String) {
        #expect(TitleCatalog.normalized(written) == expected)
    }

    @Test func theWholeTitleBeatsOneThatStartsWithItWhichBeatsOneThatOnlyContainsIt() {
        let catalog = TitleCatalog(titles: [title("3", "Aliens"), title("2", "Alien: Romulus"), title("1", "Alien")], fetchedAt: .now)
        #expect(catalog.matching("alien").map(\.id) == ["1", "2", "3"])
    }

    @Test func spokenWithoutPunctuationOrTheArticleStillFinds() {
        let catalog = TitleCatalog(titles: [title("h", "The Handmaid's Tale", type: "series"), title("s", "Spider-Man: Brand New Day")], fetchedAt: .now)
        #expect(catalog.matching("handmaids tale").first?.id == "h")
        #expect(catalog.matching("Spider Man Brand New Day").first?.id == "s")
        #expect(catalog.matching("new day spider man").first?.id == "s")
    }

    @Test func tiesGoToTheShorterTitleThenTheNewer() {
        let catalog = TitleCatalog(titles: [
            title("long", "Dune Part Two", year: 2024), title("old", "Dune", year: 1984), title("new", "Dune", year: 2021),
        ], fetchedAt: .now)
        #expect(catalog.matching("dune").map(\.id) == ["new", "old", "long"])
    }

    @Test func nothingHeardOrNothingMatchingIsEmptyAndTheLimitHolds() {
        let catalog = TitleCatalog(titles: (0 ..< 30).map { title("\($0)", "Star \($0)") }, fetchedAt: .now)
        #expect(catalog.matching("   ").isEmpty)
        #expect(catalog.matching("zzz").isEmpty)
        #expect(catalog.matching("star", limit: 5).count == 5)
    }

    @Test func aCatalogOverADayOldIsStale() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        #expect(!TitleCatalog(titles: [], fetchedAt: now.addingTimeInterval(-3_600)).isStale(now: now))
        #expect(TitleCatalog(titles: [], fetchedAt: now.addingTimeInterval(-90_000)).isStale(now: now))
    }

    @Test func everyFilmAndSeriesIsFetchedTwoHundredAPage() async throws {
        let library = PagedLibrary(films: 450, series: 3)
        let catalog = try await session(library).titleCatalog(now: Date(timeIntervalSince1970: 7))
        #expect(catalog.titles.count == 453)
        #expect(Set(catalog.titles.map(\.id)).count == 453)
        #expect(catalog.titles.first { $0.id == "s2" }?.itemType == "series")
        #expect(catalog.fetchedAt == Date(timeIntervalSince1970: 7))
        #expect(await library.asked == ["movie@0/200", "movie@200/200", "movie@400/200", "series@0/200"])
    }

    @Test func theStoreKeepsTheCatalogBetweenLaunches() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = TitleCatalogStore(directory: folder)
        #expect(store.catalog == nil)
        let catalog = TitleCatalog(titles: [title("a", "Arrival", year: 2016)], fetchedAt: Date(timeIntervalSince1970: 42))
        try store.save(catalog)
        #expect(TitleCatalogStore(directory: folder).catalog == catalog)
    }
}
