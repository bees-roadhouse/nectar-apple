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
    public let overview: String?
    /// The title's logo art, when nectar has one; root-relative.
    public let logoPath: String?
    public let genres: [String]?

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
        progressSeconds: Double? = nil,
        overview: String? = nil,
        logoPath: String? = nil,
        genres: [String]? = nil
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
        self.overview = overview
        self.logoPath = logoPath
        self.genres = genres
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
        case overview, genres
        case logoPath = "logo_url"
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

    /// Artwork at the width it's drawn, in pixels (nectar #413): `…/w{N}` gets the smallest copy
    /// nectar made at or above N, so a tile downloads kilobytes instead of the original.
    /// Rounded up, so never a blurrier copy than asked; a path that already names a size is left alone.
    public nonisolated func resolve(_ path: String?, pixelWidth: Double) -> URL? {
        guard let path, !path.isEmpty else { return nil }
        // Only nectar's own images come in widths; anything else as it is.
        guard path.hasPrefix("/api/v1/images/"), var components = URLComponents(string: path) else { return resolve(path) }
        let segments = components.path.split(separator: "/")
        let alreadySized = segments.count > 4 && segments.last?.range(of: #"^w?\d{1,5}$"#, options: .regularExpression) != nil
        if pixelWidth >= 1, pixelWidth.isFinite, !alreadySized {
            // Into the path, before any query nectar sent (#120: nectar #695 versions the URLs it hands out).
            components.path += "/w\(Int(pixelWidth.rounded(.up)))"
        }
        if components.queryItems?.contains(where: { $0.name == "v" }) != true {
            components.queryItems = (components.queryItems ?? []) + [URLQueryItem(name: "v", value: String(Self.imageVersion))]
        }
        return resolve(components.string)
    }

    /// nectar's `IMAGE_VERSION` (`shared/src/image_version.ts`, nectar #449), for a URL nectar sent without one. Once
    /// nectar #695 versions every image URL it hands out, the server's `v` wins and this is only a fallback.
    /// A versioned URL is immutable, so the image cache keeps it for good.
    static let imageVersion = 2
}
