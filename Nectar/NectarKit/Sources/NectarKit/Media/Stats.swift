import Foundation

/// The whole server at a glance (`GET /api/v1/stats/overview`, admins only, #81).
public struct StatsOverview: Decodable, Equatable, Sendable {
    public let users: Int
    public let libraries: Int
    public let itemsByType: [String: Int]
    public let totalItems: Int
    public let totalWatchTimeSeconds: Double
    public let totalPlays: Int
    public let activeStreams: Int
    /// `DirectPlay`, `DirectStream`, `Transcode`: how many plays went each way.
    public let playMethods: [String: Int]
    /// Transcoded plays over all plays, 0...1.
    public let transcodeRatio: Double

    public var transcodePercent: Int {
        Int((transcodeRatio * 100).rounded())
    }

    private enum Keys: String, CodingKey {
        case users, libraries
        case itemsByType = "items_by_type"
        case totalItems = "total_items"
        case totalWatchTimeSeconds = "total_watch_time_seconds"
        case totalPlays = "total_plays"
        case activeStreams = "active_streams"
        case playMethods = "play_methods"
        case transcodeRatio = "transcode_ratio"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        users = c.lenientInt(.users) ?? 0
        libraries = c.lenientInt(.libraries) ?? 0
        itemsByType = (try? c.decode([String: Int].self, forKey: .itemsByType)) ?? [:]
        totalItems = c.lenientInt(.totalItems) ?? 0
        totalWatchTimeSeconds = c.lenientDouble(.totalWatchTimeSeconds) ?? 0
        totalPlays = c.lenientInt(.totalPlays) ?? 0
        activeStreams = c.lenientInt(.activeStreams) ?? 0
        playMethods = (try? c.decode([String: Int].self, forKey: .playMethods)) ?? [:]
        transcodeRatio = c.lenientDouble(.transcodeRatio) ?? 0
    }
}

/// Plays and watch time in one day (`GET /api/v1/stats/activity`).
public struct ActivityPoint: Decodable, Equatable, Sendable {
    public let bucket: Date
    public let plays: Int
    public let watchTimeSeconds: Double

    public init(bucket: Date, plays: Int, watchTimeSeconds: Double) {
        self.bucket = bucket
        self.plays = plays
        self.watchTimeSeconds = watchTimeSeconds
    }

    /// The last `count` UTC days to `endingOn`, a quiet day as zero: nectar only lists days with plays,
    /// and a chart with gaps closed up reads as busier than it was.
    public static func days(_ points: [ActivityPoint], count: Int, endingOn end: Date) -> [ActivityPoint] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let last = calendar.startOfDay(for: end)
        let byDay = Dictionary(points.map { (calendar.startOfDay(for: $0.bucket), $0) }, uniquingKeysWith: { a, _ in a })
        return (0 ..< count).reversed().compactMap { back in
            calendar.date(byAdding: .day, value: -back, to: last).map { day in
                byDay[day].map { ActivityPoint(bucket: day, plays: $0.plays, watchTimeSeconds: $0.watchTimeSeconds) }
                    ?? ActivityPoint(bucket: day, plays: 0, watchTimeSeconds: 0)
            }
        }
    }

    private enum Keys: String, CodingKey {
        case bucket, plays
        case watchTimeSeconds = "watch_time_seconds"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        bucket = try StatsDate.decode(c, .bucket) ?? Date.distantPast
        plays = c.lenientInt(.plays) ?? 0
        watchTimeSeconds = c.lenientDouble(.watchTimeSeconds) ?? 0
    }
}

/// One viewer's plays (`GET /api/v1/stats/users`); plays from a since-deleted user have no id or name.
public struct UserStat: Decodable, Equatable, Identifiable, Sendable {
    public let userID: String?
    public let username: String?
    public let plays: Int
    public let watchTimeSeconds: Double
    public let lastSeen: Date?
    public let favoriteGenres: [String]

    public var id: String {
        userID ?? "unknown"
    }

    private enum Keys: String, CodingKey {
        case username, plays
        case userID = "user_id"
        case watchTimeSeconds = "watch_time_seconds"
        case lastSeen = "last_seen"
        case favoriteGenres = "favorite_genres"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        userID = try c.decodeIfPresent(String.self, forKey: .userID)
        username = try c.decodeIfPresent(String.self, forKey: .username)
        plays = c.lenientInt(.plays) ?? 0
        watchTimeSeconds = c.lenientDouble(.watchTimeSeconds) ?? 0
        lastSeen = try StatsDate.decode(c, .lastSeen)
        favoriteGenres = (try? c.decode([String].self, forKey: .favoriteGenres)) ?? []
    }
}

/// A most-watched title (`GET /api/v1/stats/items`); one removed since has no id.
public struct ItemStat: Decodable, Equatable, Sendable {
    public let itemID: String?
    public let itemName: String?
    public let itemType: String?
    public let plays: Int
    public let watchTimeSeconds: Double

    private enum Keys: String, CodingKey {
        case plays
        case itemID = "item_id"
        case itemName = "item_name"
        case itemType = "item_type"
        case watchTimeSeconds = "watch_time_seconds"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        itemID = try c.decodeIfPresent(String.self, forKey: .itemID)
        itemName = try c.decodeIfPresent(String.self, forKey: .itemName)
        itemType = try c.decodeIfPresent(String.self, forKey: .itemType)
        plays = c.lenientInt(.plays) ?? 0
        watchTimeSeconds = c.lenientDouble(.watchTimeSeconds) ?? 0
    }
}

/// Watch time as a person reads it: minutes under an hour ("45 min"), hours after ("12 h").
public func watchTimeText(_ seconds: Double) -> String {
    let minutes = Int((seconds / 60).rounded())
    return minutes < 60 ? "\(minutes) min" : "\(Int((seconds / 3600).rounded())) h"
}

/// nectar's timestamps, with or without fractional seconds.
enum StatsDate {
    static func decode<K: CodingKey>(_ c: KeyedDecodingContainer<K>, _ key: K) throws -> Date? {
        guard let text = try c.decodeIfPresent(String.self, forKey: key) else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: text) ?? ISO8601DateFormatter().date(from: text)
    }
}

private struct ActivityResponse: Decodable {
    let series: [ActivityPoint]
}

private struct UsersResponse: Decodable {
    let users: [UserStat]
}

private struct ItemsResponse: Decodable {
    let items: [ItemStat]
}

extension NectarSession {

    public func statsOverview() async throws -> StatsOverview {
        try JSONDecoder().decode(StatsOverview.self, from: try await get("api/v1/stats/overview"))
    }

    /// Plays per day over nectar's default window, the last 30 days.
    public func statsActivity() async throws -> [ActivityPoint] {
        try JSONDecoder().decode(ActivityResponse.self, from: try await get("api/v1/stats/activity")).series
    }

    public func statsUsers() async throws -> [UserStat] {
        try JSONDecoder().decode(UsersResponse.self, from: try await get("api/v1/stats/users")).users
    }

    /// The most-played titles.
    public func statsItems(limit: Int = 10) async throws -> [ItemStat] {
        let query = [URLQueryItem(name: "metric", value: "plays"), URLQueryItem(name: "limit", value: String(limit))]
        return try JSONDecoder().decode(ItemsResponse.self, from: try await get("api/v1/stats/items", query: query)).items
    }
}
