import Foundation
import Testing
@testable import NectarKit

private actor Server: HTTPTransport {
    private let answers: [String: String]
    private(set) var requests: [URLRequest] = []

    init(_ answers: [String: String]) {
        self.answers = answers
    }

    nonisolated func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        try await answer(request)
    }

    private func answer(_ request: URLRequest) throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        guard let body = answers[request.url!.path] else { throw URLError(.fileDoesNotExist) }
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

private func query(_ request: URLRequest?) -> [String: String] {
    let items = URLComponents(url: request!.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
    return Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
}

@Suite("Home rows")
struct HomeRowTests {

    @Test func recommendationsAreOwnedOrDiscoverable() async throws {
        let server = Server(["/api/v1/recommendations": #"""
        {"recommendations":[
          {"id":"r1","media_ref":{"kind":"movie","tmdb_id":329865,"title":"Arrival","year":2016},"source":"dream","in_library":true,
           "media_item_id":"m1","score":0.9,"reason":"Because you watched Contact","poster_url":"/api/v1/images/p1","title":"Arrival","year":2016,"kind":"movie"},
          {"id":"r2","media_ref":{"kind":"series","tmdb_id":"95396","title":"Severance","year":2022},"source":"dream","in_library":false,
           "media_item_id":null,"score":0.8,"reason":null,"poster_url":null,"title":"Severance","year":2022,"kind":"series"}
        ]}
        """#])
        let recs = try await session(server).recommendations()
        #expect(recs.map(\.title) == ["Arrival", "Severance"])
        #expect(recs[0].mediaItemID == "m1" && recs[0].reason == "Because you watched Contact")
        #expect(recs[0].discoverItem == nil, "owned: it opens the library detail, not Discover")
        let severance = try #require(recs[1].discoverItem)
        #expect(severance.tmdbID == 95396 && severance.kind == .series, "tmdb_id may be a string")
        #expect(severance.title == "Severance" && severance.year == 2022)
    }

    @Test func aRowAcrossLibrariesNamesNoLibrary() async throws {
        let server = Server(["/api/v1/media": #"{"items":[],"total":0}"#, "/api/v1/media/filters": #"{"genres":["Drama"],"resolutions":[]}"#])
        var genre = LibraryQuery(library: nil)
        genre.genre = "Drama"
        genre.sort = .rating
        genre.descending = true
        genre.limit = 20
        _ = try await session(server).media(genre)
        _ = try await session(server).filters(library: nil)
        let sent = await server.requests.map(query)
        #expect(sent[0] == ["genre": "Drama", "sort": "rating", "order": "desc", "limit": "20", "offset": "0"])
        #expect(sent[1].isEmpty, "the global facets")
    }

    @Test func recentlyAddedIsNewestFirstInItsLibrary() {
        let recent = LibraryQuery.recentlyAdded(in: "l1")
        #expect(recent.library == "l1" && recent.sort == .dateAdded && recent.descending && recent.limit == 20)
        let music = try! JSONDecoder().decode(Library.self, from: Data(#"{"id":"l3","name":"Music","library_type":"music","item_count":1}"#.utf8))
        #expect(LibraryQuery.recentlyAdded(in: music).itemType == "album", "a music row is its newest albums, not tracks")
    }
}
