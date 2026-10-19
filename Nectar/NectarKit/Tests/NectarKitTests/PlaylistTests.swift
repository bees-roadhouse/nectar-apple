import Foundation
import Testing
@testable import NectarKit

private actor ByPath: HTTPTransport {
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

private func session(_ transport: ByPath) -> NectarSession {
    NectarSession(
        baseURL: URL(string: "https://nectar.test")!,
        tokenEndpoint: URL(string: "https://nectar.test/token")!,
        clientID: "nectar-tv",
        store: InMemoryTokenStore(TokenSet(accessToken: "jwt-1", tokenType: "Bearer", expiresIn: nil, refreshToken: "r1")),
        transport: transport
    )
}

/// Shaped as nectar's collections routes build them after #433.
private let list = #"""
{"collections":[{"id":"p1","user_id":"u1","name":"Movie night","description":null,"kind":"playlist","item_count":"2",
 "created_at":"2026-10-19T12:00:00Z","updated_at":"2026-10-19T12:00:00Z"}]}
"""#
private let detail = #"""
{"collection":{"id":"p1","name":"Movie night","description":"Fridays","kind":"playlist","item_count":2},
 "items":[
  {"id":"m1","item_type":"movie","title":"Arrival","year":2016,"sort_index":0,"poster_url":"/api/v1/images/i1","entry":"owned","media_item_id":"m1"},
  {"id":"w1","entry":"wanted","item_type":"movie","title":"Piper","year":2016,"sort_index":1,"poster_url":"https://image.tmdb.org/t/p/w342/x.jpg",
   "media_item_id":null,"tmdb_id":"399106","request_status":"approved"},
  {"id":"s1","item_type":"series","title":"Severance","year":2022,"sort_index":2,"poster_url":null,"entry":"owned","media_item_id":"s1"},
  {"id":"e1","item_type":"episode","title":"Good News About Hell","year":2022,"sort_index":3,"poster_url":null,"entry":"owned","media_item_id":"e1"}
 ]}
"""#

@Suite("Playlists")
struct PlaylistTests {

    @Test func listsThePlaylistsOnly() async throws {
        let transport = ByPath(["/api/v1/collections": list])
        let playlists = try await session(transport).playlists()
        let request = await transport.requests.first
        #expect(request?.url?.query == "kind=playlist")
        #expect(playlists == [Playlist(id: "p1", name: "Movie night", description: nil, itemCount: 2)], "item_count arrives as a string from COUNT()")
    }

    @Test func membersKeepTheirOrderAndEntryKind() async throws {
        let transport = ByPath(["/api/v1/collections/p1": detail])
        let members = try await session(transport).playlist("p1").members
        #expect(members.map(\.id) == ["m1", "w1", "s1", "e1"])
        #expect(members[0].entry == .owned && members[0].mediaItemID == "m1")
        #expect(members[1].entry == .wanted && members[1].mediaItemID == nil && members[1].tmdbID == 399106)
        #expect(members[1].requestStatus == "approved")
    }

    @Test func playOrderIsOwnedMoviesAndEpisodesOnly() async throws {
        let transport = ByPath(["/api/v1/collections/p1": detail])
        let queue = try await session(transport).playlist("p1").playQueue
        #expect(queue.map(\.id) == ["m1", "e1"], "a wanted entry isn't here yet, and a series isn't one thing to play")
        #expect(queue.first?.title == "Arrival")
        #expect(queue.first?.posterPath == "/api/v1/images/i1")
    }
}
