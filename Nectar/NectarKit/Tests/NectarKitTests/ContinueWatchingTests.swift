import Foundation
import Testing
@testable import NectarKit

/// Answers every request with one body and keeps the requests.
private actor RecordingTransport: HTTPTransport {

    private let status: Int
    private let body: String
    private(set) var requests: [URLRequest] = []

    init(status: Int = 200, body: String) {
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

/// Shaped as nectar's `/api/v1/media/continue` sends it (routes/media.ts at 7298dbc): the summarised
/// media row with its extra columns, artwork as root-relative paths, and `progress_seconds`.
private let continueBody = #"""
{"items":[
 {"id":"6f1c","library_id":"lib1","parent_id":null,"item_type":"movie","title":"Arrival","year":2016,
  "runtime_seconds":6960,"container":"mkv","video_codec":"hevc","metadata_json":{"tmdb":329865},
  "season_number":null,"episode_number":null,
  "poster_url":"/api/v1/images/aa11","backdrop_url":"/api/v1/images/bb22","logo_url":null,
  "genres":["Drama","Science Fiction"],"progress_seconds":1740.5},
 {"id":"9e2d","library_id":"lib2","parent_id":"s1","item_type":"episode","title":"The Pilot","series_title":"Severance",
  "runtime_seconds":null,"season_number":1,"episode_number":1,
  "poster_url":null,"backdrop_url":null,"genres":[],"progress_seconds":300}
],"total":2}
"""#

private func session(_ transport: RecordingTransport) -> NectarSession {
    NectarSession(
        baseURL: URL(string: "https://nectar.test")!,
        tokenEndpoint: URL(string: "https://nectar.test/token")!,
        clientID: "nectar-tv",
        store: InMemoryTokenStore(TokenSet(accessToken: "jwt-1", tokenType: "Bearer", expiresIn: nil, refreshToken: "r1")),
        transport: transport
    )
}

@Suite("Continue watching")
struct ContinueWatchingTests {

    @Test func decodesTheRowAsNectarShapesIt() async throws {
        let cards = try await session(RecordingTransport(body: continueBody)).continueWatching()
        #expect(cards.count == 2)
        #expect(cards[0] == MediaCard(
            id: "6f1c", itemType: "movie", title: "Arrival", year: 2016, runtimeSeconds: 6960,
            posterPath: "/api/v1/images/aa11", backdropPath: "/api/v1/images/bb22", progressSeconds: 1740.5
        ))
        #expect(cards[0].seriesTitle == nil)
        #expect(cards[1].seriesTitle == "Severance")
        #expect(cards[1].seasonNumber == 1)
        #expect(cards[1].artworkPath == nil)
    }

    @Test func asksForTheLimitWithTheBearerToken() async throws {
        let transport = RecordingTransport(body: #"{"items":[],"total":0}"#)
        let cards = try await session(transport).continueWatching(limit: 12)
        #expect(cards.isEmpty)

        let request = try #require(await transport.requests.first)
        let url = try #require(request.url)
        #expect(url.path == "/api/v1/media/continue")
        #expect(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems == [URLQueryItem(name: "limit", value: "12")])
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer jwt-1")
    }

    @Test func aServerErrorSurfacesWithItsStatus() async throws {
        let transport = RecordingTransport(status: 500, body: "boom")
        await #expect(throws: NectarSessionError.unexpectedStatus(500)) {
            try await session(transport).continueWatching()
        }
    }

    @Test func artworkResolvesAgainstTheServer() async throws {
        let nectar = session(RecordingTransport(body: "{}"))
        #expect(nectar.resolve("/api/v1/images/aa11")?.absoluteString == "https://nectar.test/api/v1/images/aa11")
        #expect(nectar.resolve(nil) == nil)
        #expect(nectar.resolve("") == nil)
    }

    /// nectar #413: `/api/v1/images/{id}/w{N}` serves the smallest copy at or above N pixels.
    @Test func artworkAsksForTheWidthItDraws() async throws {
        let nectar = session(RecordingTransport(body: "{}"))
        #expect(nectar.resolve("/api/v1/images/aa11", pixelWidth: 960)?.absoluteString == "https://nectar.test/api/v1/images/aa11/w960")
        #expect(nectar.resolve("/api/v1/images/aa11", pixelWidth: 479.4)?.absoluteString == "https://nectar.test/api/v1/images/aa11/w480", "rounded up, never a blurrier copy")
        #expect(nectar.resolve("/api/v1/images/aa11/w342", pixelWidth: 960)?.absoluteString == "https://nectar.test/api/v1/images/aa11/w342", "a sized path isn't sized twice")
        #expect(nectar.resolve(nil, pixelWidth: 960) == nil)
        #expect(nectar.resolve("/api/v1/images/aa11", pixelWidth: 0)?.absoluteString == "https://nectar.test/api/v1/images/aa11", "no width, the original")
    }

    @Test(arguments: [
        (1740.0, 6960.0, 0.25),
        (-5.0, 6960.0, 0.0),
        (9000.0, 6960.0, 1.0),
    ])
    func progressIsAClampedFraction(position: Double, runtime: Double, expected: Double) {
        let card = MediaCard(id: "x", runtimeSeconds: runtime, progressSeconds: position)
        #expect(card.progress == expected)
    }

    @Test func progressIsUnknownWithoutARuntime() {
        #expect(MediaCard(id: "x", runtimeSeconds: nil, progressSeconds: 300).progress == nil)
        #expect(MediaCard(id: "x", runtimeSeconds: 0, progressSeconds: 300).progress == nil)
        #expect(MediaCard(id: "x", runtimeSeconds: 6960, progressSeconds: nil).progress == nil)
    }

    @Test func wideArtworkFallsBackToThePoster() {
        #expect(MediaCard(id: "x", posterPath: "/p", backdropPath: "/b").artworkPath == "/b")
        #expect(MediaCard(id: "x", posterPath: "/p").artworkPath == "/p")
    }
}
