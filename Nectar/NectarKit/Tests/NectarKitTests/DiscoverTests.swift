import Foundation
import Testing
@testable import NectarKit

/// Answers every request with one body and keeps the requests.
private actor OneAnswer: HTTPTransport {
    private let status: Int
    private let body: String
    private(set) var requests: [URLRequest] = []

    init(status: Int = 200, _ body: String) {
        self.status = status
        self.body = body
    }

    nonisolated func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        try await answer(request)
    }

    private func answer(_ request: URLRequest) -> (Data, HTTPURLResponse) {
        requests.append(request)
        return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }
}

private func session(_ transport: OneAnswer) -> NectarSession {
    NectarSession(
        baseURL: URL(string: "https://nectar.test")!,
        tokenEndpoint: URL(string: "https://nectar.test/token")!,
        clientID: "nectar-tv",
        store: InMemoryTokenStore(TokenSet(accessToken: "jwt-1", tokenType: "Bearer", expiresIn: nil, refreshToken: "r1")),
        transport: transport
    )
}

/// Shaped as nectar's `finalize` in routes/discover.ts builds it.
private let discoverBody = #"""
{"results":[
 {"tmdb_id":950396,"kind":"movie","title":"A Minecraft Movie","year":2025,"overview":"Four misfits…",
  "poster_url":"https://image.tmdb.org/t/p/w342/p.jpg","backdrop_url":"https://image.tmdb.org/t/p/w780/b.jpg",
  "vote_average":6.5,"in_library":true,"already_requested":false},
 {"tmdb_id":1399,"kind":"series","title":"Game of Thrones","year":null,"overview":null,
  "poster_url":null,"backdrop_url":null,"vote_average":null,"in_library":false,"already_requested":true}
]}
"""#

private func query(_ request: URLRequest?) -> [String: String] {
    let items = request?.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false)?.queryItems } ?? []
    return Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
}

@Suite("Discover")
struct DiscoverTests {

    @Test func trendingDecodesAsNectarShapesIt() async throws {
        let transport = OneAnswer(discoverBody)
        let items = try await session(transport).discoverTrending(.movie)

        let request = await transport.requests.first
        #expect(request?.url?.path == "/api/v1/discover/trending")
        #expect(query(request) == ["kind": "movie"])
        #expect(items.count == 2)
        #expect(items[0] == DiscoverItem(
            tmdbID: 950396, kind: .movie, title: "A Minecraft Movie", year: 2025, overview: "Four misfits…",
            posterURL: URL(string: "https://image.tmdb.org/t/p/w342/p.jpg"), backdropURL: URL(string: "https://image.tmdb.org/t/p/w780/b.jpg"),
            rating: 6.5, inLibrary: true, alreadyRequested: false
        ))
        #expect(items[1].kind == .series)
        #expect(items[1].posterURL == nil)
        #expect(items[1].alreadyRequested)
        #expect(items[0].id != items[1].id)
    }

    @Test func searchSendsTheQueryAndKind() async throws {
        let transport = OneAnswer(#"{"results":[]}"#)
        let items = try await session(transport).discoverSearch("mine craft", kind: .all)
        #expect(items.isEmpty)
        let request = await transport.requests.first
        #expect(request?.url?.path == "/api/v1/discover/search")
        #expect(query(request) == ["q": "mine craft", "kind": "all"])
    }

    @Test func aMovieAndASeriesWithTheSameTmdbIDAreDifferentItems() {
        let movie = DiscoverItem(tmdbID: 1, kind: .movie, title: "x")
        let series = DiscoverItem(tmdbID: 1, kind: .series, title: "x")
        #expect(movie.id != series.id, "TMDB numbers movies and series separately")
    }

    @Test func aServerWithoutTMDBSurfacesItsMessage() async throws {
        let transport = OneAnswer(status: 400, #"{"error":"TMDB is not configured — add a TMDB API key"}"#)
        await #expect(throws: NectarSessionError.unexpectedStatus(400)) {
            try await session(transport).discoverTrending(.all)
        }
    }
}
