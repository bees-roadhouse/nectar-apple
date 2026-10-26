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

    @Test func aPeoplePagePreservesCreditsAndEncodesTheSearchOnce() async throws {
        let server = Server(["/api/v1/people": #"""
        {"people":[{"id":"p2","name":"Élodie A/B & Co","profile_image_url":"/config/people/p2.jpg","credit_count":"9"},
                   {"id":"p1","name":"Amy Adams","profile_image_url":"https://image.tmdb.org/p1.jpg","credit_count":2}],"total":"81"}
        """#])
        let page = try await session(server).people(search: "  Élodie A/B & Co  ", offset: 60)
        #expect(page.people.map(\.id) == ["p2", "p1"])
        #expect(page.total == 81 && page.people[0].creditCount == 9)
        #expect(page.people[0].photo == nil)
        #expect(page.people[1].photo?.absoluteString == "https://image.tmdb.org/p1.jpg")
        let request = try #require(await server.requests.first)
        let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
        #expect(query.first(where: { $0.name == "search" })?.value == "Élodie A/B & Co")
        #expect(query.first(where: { $0.name == "offset" })?.value == "60")
        #expect(query.first(where: { $0.name == "limit" })?.value == "60")
    }

    @Test func aGenreWithSlashAmpersandAndAccentIsEncodedOnce() async throws {
        let server = Server(["/api/v1/media": #"{"items":[],"total":0}"#])
        var request = LibraryQuery(library: nil)
        request.genre = "R&B / Cinéma"
        request.offset = 60
        _ = try await session(server).media(request)
        let sent = try #require(await server.requests.first)
        let query = URLComponents(url: sent.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
        #expect(query.first(where: { $0.name == "genre" })?.value == "R&B / Cinéma")
        #expect(query.first(where: { $0.name == "offset" })?.value == "60")
    }

    /// nectar#376 slice 2: a filmography poster's hash reaches the card a credit opens as.
    @Test func aCreditsCardCarriesItsPostersPreview() async throws {
        let server = Server(["/api/v1/people/a1": #"""
        {"person":{"id":"a1","name":"Amy Adams"},
         "filmography":[{"id":"m1","item_type":"movie","title":"Arrival","poster_url":"/api/v1/images/p1","poster_blurhash":"00FF00"},
                        {"id":"m2","item_type":"movie","title":"Enchanted","poster_url":null,"poster_blurhash":null}]}
        """#])
        let credits = try await session(server).person("a1").credits
        #expect(credits.map(\.card.posterBlurHash) == ["00FF00", nil])
    }

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

    /// Palp's note on #181: URLComponents leaves "+" bare in a query, and nectar reads a bare "+" as a space.
    @Test func aPlusInASearchOrGenreReachesTheServerAsAPlus() async throws {
        let server = Server(["/api/v1/people": #"{"people":[],"total":0}"#, "/api/v1/media": #"{"items":[],"total":0}"#])
        _ = try await session(server).people(search: "C++ & A+B")
        var request = LibraryQuery(library: nil)
        request.genre = "Rock+Roll"
        _ = try await session(server).media(request)
        let sent = await server.requests
        let people = try #require(sent.first?.url?.query)
        let media = try #require(sent.last?.url?.query)
        #expect(people.contains("search=C%2B%2B%20%26%20A%2BB"), "people query: \(people)")
        #expect(media.contains("genre=Rock%2BRoll"), "media query: \(media)")
        #expect(!people.contains("+") && !media.contains("+"))
    }
}
