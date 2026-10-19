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

@Suite("People and collections")
struct PeopleTests {

    @Test func aPersonAndWhatTheyreIn() async throws {
        let server = Server(["/api/v1/people/a1": #"""
        {"person":{"id":"a1","name":"Amy Adams","sort_name":"Adams, Amy","profile_image_url":"https://image.tmdb.org/t/p/w185/amy.jpg","credit_count":"3"},
         "filmography":[
           {"id":"m1","item_type":"movie","title":"Arrival","year":2016,"roles":["actor"],"character":"Louise Banks","poster_url":"/api/v1/images/p1"},
           {"id":"m2","item_type":"movie","title":"Enchanted","year":2007,"roles":["actor","producer"],"character":null,"poster_url":null}
         ]}
        """#])
        let detail = try await session(server).person("a1")
        #expect(detail.person.name == "Amy Adams" && detail.person.creditCount == 3)
        #expect(detail.person.photo?.absoluteString == "https://image.tmdb.org/t/p/w185/amy.jpg")
        #expect(detail.credits.map(\.title) == ["Arrival", "Enchanted"])
        #expect(detail.credits[0].role == "as Louise Banks")
        #expect(detail.credits[1].role == "actor, producer", "no character: the roles")
        #expect(detail.credits[0].card.id == "m1" && detail.credits[0].card.posterPath == "/api/v1/images/p1")
    }

    @Test func aPhotoOnTheServersDiskIsNoPhoto() async throws {
        let server = Server(["/api/v1/people/a2": #"{"person":{"id":"a2","name":"Jeremy Renner","profile_image_url":"/config/people/r.jpg","credit_count":1},"filmography":[]}"#])
        #expect(try await session(server).person("a2").person.photo == nil)
    }

    @Test func collectionsAreAskedForByKind() async throws {
        let server = Server(["/api/v1/collections": #"{"collections":[{"id":"c1","name":"Marvel","description":"The MCU","kind":"collection","item_count":"23"}]}"#])
        let collections = try await session(server).collections(kind: "collection")
        #expect(await server.requests.first?.url?.query == "kind=collection")
        #expect(collections.map(\.name) == ["Marvel"] && collections[0].itemCount == 23)
    }
}
