import Foundation

/// What a library search looks through (`/api/v1/search…`): titles, or moments inside them.
public enum SearchMode: String, CaseIterable, Sendable {
    /// Titles by their words and meaning.
    case titles
    /// What's said: transcript lines, each a moment to play from.
    case dialogue
    /// What's seen: the best-matching frame of each title.
    case scenes
    /// What's heard: tracks by sound.
    case audio

    public var title: String {
        switch self {
        case .titles: "Titles"
        case .dialogue: "Dialogue"
        case .scenes: "Scenes"
        case .audio: "Audio"
        }
    }
}

public enum SearchError: Error, Equatable {
    /// nectar has this kind of search switched off (scenes and audio are opt-in on the server).
    case disabled
}

/// A title found by `GET /api/v1/search`.
public struct TitleHit: Decodable, Equatable, Identifiable, Sendable {
    public let id: String
    public let itemType: String
    public let title: String
    public let year: Int?
    public let overview: String?
    /// nectar doesn't send one yet; used as soon as it does.
    public let posterPath: String?
    public let posterBlurHash: String?

    enum CodingKeys: String, CodingKey {
        case id, title, year, overview
        case itemType = "item_type"
        case posterPath = "poster_url"
        case posterBlurHash = "poster_blurhash"
    }

    public init(
        id: String, itemType: String, title: String, year: Int? = nil, overview: String? = nil, posterPath: String? = nil,
        posterBlurHash: String? = nil
    ) {
        self.id = id
        self.itemType = itemType
        self.title = title
        self.year = year
        self.overview = overview
        self.posterPath = posterPath
        self.posterBlurHash = posterBlurHash
    }


    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        itemType = try c.decode(String.self, forKey: .itemType)
        title = (try c.decodeIfPresent(String.self, forKey: .title)) ?? "Untitled"
        year = c.lenientInt(.year)
        overview = try c.decodeIfPresent(String.self, forKey: .overview)
        posterPath = try c.decodeIfPresent(String.self, forKey: .posterPath)
        posterBlurHash = try c.decodeIfPresent(String.self, forKey: .posterBlurHash)
    }
}

/// A dialogue, scene or audio hit: a title, and for dialogue and scenes the moment in it.
public struct SearchHit: Decodable, Equatable, Identifiable, Sendable {
    public let itemID: String
    public let itemType: String
    public let title: String
    public let posterPath: String?
    /// The frame at the moment; it needs the token.
    public let thumbPath: String?
    /// Where in the title; nil for audio.
    public let seconds: Double?
    /// The line, for dialogue.
    public let snippet: String?
    /// Which library the title is in: a library's own search keeps only its lines (#96).
    public let libraryID: String?

    /// One title can match at several moments.
    public var id: String { "\(itemID)@\(seconds ?? -1)" }

    /// The card the player takes, starting at the moment.
    public var card: MediaCard {
        MediaCard(id: itemID, itemType: itemType, title: title, posterPath: posterPath, progressSeconds: seconds)
    }

    enum CodingKeys: String, CodingKey {
        case title, snippet
        case itemID = "media_item_id"
        case itemType = "item_type"
        case posterPath = "poster_url"
        case thumbPath = "thumb_url"
        case seconds = "t_seconds"
        case libraryID = "library_id"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        itemID = try c.decode(String.self, forKey: .itemID)
        itemType = try c.decode(String.self, forKey: .itemType)
        title = (try c.decodeIfPresent(String.self, forKey: .title)) ?? "Untitled"
        posterPath = try c.decodeIfPresent(String.self, forKey: .posterPath)
        thumbPath = try c.decodeIfPresent(String.self, forKey: .thumbPath)
        seconds = c.lenientDouble(.seconds)
        snippet = try c.decodeIfPresent(String.self, forKey: .snippet)
        libraryID = try c.decodeIfPresent(String.self, forKey: .libraryID)
    }
}

private struct Results<Hit: Decodable>: Decodable {
    let results: [Hit]
}

extension NectarSession {

    /// Titles matching `query`, best first; with a `library`, only that library's, scoped by nectar (#96).
    public func searchTitles(_ query: String, library: String? = nil, limit: Int = 40) async throws -> [TitleHit] {
        let data = try await get("api/v1/search", query: Self.searchQuery(query, library: library, limit: limit))
        return try JSONDecoder().decode(Results<TitleHit>.self, from: data).results
    }

    /// Dialogue, scene or audio hits for `query`. Throws ``SearchError/disabled`` when nectar has the mode off.
    /// With a `library`, only that library's: nectar is asked to scope it (nectar#610), and until it does,
    /// hits from other libraries are dropped here.
    public func searchMoments(_ query: String, in mode: SearchMode, library: String? = nil, limit: Int = 30) async throws -> [SearchHit] {
        precondition(mode != .titles, "titles come from searchTitles")
        do {
            let data = try await get("api/v1/search/\(mode.rawValue)", query: Self.searchQuery(query, library: library, limit: limit))
            let hits = try JSONDecoder().decode(Results<SearchHit>.self, from: data).results
            guard let library else { return hits }
            return hits.filter { $0.libraryID == nil || $0.libraryID == library }
        } catch NectarSessionError.unexpectedStatus(400) where mode == .scenes || mode == .audio {
            throw SearchError.disabled
        }
    }

    private static func searchQuery(_ query: String, library: String?, limit: Int) -> [URLQueryItem] {
        var items = [URLQueryItem(name: "q", value: query), URLQueryItem(name: "limit", value: String(limit))]
        if let library { items.append(URLQueryItem(name: "library_id", value: library)) }
        return items
    }
}
