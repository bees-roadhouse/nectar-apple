import Foundation

/// A title nectar's dreaming loop picked for this user (`GET /api/v1/recommendations`): owned, or one to discover.
public struct Recommendation: Decodable, Equatable, Identifiable, Sendable {
    public let id: String
    public let title: String
    public let year: Int?
    /// `movie` or `series`.
    public let kind: String?
    public let inLibrary: Bool
    public let mediaItemID: String?
    public let posterPath: String?
    /// nil for a title to discover: its poster is TMDB's.
    public let posterBlurHash: String?
    /// Why it was picked, when nectar says.
    public let reason: String?
    let tmdbID: Int?

    /// Not in the library: the Discover result it stands for, so Want it and Add to playlist work as there.
    public var discoverItem: DiscoverItem? {
        guard !inLibrary || mediaItemID == nil, let tmdbID else { return nil }
        let kind: DiscoverItem.Kind = self.kind == "series" || self.kind == "tv" ? .series : .movie
        return DiscoverItem(tmdbID: tmdbID, kind: kind, title: title, year: year)
    }

    private enum Keys: String, CodingKey {
        case id, title, year, kind, reason
        case inLibrary = "in_library"
        case mediaItemID = "media_item_id"
        case posterPath = "poster_url"
        case posterBlurHash = "poster_blurhash"
        case mediaRef = "media_ref"
    }

    private enum Ref: String, CodingKey {
        case tmdbID = "tmdb_id"
        case title
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        id = try c.decode(String.self, forKey: .id)
        let ref = try? c.nestedContainer(keyedBy: Ref.self, forKey: .mediaRef)
        let refTitle = try ref?.decodeIfPresent(String.self, forKey: .title)
        title = (try c.decodeIfPresent(String.self, forKey: .title)) ?? refTitle ?? "Untitled"
        year = c.lenientInt(.year)
        kind = try c.decodeIfPresent(String.self, forKey: .kind)
        inLibrary = (try c.decodeIfPresent(Bool.self, forKey: .inLibrary)) ?? false
        mediaItemID = try c.decodeIfPresent(String.self, forKey: .mediaItemID)
        posterPath = try c.decodeIfPresent(String.self, forKey: .posterPath)
        posterBlurHash = try c.decodeIfPresent(String.self, forKey: .posterBlurHash)
        reason = try c.decodeIfPresent(String.self, forKey: .reason)
        tmdbID = ref?.lenientInt(.tmdbID)
    }
}

private struct Recommendations: Decodable {
    let recommendations: [Recommendation]
}

extension NectarSession {
    /// This user's recommendations, best first; empty until nectar has dreamt for them.
    public func recommendations() async throws -> [Recommendation] {
        try JSONDecoder().decode(Recommendations.self, from: try await get("api/v1/recommendations")).recommendations
    }
}
