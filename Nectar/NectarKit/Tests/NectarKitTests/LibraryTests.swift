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

@Suite("Library browse")
struct LibraryTests {

    @Test func librariesKeepTheirTypeAndCount() async throws {
        let server = Server(["/api/v1/libraries": #"""
        {"libraries":[
          {"id":"l1","name":"Movies","library_type":"movies","paths":["/m"],"item_count":"812","last_scan":null},
          {"id":"l2","name":"TV Shows","library_type":"shows","paths":["/t"],"item_count":96},
          {"id":"l3","name":"Music","library_type":"music","paths":["/a"],"item_count":0},
          {"id":"l4","name":"Comics","library_type":"zines","paths":["/z"],"item_count":3}
        ]}
        """#])
        let libraries = try await session(server).libraries()
        #expect(libraries.map(\.name) == ["Movies", "TV Shows", "Music", "Comics"], "every library, none filtered out")
        #expect(libraries[0].kind == .movies && libraries[0].itemCount == 812, "COUNT() arrives as a string")
        #expect(libraries[1].kind == .shows)
        #expect(libraries[2].kind == .music)
        #expect(libraries[3].kind == .other("zines"), "a type newer than the app still gets a tab")
    }

    @Test func eachLibraryListsItsTopLevelItems() async throws {
        let server = Server(["/api/v1/media": #"{"items":[],"total":0}"#])
        let music = try JSONDecoder().decode(Library.self, from: Data(#"{"id":"l3","name":"Music","library_type":"music","item_count":0}"#.utf8))
        let shows = try JSONDecoder().decode(Library.self, from: Data(#"{"id":"l2","name":"TV","library_type":"shows","item_count":0}"#.utf8))
        _ = try await session(server).media(LibraryQuery(music))
        _ = try await session(server).media(LibraryQuery(shows))
        let sent = await server.requests.map(query)
        #expect(sent[0]["type"] == "album", "albums, not every track")
        #expect(sent[1]["type"] == nil, "nectar lists a shows library's series by itself")
    }

    @Test func aPageAsksForWhatTheGridShows() async throws {
        let server = Server(["/api/v1/media": #"{"items":[{"id":"m1","item_type":"movie","title":"Arrival","year":2016,"poster_url":"/api/v1/images/p1"}],"total":"812"}"#])
        var request = LibraryQuery(library: "l1")
        request.sort = .dateAdded
        request.descending = true
        request.genre = "Science Fiction"
        request.resolution = "2160p"
        request.offset = 60
        let page = try await session(server).media(request)

        let sent = query(await server.requests.first)
        #expect(sent == ["library": "l1", "sort": "date_added", "order": "desc", "genre": "Science Fiction",
                         "resolution": "2160p", "limit": "60", "offset": "60"])
        #expect(page.items.map(\.title) == ["Arrival"])
        #expect(page.total == 812)
    }

    @Test func noFilterMeansNoParameter() async throws {
        let server = Server(["/api/v1/media": #"{"items":[],"total":0}"#])
        _ = try await session(server).media(LibraryQuery(library: "l2"))
        #expect(query(await server.requests.first) == ["library": "l2", "sort": "title", "order": "asc", "limit": "60", "offset": "0"])
    }

    @Test func filtersOfferWhatTheLibraryHas() async throws {
        let server = Server(["/api/v1/media/filters": #"""
        {"resolutions":["2160p","1080p"],"video_codecs":["hevc"],"hdr_formats":[],"audio_codecs":["eac3"],
         "audio_channels":["6"],"languages":["en"],"genres":["Drama","Science Fiction"]}
        """#])
        let filters = try await session(server).filters(library: "l1")
        #expect(query(await server.requests.first) == ["library": "l1"])
        #expect(filters.genres == ["Drama", "Science Fiction"])
        #expect(filters.resolutions == ["2160p", "1080p"])
    }
}
