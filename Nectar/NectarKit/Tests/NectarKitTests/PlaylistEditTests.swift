import Foundation
import Testing
@testable import NectarKit

/// Answers by path with a status and body, and keeps every request.
private actor Server: HTTPTransport {
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

private func session(_ transport: Server) -> NectarSession {
    NectarSession(
        baseURL: URL(string: "https://nectar.test")!,
        tokenEndpoint: URL(string: "https://nectar.test/token")!,
        clientID: "nectar-tv",
        store: InMemoryTokenStore(TokenSet(accessToken: "jwt-1", tokenType: "Bearer", expiresIn: nil, refreshToken: "r1")),
        transport: transport
    )
}

private func json(_ request: URLRequest?) throws -> [String: Any] {
    try #require(JSONSerialization.jsonObject(with: request?.httpBody ?? Data()) as? [String: Any])
}

private let piper = DiscoverItem(
    tmdbID: 399106, kind: .movie, title: "Piper", year: 2016,
    posterURL: URL(string: "https://image.tmdb.org/t/p/w342/piper.jpg")
)

@Suite("Playlists: adding and creating")
struct PlaylistEditTests {

    @Test func aDiscoverTitleIsAddedByItsTMDBRef() async throws {
        let server = Server(["/api/v1/collections/p1/items": (200, #"{"items":[]}"#)])
        try await session(server).add(piper, toPlaylist: "p1")

        let request = await server.requests.first
        #expect(request?.httpMethod == "POST")
        let body = try json(request)
        #expect(body["tmdb_id"] as? Int == 399106)
        #expect(body["kind"] as? String == "movie")
        #expect(body["title"] as? String == "Piper")
        #expect(body["year"] as? Int == 2016)
        #expect(body["poster_url"] as? String == "https://image.tmdb.org/t/p/w342/piper.jpg", "kept so a wanted entry has a poster")
        #expect(body["media_item_id"] == nil, "nectar works out ownership from the TMDB ref")
    }

    @Test func aWrongMediaTypeIsReportedNotSwallowed() async throws {
        let server = Server(["/api/v1/collections/p1/items": (400, #"{"error":"this playlist holds audio"}"#)])
        await #expect(throws: NectarSessionError.self) {
            try await session(server).add(piper, toPlaylist: "p1")
        }
    }

    @Test func aNewPlaylistIsAPlaylistNotACollection() async throws {
        let server = Server(["/api/v1/collections": (201, #"""
        {"id":"p9","user_id":"u1","name":"Friday","description":null,"kind":"playlist","item_count":"0"}
        """#)])
        let created = try await session(server).createPlaylist(named: "  Friday ")

        let body = try json(await server.requests.first)
        #expect(body["name"] as? String == "Friday", "trimmed, as nectar would")
        #expect(body["kind"] as? String == "playlist")
        #expect(created == Playlist(id: "p9", name: "Friday", description: nil, itemCount: 0))
    }
}
