import Foundation
import Testing
@testable import NectarKit

/// Answers by path and keeps every request.
private actor Routes: HTTPTransport {
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

private func session(_ transport: Routes) -> NectarSession {
    NectarSession(
        baseURL: URL(string: "https://nectar.test")!,
        tokenEndpoint: URL(string: "https://nectar.test/token")!,
        clientID: "nectar-tv",
        store: InMemoryTokenStore(TokenSet(accessToken: "jwt-1", tokenType: "Bearer", expiresIn: nil, refreshToken: "r1")),
        transport: transport
    )
}

private let minecraft = DiscoverItem(tmdbID: 950396, kind: .movie, title: "A Minecraft Movie", year: 2025)

@Suite("Requests (want it)")
struct RequestTests {

    @Test func wantItPostsTheTitleAsNectarReadsIt() async throws {
        let transport = Routes(["/api/v1/requests": (201, #"{"id":"r1","status":"pending"}"#)])
        _ = try await session(transport).want(minecraft)

        let request = try #require(await transport.requests.first)
        #expect(request.httpMethod == "POST")
        let body = try #require(JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any])
        let ref = try #require(body["media_ref"] as? [String: Any])
        #expect(ref["kind"] as? String == "movie")
        #expect(ref["tmdb_id"] as? Int == 950396)
        #expect(ref["title"] as? String == "A Minecraft Movie")
        #expect(ref["year"] as? Int == 2025)
    }

    @Test func aHouseholdMemberIsApprovedAtOnce() async throws {
        let transport = Routes(["/api/v1/requests": (201, #"{"id":"r1","status":"approved","monitored_item_id":"m1","wanted_id":"w1","auto_approved":true}"#)])
        #expect(try await session(transport).want(minecraft) == .wanted)
    }

    @Test func aGuestWaitsForApproval() async throws {
        let transport = Routes(["/api/v1/requests": (201, #"{"id":"r1","status":"pending"}"#)])
        #expect(try await session(transport).want(minecraft) == .awaitingApproval)
    }

    @Test func anOpenRequestFromAnyoneIsAlreadyRequested() async throws {
        let transport = Routes(["/api/v1/requests": (409, #"{"error":"an open request for this title already exists"}"#)])
        #expect(try await session(transport).want(minecraft) == .alreadyRequested)
    }

    @Test func myRequestsMapToTheirTitles() async throws {
        let transport = Routes(["/api/v1/requests": (200, #"""
        {"requests":[
          {"id":"a","media_ref":{"kind":"movie","tmdb_id":950396,"title":"A Minecraft Movie"},"status":"approved","auto_approved":true},
          {"id":"b","media_ref":{"kind":"series","tmdb_id":"1399","title":"Game of Thrones"},"status":"pending","auto_approved":false},
          {"id":"c","media_ref":{"kind":"movie","imdb_id":"tt1","title":"No tmdb"},"status":"denied","auto_approved":false},
          {"id":"d","media_ref":{"kind":"movie","tmdb_id":5,"title":"Old"},"status":"fulfilled","auto_approved":false}
        ]}
        """#)])
        let mine = try await session(transport).myRequestStates()
        #expect(mine[DiscoverItem(tmdbID: 950396, kind: .movie, title: "").id] == .wanted)
        #expect(mine[DiscoverItem(tmdbID: 1399, kind: .series, title: "").id] == .awaitingApproval, "tmdb_id may arrive as a string")
        #expect(mine.count == 2, "denied, fulfilled and tmdb-less requests aren't open")
    }
}

/// An admin's `GET /requests` is everyone's; these are nate's and Maggie's.
private let everyone = #"""
{"requests":[
  {"id":"a","media_ref":{"kind":"movie","tmdb_id":399106,"title":"Piper","year":2016},"requested_by":"u-nate","requested_by_name":"nate",
   "status":"approved","monitored_item_id":"mi1","created_at":"2026-10-19T14:43:05.123Z","decided_at":"2026-10-19T14:43:05.200Z","auto_approved":true},
  {"id":"b","media_ref":{"kind":"series","tmdb_id":"1399","title":"Game of Thrones","year":2011},"requested_by":"u-maggie","requested_by_name":"maggie",
   "status":"pending","monitored_item_id":null,"created_at":"2026-10-18T20:00:00Z","decided_at":null,"auto_approved":false},
  {"id":"c","media_ref":{"kind":"movie","tmdb_id":5,"title":"Four Rooms","year":1995},"requested_by":"u-nate","requested_by_name":"nate",
   "status":"fulfilled","monitored_item_id":"mi2","created_at":"2026-10-01T09:30:00Z","decided_at":"2026-10-01T09:30:01Z","auto_approved":true},
  {"id":"d","media_ref":{"kind":"movie","tmdb_id":6,"title":"Judgment Night","year":1993},"requested_by":"u-nate","requested_by_name":"nate",
   "status":"denied","monitored_item_id":null,"created_at":"2026-09-30T09:30:00Z","decided_at":"2026-09-30T10:00:00Z","auto_approved":false}
]}
"""#

@Suite("My requests")
struct MyRequestTests {

    @Test func onlyTheCallersOwnEvenForAnAdmin() async throws {
        let mine = try await session(Routes(["/api/v1/requests": (200, everyone)])).myRequests(userID: "u-nate")
        #expect(mine.map(\.title) == ["Piper", "Four Rooms", "Judgment Night"], "Maggie's request isn't nate's")
        #expect(mine[0].year == 2016 && mine[0].kind == .movie && mine[0].autoApproved)
    }

    @Test func eachStatusSaysWhereItStands() async throws {
        let mine = try await session(Routes(["/api/v1/requests": (200, everyone)])).myRequests(userID: "u-nate")
        #expect(mine.map(\.status) == [.approved, .fulfilled, .denied])
        #expect(mine.map(\.status.label) == ["Wanted · downloading", "In your library", "Declined"])
        #expect(MyRequest.Status(rawValue: "pending")?.label == "Awaiting approval")
    }

    @Test func whenItWasAskedFor() async throws {
        let mine = try await session(Routes(["/api/v1/requests": (200, everyone)])).myRequests(userID: "u-nate")
        let expected = ISO8601DateFormatter().date(from: "2026-10-19T14:43:05Z")!.addingTimeInterval(0.123)
        #expect(abs(try #require(mine[0].requestedAt).timeIntervalSince(expected)) < 0.001, "fractional seconds kept")
        #expect(mine[1].requestedAt == ISO8601DateFormatter().date(from: "2026-10-01T09:30:00Z"), "with or without fractions")
    }

    @Test func discoverTagsCountOnlyTheCallersRequests() async throws {
        let states = try await session(Routes(["/api/v1/requests": (200, everyone)])).myRequestStates(userID: "u-nate")
        #expect(states[DiscoverItem(tmdbID: 1399, kind: .series, title: "").id] == nil, "Maggie's pending request isn't nate's to show")
        #expect(states[DiscoverItem(tmdbID: 399106, kind: .movie, title: "").id] == .wanted)
    }
}
