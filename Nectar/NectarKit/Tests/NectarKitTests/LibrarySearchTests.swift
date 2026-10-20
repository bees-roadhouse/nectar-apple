import Foundation
import Testing
@testable import NectarKit

/// Answers by path and keeps every request.
private actor PathTransport: HTTPTransport {

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
        guard let (status, body) = answers[request.url!.path] else { throw URLError(.fileDoesNotExist) }
        return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }
}

private func session(_ transport: PathTransport) -> NectarSession {
    NectarSession(
        baseURL: URL(string: "https://nectar.test")!,
        tokenEndpoint: URL(string: "https://nectar.test/token")!,
        clientID: "nectar-tv",
        store: InMemoryTokenStore(TokenSet(accessToken: "jwt-1", tokenType: "Bearer", expiresIn: nil, refreshToken: "r1")),
        transport: transport
    )
}

private func query(_ request: URLRequest?) -> [String: String] {
    let items = request.flatMap { URLComponents(url: $0.url!, resolvingAgainstBaseURL: false)?.queryItems } ?? []
    return Dictionary(items.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { a, _ in a })
}

private func hit(_ id: String, _ type: String) -> TitleHit {
    TitleHit(id: id, itemType: type, title: id)
}

/// `/search/dialogue` rows as nectar's routes/search.ts sends them: one from this library, one from another.
private let dialogue = #"""
{"results":[
 {"media_item_id":"m1","library_id":"tv","item_type":"episode","title":"The Kingsroad","t_seconds":812,"snippet":"Winter is coming."},
 {"media_item_id":"m2","library_id":"films","item_type":"movie","title":"Arrival","t_seconds":95,"snippet":"Winter is coming."}
]}
"""#

@Suite("Library search")
struct LibrarySearchTests {

    @Test func titlesAreScopedToTheLibraryOnTheServer() async throws {
        let transport = PathTransport(["/api/v1/search": (200, #"{"results":[]}"#)])
        let tv = session(transport)
        _ = try await tv.searchTitles("kings", library: "tv")
        _ = try await tv.searchTitles("kings")

        let requests = await transport.requests
        #expect(query(requests[0])["library_id"] == "tv")
        #expect(query(requests[0])["q"] == "kings")
        #expect(query(requests[1])["library_id"] == nil, "the global search stays unscoped")
    }

    @Test func dialogueAsksForTheLibraryAndKeepsOnlyItsLines() async throws {
        let transport = PathTransport(["/api/v1/search/dialogue": (200, dialogue)])
        let hits = try await session(transport).searchMoments("winter", in: .dialogue, library: "tv")

        #expect(query(await transport.requests.first)["library_id"] == "tv")
        #expect(hits.map(\.itemID) == ["m1"], "until nectar#610, a line from another library is dropped here")
    }

    @Test func dialogueWithoutALibraryKeepsEveryLine() async throws {
        let transport = PathTransport(["/api/v1/search/dialogue": (200, dialogue)])
        let hits = try await session(transport).searchMoments("winter", in: .dialogue)

        #expect(hits.map(\.itemID) == ["m1", "m2"])
    }

    @Test func aShowsLibraryListsShowsThenEpisodes() {
        let sections = LibrarySearch.sections(.shows, [hit("e1", "episode"), hit("s1", "series"), hit("x", "season"), hit("e2", "episode")])

        #expect(sections.map(\.title) == ["Shows", "Episodes"])
        #expect(sections.map { $0.hits.map(\.id) } == [["s1"], ["e1", "e2"]], "nectar's order is kept within a section")
    }

    @Test func aMusicLibraryListsAlbumsThenSongs() {
        let sections = LibrarySearch.sections(.music, [hit("t1", "track"), hit("a1", "album")])

        #expect(sections.map(\.title) == ["Albums", "Songs"])
        #expect(sections.map(\.style) == [.posters, .list])
    }

    @Test func aFilmLibraryIsOneUntitledGridAndEmptySectionsAreLeftOut() {
        #expect(LibrarySearch.sections(.movies, [hit("m1", "movie"), hit("m2", "movie")]).map(\.title) == [nil])
        #expect(LibrarySearch.sections(.shows, [hit("s1", "series")]).map(\.title) == ["Shows"])
        #expect(LibrarySearch.sections(.movies, []).isEmpty)
    }

    @Test func episodesAreStillsAndShowsArePosters() {
        let sections = LibrarySearch.sections(.shows, [hit("s1", "series"), hit("e1", "episode")])

        #expect(sections.map(\.style) == [.posters, .stills])
    }

    @Test func recentSearchesAreKeptPerLibraryNewestFirstWithoutRepeats() throws {
        let defaults = try #require(UserDefaults(suiteName: "LibrarySearchTests.\(UUID().uuidString)"))
        let films = RecentSearches(library: "films", defaults: defaults)
        let tv = RecentSearches(library: "tv", defaults: defaults)

        for q in ["arrival", " Dune ", "", "ARRIVAL", "heat", "alien", "brazil", "casino"] {
            films.record(q)
        }
        tv.record("kingsroad")

        #expect(films.list == ["casino", "brazil", "alien", "heat", "ARRIVAL"], "five at most; a repeat moves up in the casing typed last; blanks are ignored")
        #expect(tv.list == ["kingsroad"])
        #expect(RecentSearches(library: "films", defaults: defaults).list.first == "casino", "kept on the device")
    }
}
