import Foundation

/// One card in a row: the media row nectar summarises for every list, as much of it as a row shows.
///
/// nectar sends far more (codecs, file path, ratings); those stay undecoded until something uses them.
/// Every field but the id is optional, so a row with a gap still shows its title rather than failing whole.
public struct MediaCard: Decodable, Equatable, Identifiable, Sendable {
    public let id: String
    public let itemType: String?
    public let title: String?
    /// An episode's series (nectar#393); nil for anything else.
    public let seriesTitle: String?
    public let year: Int?
    public let runtimeSeconds: Double?
    public let seasonNumber: Int?
    public let episodeNumber: Int?
    /// Root-relative (`/api/v1/images/{id}`); resolve with ``NectarSession/resolve(_:)``.
    public let posterPath: String?
    public let backdropPath: String?
    /// How far in this user is, on the continue row only.
    public let progressSeconds: Double?

    public init(
        id: String,
        itemType: String? = nil,
        title: String? = nil,
        seriesTitle: String? = nil,
        year: Int? = nil,
        runtimeSeconds: Double? = nil,
        seasonNumber: Int? = nil,
        episodeNumber: Int? = nil,
        posterPath: String? = nil,
        backdropPath: String? = nil,
        progressSeconds: Double? = nil
    ) {
        self.id = id
        self.itemType = itemType
        self.title = title
        self.seriesTitle = seriesTitle
        self.year = year
        self.runtimeSeconds = runtimeSeconds
        self.seasonNumber = seasonNumber
        self.episodeNumber = episodeNumber
        self.posterPath = posterPath
        self.backdropPath = backdropPath
        self.progressSeconds = progressSeconds
    }

    enum CodingKeys: String, CodingKey {
        case id
        case itemType = "item_type"
        case title
        case seriesTitle = "series_title"
        case year
        case runtimeSeconds = "runtime_seconds"
        case seasonNumber = "season_number"
        case episodeNumber = "episode_number"
        case posterPath = "poster_url"
        case backdropPath = "backdrop_url"
        case progressSeconds = "progress_seconds"
    }

    /// How far through, 0...1, or nil when nectar doesn't know the runtime.
    public var progress: Double? {
        guard let runtimeSeconds, runtimeSeconds > 0, let progressSeconds else { return nil }
        return min(max(progressSeconds / runtimeSeconds, 0), 1)
    }

    /// The wide artwork a row card wants, falling back to the poster.
    public var artworkPath: String? {
        backdropPath ?? posterPath
    }
}

struct MediaPage: Decodable {
    let items: [MediaCard]
}

extension NectarSession {

    /// What this user started and didn't finish, most recently played first
    /// (`GET /api/v1/media/continue`; nectar clamps `limit` to 1...100).
    public func continueWatching(limit: Int = 20) async throws -> [MediaCard] {
        let data = try await get("api/v1/media/continue", query: [URLQueryItem(name: "limit", value: String(limit))])
        return try JSONDecoder().decode(MediaPage.self, from: data).items
    }

    /// A root-relative path nectar hands out (artwork, for one) as a full URL on this server.
    /// Images need no token, so the URL loads as it is.
    public nonisolated func resolve(_ path: String?) -> URL? {
        guard let path, !path.isEmpty else { return nil }
        return URL(string: path, relativeTo: baseURL)?.absoluteURL
    }
}
