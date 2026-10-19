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

private func query(_ request: URLRequest?) -> [String: String] {
    let items = URLComponents(url: request!.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
    return Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
}

@Suite("Library search")
struct SearchTests {

    @Test func titlesComeBackAsNectarRanksThem() async throws {
        let server = Server(["/api/v1/search": (200, #"""
        {"results":[{"id":"m1","library_id":"l1","title":"Arrival","item_type":"movie","overview":"Linguists.","year":2016,"file_path":"/x","container":"mkv"},
                    {"id":"s1","library_id":"l2","title":"Dark","item_type":"series","overview":null,"year":"2017","poster_url":"/api/v1/images/p9"}],"total":2}
        """#)])
        let hits = try await session(server).searchTitles("aliens language")
        #expect(query(await server.requests.first) == ["q": "aliens language", "limit": "40"])
        #expect(hits.map(\.title) == ["Arrival", "Dark"])
        #expect(hits[0].itemType == "movie" && hits[0].year == 2016 && hits[0].posterPath == nil)
        #expect(hits[1].year == 2017 && hits[1].posterPath == "/api/v1/images/p9", "a poster is used once nectar sends one")
    }

    @Test func aDialogueHitIsAMomentWithItsLine() async throws {
        let server = Server(["/api/v1/search/dialogue": (200, #"""
        {"results":[{"media_item_id":"m1","library_id":"l1","title":"Arrival","item_type":"movie","poster_url":"/api/v1/images/p1",
          "thumb_url":"/api/v1/media/m1/trickplay/frame?t=4920","t_seconds":4920.5,"end_seconds":4924,"snippet":"Kangaroo."}]}
        """#)])
        let hits = try await session(server).searchMoments("kangaroo", in: .dialogue)
        #expect(query(await server.requests.first) == ["q": "kangaroo", "limit": "30"])
        #expect(hits.count == 1)
        #expect(hits[0].itemID == "m1" && hits[0].seconds == 4920.5 && hits[0].snippet == "Kangaroo.")
        #expect(hits[0].thumbPath == "/api/v1/media/m1/trickplay/frame?t=4920")
        #expect(hits[0].card.progressSeconds == 4920.5, "playing a moment starts at it")
        #expect(hits[0].card.id == "m1" && hits[0].card.title == "Arrival")
    }

    @Test func sceneAndAudioHitsComeFromTheirOwnRoutes() async throws {
        let server = Server([
            "/api/v1/search/scenes": (200, #"{"results":[{"media_item_id":"m2","library_id":"l1","title":"Dune","item_type":"movie","t_seconds":61,"similarity":0.31,"poster_url":null,"thumb_url":null}]}"#),
            "/api/v1/search/audio": (200, #"{"results":[{"media_item_id":"t1","library_id":"l3","title":"Hurt","item_type":"track","poster_url":"/api/v1/images/a1","similarity":0.4}]}"#),
        ])
        let scenes = try await session(server).searchMoments("desert at night", in: .scenes)
        let audio = try await session(server).searchMoments("sad piano", in: .audio)
        #expect(scenes[0].seconds == 61 && scenes[0].thumbPath == nil)
        #expect(audio[0].itemType == "track" && audio[0].seconds == nil)
        #expect(audio[0].card.progressSeconds == nil)
    }

    @Test func aModeTheServerSwitchedOffSaysSo() async throws {
        let server = Server(["/api/v1/search/scenes": (400, #"{"error":"scene search is disabled"}"#)])
        await #expect(throws: SearchError.disabled) {
            _ = try await session(server).searchMoments("anything", in: .scenes)
        }
    }

    @Test func theModesAreTheFourNectarHas() {
        #expect(SearchMode.allCases.map(\.title) == ["Titles", "Dialogue", "Scenes", "Audio"])
    }
}
