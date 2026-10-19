import Foundation

/// A title from TMDB through nectar's Discover: owned or not, with the caller's request state.
public struct DiscoverItem: Decodable, Equatable, Identifiable, Sendable {

    public enum Kind: String, Decodable, Sendable {
        case movie
        case series
    }

    public let tmdbID: Int
    public let kind: Kind
    public let title: String
    public let year: Int?
    public let overview: String?
    /// TMDB's CDN, already sized by nectar (posters w342, backdrops w780).
    public let posterURL: URL?
    public let backdropURL: URL?
    /// TMDB's vote average, 0–10.
    public let rating: Double?
    public let inLibrary: Bool
    /// This user already has a pending or approved request for it.
    public let alreadyRequested: Bool

    /// TMDB numbers movies and series separately, so the id needs both.
    public var id: String { "\(kind.rawValue)-\(tmdbID)" }

    public init(
        tmdbID: Int,
        kind: Kind,
        title: String,
        year: Int? = nil,
        overview: String? = nil,
        posterURL: URL? = nil,
        backdropURL: URL? = nil,
        rating: Double? = nil,
        inLibrary: Bool = false,
        alreadyRequested: Bool = false
    ) {
        self.tmdbID = tmdbID
        self.kind = kind
        self.title = title
        self.year = year
        self.overview = overview
        self.posterURL = posterURL
        self.backdropURL = backdropURL
        self.rating = rating
        self.inLibrary = inLibrary
        self.alreadyRequested = alreadyRequested
    }

    enum CodingKeys: String, CodingKey {
        case tmdbID = "tmdb_id"
        case kind
        case title
        case year
        case overview
        case posterURL = "poster_url"
        case backdropURL = "backdrop_url"
        case rating = "vote_average"
        case inLibrary = "in_library"
        case alreadyRequested = "already_requested"
    }
}

/// Which titles Discover lists.
public enum DiscoverKind: String, Sendable {
    case all
    case movie
    case tv
}

struct DiscoverPage: Decodable {
    let results: [DiscoverItem]
}

extension NectarSession {

    /// What's popular on TMDB now (`GET /api/v1/discover/trending`), marked against the library.
    public func discoverTrending(_ kind: DiscoverKind = .all) async throws -> [DiscoverItem] {
        let data = try await get("api/v1/discover/trending", query: [URLQueryItem(name: "kind", value: kind.rawValue)])
        return try JSONDecoder().decode(DiscoverPage.self, from: data).results
    }

    /// TMDB search through nectar (`GET /api/v1/discover/search`): titles whether owned or not.
    public func discoverSearch(_ query: String, kind: DiscoverKind = .all) async throws -> [DiscoverItem] {
        let data = try await get("api/v1/discover/search", query: [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "kind", value: kind.rawValue),
        ])
        return try JSONDecoder().decode(DiscoverPage.self, from: data).results
    }
}
