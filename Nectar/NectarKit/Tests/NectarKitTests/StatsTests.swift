import Foundation
@testable import NectarKit
import Testing

private actor StatsServer: HTTPTransport {
    private(set) var asked: [URL] = []

    nonisolated func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        try await answer(request)
    }

    private func answer(_ request: URLRequest) throws -> (Data, HTTPURLResponse) {
        asked.append(request.url!)
        let body: String
        switch request.url!.path {
        case "/api/v1/stats/overview":
            body = #"{"users":3,"libraries":5,"items_by_type":{"movie":854,"series":53},"total_items":907,"total_watch_time_seconds":360000,"total_plays":420,"active_streams":1,"play_methods":{"DirectPlay":300,"Transcode":120},"transcode_ratio":0.2857}"#
        case "/api/v1/stats/activity":
            body = #"{"interval":"day","from":"2026-09-19T20:00:00Z","to":"2026-10-19T20:00:00Z","series":[{"bucket":"2026-10-17T00:00:00.000Z","plays":3,"watch_time_seconds":7200},{"bucket":"2026-10-19T00:00:00Z","plays":"5","watch_time_seconds":"9000"}]}"#
        case "/api/v1/stats/users":
            body = #"{"users":[{"user_id":"u1","username":"nate","plays":300,"watch_time_seconds":540000,"last_seen":"2026-10-19T19:00:00.000Z","favorite_genres":["Drama","Science Fiction"]},{"user_id":null,"username":null,"plays":4,"watch_time_seconds":100,"last_seen":null,"favorite_genres":[]}]}"#
        case "/api/v1/stats/items":
            body = #"{"metric":"plays","items":[{"item_id":"a","item_name":"Arrival","item_type":"movie","plays":12,"watch_time_seconds":50000},{"item_id":null,"item_name":"Gone","item_type":null,"plays":1,"watch_time_seconds":60}]}"#
        default:
            throw URLError(.fileDoesNotExist)
        }
        return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}

private func session(_ transport: StatsServer) -> NectarSession {
    NectarSession(
        baseURL: URL(string: "https://nectar.test")!,
        tokenEndpoint: URL(string: "https://nectar.test/token")!,
        clientID: "nectar-tv",
        store: InMemoryTokenStore(TokenSet(accessToken: "jwt-1", tokenType: "Bearer", expiresIn: nil, refreshToken: "r1")),
        transport: transport
    )
}

private func day(_ text: String) -> Date {
    ISO8601DateFormatter().date(from: "\(text)T00:00:00Z")!
}

struct StatsTests {

    @Test func theOverviewDecodesAndReadsAsHoursAndAShare() async throws {
        let overview = try await session(StatsServer()).statsOverview()
        #expect(overview.totalPlays == 420)
        #expect(overview.totalItems == 907)
        #expect(overview.itemsByType["series"] == 53)
        #expect(overview.playMethods["Transcode"] == 120)
        #expect(overview.transcodePercent == 29)
    }

    @Test func activityDecodesCountsWrittenEitherWayAndFillsTheQuietDays() async throws {
        let points = try await session(StatsServer()).statsActivity()
        #expect(points.map(\.plays) == [3, 5])
        #expect(points.last?.watchTimeSeconds == 9000)
        let days = ActivityPoint.days(points, count: 4, endingOn: day("2026-10-19"))
        #expect(days.map(\.bucket) == [day("2026-10-16"), day("2026-10-17"), day("2026-10-18"), day("2026-10-19")])
        #expect(days.map(\.plays) == [0, 3, 0, 5])
    }

    @Test func usersKeepTheirGenresAndAnUnknownViewerIsStillCounted() async throws {
        let users = try await session(StatsServer()).statsUsers()
        #expect(users.count == 2)
        #expect(users[0].username == "nate" && users[0].favoriteGenres == ["Drama", "Science Fiction"])
        #expect(users[0].lastSeen == ISO8601DateFormatter().date(from: "2026-10-19T19:00:00Z"))
        #expect(users[1].username == nil && users[1].lastSeen == nil)
    }

    @Test(arguments: [(0.0, "0 min"), (29.0, "0 min"), (2_700, "45 min"), (3_569, "59 min"), (3_600, "1 h"), (5_399, "1 h"), (360_000, "100 h")])
    func watchTimeReadsInMinutesUnderAnHourAndHoursAfter(_ seconds: Double, _ text: String) {
        #expect(watchTimeText(seconds) == text)
    }

    @Test func mostWatchedAsksForTheTopTenByPlays() async throws {
        let server = StatsServer()
        let items = try await session(server).statsItems()
        #expect(items.map(\.itemName) == ["Arrival", "Gone"])
        #expect(items.first?.itemID == "a" && items.last?.itemID == nil)
        let asked = try #require(await server.asked.last)
        let query = URLComponents(url: asked, resolvingAgainstBaseURL: false)?.queryItems ?? []
        #expect(Set(query.map { "\($0.name)=\($0.value ?? "")" }) == ["limit=10", "metric=plays"])
    }
}
