import Foundation

/// A library the user can see (`GET /api/v1/libraries`).
public struct Library: Decodable, Equatable, Identifiable, Sendable {

    /// nectar's library types (`shared/src/library.ts`), and anything newer as it's named.
    public enum Kind: Equatable, Sendable {
        case movies
        case shows
        case music
        case books
        case photos
        case other(String)

        /// What a grid of this library lists: a shows library's series are nectar's default;
        /// a music library would otherwise list every track, not its albums.
        var topLevelType: String? {
            switch self {
            case .music: "album"
            case .books: "book"
            case .photos: "photo"
            case .movies, .shows, .other: nil
            }
        }
    }

    public let id: String
    public let name: String
    public let kind: Kind
    public let itemCount: Int

    enum CodingKeys: String, CodingKey {
        case id, name
        case kind = "library_type"
        case itemCount = "item_count"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        switch try c.decode(String.self, forKey: .kind) {
        case "movies": kind = .movies
        case "shows": kind = .shows
        case "music": kind = .music
        case "books": kind = .books
        case "photos": kind = .photos
        case let other: kind = .other(other)
        }
        itemCount = c.lenientInt(.itemCount) ?? 0
    }
}

/// One page of a library grid: what `GET /api/v1/media` is asked for.
public struct LibraryQuery: Equatable, Sendable {

    public enum Sort: String, CaseIterable, Sendable {
        case title
        case year
        case dateAdded = "date_added"
        case rating
    }

    public let library: String
    /// The kind of item listed, from the library's type; nil leaves it to nectar.
    public var itemType: String?
    public var sort: Sort = .title
    public var descending = false
    public var genre: String?
    public var resolution: String?
    public var offset = 0
    public var limit = 60

    public init(library: String, itemType: String? = nil) {
        self.library = library
        self.itemType = itemType
    }

    /// The first page of a library, listing what it holds at the top level.
    public init(_ library: Library) {
        self.init(library: library.id, itemType: library.kind.topLevelType)
    }

    var queryItems: [URLQueryItem] {
        var items = [URLQueryItem(name: "library", value: library)]
        if let itemType { items.append(URLQueryItem(name: "type", value: itemType)) }
        items += [
            URLQueryItem(name: "sort", value: sort.rawValue),
            URLQueryItem(name: "order", value: descending ? "desc" : "asc"),
        ]
        if let genre { items.append(URLQueryItem(name: "genre", value: genre)) }
        if let resolution { items.append(URLQueryItem(name: "resolution", value: resolution)) }
        items.append(URLQueryItem(name: "limit", value: String(limit)))
        items.append(URLQueryItem(name: "offset", value: String(offset)))
        return items
    }
}

/// A page of a library, and how many there are in all.
public struct LibraryPage: Decodable, Sendable {
    public let items: [MediaCard]
    public let total: Int

    enum CodingKeys: String, CodingKey { case items, total }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        items = try c.decode([MediaCard].self, forKey: .items)
        total = c.lenientInt(.total) ?? items.count
    }
}

/// What a library can be narrowed by (`GET /api/v1/media/filters`); the TV offers genre and resolution.
public struct LibraryFilters: Decodable, Equatable, Sendable {
    public let genres: [String]
    public let resolutions: [String]

    public init(genres: [String], resolutions: [String]) {
        self.genres = genres
        self.resolutions = resolutions
    }
}

private struct Libraries: Decodable {
    let libraries: [Library]
}

extension KeyedDecodingContainer {
    /// SQL `COUNT()` comes through postgres.js as a string; anything else as a number.
    func lenientInt(_ key: Key) -> Int? {
        if let number = try? decode(Int.self, forKey: key) { return number }
        return (try? decode(String.self, forKey: key)).flatMap(Int.init)
    }
}

extension NectarSession {

    public func libraries() async throws -> [Library] {
        try JSONDecoder().decode(Libraries.self, from: try await get("api/v1/libraries")).libraries
    }

    public func media(_ query: LibraryQuery) async throws -> LibraryPage {
        try JSONDecoder().decode(LibraryPage.self, from: try await get("api/v1/media", query: query.queryItems))
    }

    public func filters(library: String) async throws -> LibraryFilters {
        let data = try await get("api/v1/media/filters", query: [URLQueryItem(name: "library", value: library)])
        return try JSONDecoder().decode(LibraryFilters.self, from: data)
    }
}
