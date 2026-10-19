import Foundation
import Testing
@testable import NectarKit

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

/// Shaped as nectar's item route builds it.
private let arrival = #"""
{"item":{"id":"m1","item_type":"movie","title":"Arrival","year":2016,"overview":"A linguist works with the military.",
 "tagline":"Why are they here?","content_rating":"PG-13","community_rating":"7.6","runtime_seconds":6960,
 "poster_url":"/api/v1/images/p1",
 "images":[{"id":"p1","image_type":"primary","url":"/api/v1/images/p1"},{"id":"b1","image_type":"backdrop","url":"/api/v1/images/b1"}],
 "genres":["Drama","Science Fiction"],
 "credits":{"cast":[{"person_id":"a1","name":"Amy Adams","character":"Louise Banks","sort_order":0,"profile_image_url":"https://image.tmdb.org/t/p/w185/amy.jpg"},
                    {"person_id":"a2","name":"Jeremy Renner","character":null,"sort_order":1,"profile_image_url":"/config/people/renner.jpg"}],
            "crew":[{"person_id":"d1","name":"Denis Villeneuve","job":"Director","department":"Directing","profile_image_url":null}]},
 "trailer_url":"/api/v1/media/m1/trailer",
 "chapters":[{"idx":0,"title":"Opening","start_seconds":0},{"idx":1,"title":"The Shell","start_seconds":812.5}],
 "next_episode":null},
 "progress":{"id":"x","position_seconds":1312,"completed":false}}
"""#

@Suite("Item detail")
struct ItemDetailTests {

    @Test func theItemRouteDecodesWhatTheDetailShows() async throws {
        let detail = try await session(Server(["/api/v1/media/m1": (200, arrival)])).detail("m1")
        #expect(detail.title == "Arrival" && detail.year == 2016 && detail.itemType == "movie")
        #expect(detail.tagline == "Why are they here?")
        #expect(detail.contentRating == "PG-13")
        #expect(detail.communityRating == 7.6, "a numeric column can arrive as a string")
        #expect(detail.runtimeSeconds == 6960)
        #expect(detail.backdropPath == "/api/v1/images/b1")
        #expect(detail.genres == ["Drama", "Science Fiction"])
        #expect(detail.directors == ["Denis Villeneuve"])
        #expect(detail.trailerPath == "/api/v1/media/m1/trailer")
        #expect(detail.chapters.map(\.startSeconds) == [0, 812.5])
        #expect(detail.resumeSeconds == 1312)
    }

    @Test func castPhotosAreOnlyURLsTheTVCanLoad() async throws {
        let cast = try await session(Server(["/api/v1/media/m1": (200, arrival)])).detail("m1").cast
        #expect(cast.map(\.name) == ["Amy Adams", "Jeremy Renner"])
        #expect(cast[0].photo?.absoluteString == "https://image.tmdb.org/t/p/w185/amy.jpg")
        #expect(cast[1].photo == nil, "a path on the server's disk isn't something the TV can fetch")
        #expect(cast[1].character == nil)
    }

    @Test func aChapterThumbnailIsTheChapterRoute() async throws {
        let detail = try await session(Server(["/api/v1/media/m1": (200, arrival)])).detail("m1")
        #expect(detail.chapters[1].thumbnailPath(item: "m1") == "/api/v1/media/m1/chapters/1")
    }

    @Test func aFinishedTitleHasNoResumePoint() async throws {
        let finished = arrival.replacingOccurrences(of: #""completed":false"#, with: #""completed":true"#)
        #expect(try await session(Server(["/api/v1/media/m1": (200, finished)])).detail("m1").resumeSeconds == nil)
    }

    @Test func playingTheDetailStartsWhereAsked() async throws {
        let detail = try await session(Server(["/api/v1/media/m1": (200, arrival)])).detail("m1")
        #expect(detail.card(startingAt: 812.5).progressSeconds == 812.5)
        #expect(detail.card(startingAt: nil).progressSeconds == nil)
        #expect(detail.card(startingAt: nil).id == "m1" && detail.card(startingAt: nil).title == "Arrival")
    }

    @Test func similarTitlesAreSummaries() async throws {
        let server = Server(["/api/v1/media/m1/similar": (200, #"{"items":[{"id":"m2","item_type":"movie","title":"Contact","year":1997}],"total":1}"#)])
        #expect(try await session(server).similar(to: "m1").map(\.title) == ["Contact"])
    }

    @Test func anOwnedTitleIsAddedByItsID() async throws {
        let server = Server(["/api/v1/collections/p1/items": (200, #"{"items":[]}"#)])
        try await session(server).add(mediaItemID: "m1", toPlaylist: "p1")
        let body = try #require(JSONSerialization.jsonObject(with: await server.requests.first?.httpBody ?? Data()) as? [String: Any])
        #expect(body as? [String: String] == ["media_item_id": "m1"])
    }

    @Test func playlistsCarryTheirMediaTypeAndWantedCount() async throws {
        let server = Server(["/api/v1/collections": (200, #"""
        {"collections":[
          {"id":"p1","name":"Movie night","description":null,"kind":"playlist","media_type":"video","item_count":"2","wanted_count":1},
          {"id":"p2","name":"Road trip","description":null,"kind":"playlist","media_type":"audio","item_count":"9","wanted_count":0},
          {"id":"p3","name":"Old","description":null,"kind":"playlist","item_count":"1"}
        ]}
        """#)])
        let lists = try await session(server).playlists()
        #expect(lists.map(\.mediaType) == ["video", "audio", "video"], "rows from before nectar #444 are video")
        #expect(lists[0].titleCount == 3, "owned plus wanted")
        #expect(lists.filter { $0.holds("video") }.map(\.id) == ["p1", "p3"])
    }

    @Test func aNewPlaylistSaysWhatItHolds() async throws {
        let server = Server(["/api/v1/collections": (201, #"{"id":"p9","name":"Mix","description":null,"kind":"playlist","media_type":"audio","item_count":"0","wanted_count":0}"#)])
        let made = try await session(server).createPlaylist(named: "Mix", mediaType: "audio")
        let body = try #require(JSONSerialization.jsonObject(with: await server.requests.first?.httpBody ?? Data()) as? [String: Any])
        #expect(body["media_type"] as? String == "audio")
        #expect(made.mediaType == "audio")
    }
}
