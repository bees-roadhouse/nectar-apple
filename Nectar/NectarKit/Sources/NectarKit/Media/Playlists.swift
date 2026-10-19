import Foundation

/// An ordered list of titles the user made (a nectar collection of kind `playlist`).
public struct Playlist: Decodable, Equatable, Identifiable, Sendable {
    public let id: String
    public let name: String
    public let description: String?
    /// Owned members only; wanted entries aren't counted by nectar.
    public let itemCount: Int

    public init(id: String, name: String, description: String?, itemCount: Int) {
        self.id = id
        self.name = name
        self.description = description
        self.itemCount = itemCount
    }

    enum CodingKeys: String, CodingKey {
        case id, name, description
        case itemCount = "item_count"
    }

    /// `item_count` comes from SQL `COUNT()`, which postgres.js serialises as a string.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        description = try c.decodeIfPresent(String.self, forKey: .description)
        itemCount = (try? c.decode(Int.self, forKey: .itemCount)) ?? Int((try? c.decode(String.self, forKey: .itemCount)) ?? "") ?? 0
    }
}

/// One entry of a playlist: a title in the library, or one wanted and not here yet (nectar #433).
public struct PlaylistMember: Decodable, Equatable, Identifiable, Sendable {

    public enum Entry: String, Decodable, Sendable {
        case owned
        case wanted
    }

    /// The entry's id: what reorder and delete take.
    public let id: String
    public let entry: Entry
    public let itemType: String
    public let title: String
    public let year: Int?
    /// A nectar image path when owned, a TMDB URL when wanted.
    public let posterPath: String?
    public let mediaItemID: String?
    public let tmdbID: Int?
    /// The latest request for a wanted entry: pending, approved, denied, fulfilled.
    public let requestStatus: String?

    enum CodingKeys: String, CodingKey {
        case id, entry, title, year
        case itemType = "item_type"
        case posterPath = "poster_url"
        case mediaItemID = "media_item_id"
        case tmdbID = "tmdb_id"
        case requestStatus = "request_status"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        entry = try c.decode(Entry.self, forKey: .entry)
        itemType = try c.decode(String.self, forKey: .itemType)
        title = try c.decode(String.self, forKey: .title)
        year = try c.decodeIfPresent(Int.self, forKey: .year)
        posterPath = try c.decodeIfPresent(String.self, forKey: .posterPath)
        mediaItemID = try c.decodeIfPresent(String.self, forKey: .mediaItemID)
        tmdbID = (try? c.decodeIfPresent(Int.self, forKey: .tmdbID)) ?? (try? c.decodeIfPresent(String.self, forKey: .tmdbID)).flatMap { $0.flatMap(Int.init) }
        requestStatus = try c.decodeIfPresent(String.self, forKey: .requestStatus)
    }

    /// Something AVPlayer can play as one title: an owned movie or episode. A series is many things.
    public var isPlayable: Bool {
        entry == .owned && mediaItemID != nil && (itemType == "movie" || itemType == "episode")
    }
}

/// A playlist with its members, in order.
public struct PlaylistDetail: Equatable, Sendable {
    public let playlist: Playlist
    public let members: [PlaylistMember]

    /// What "Play" plays, in order: owned movies and episodes, as cards the player takes.
    public var playQueue: [MediaCard] {
        members.filter(\.isPlayable).map { member in
            MediaCard(id: member.mediaItemID!, itemType: member.itemType, title: member.title, year: member.year, posterPath: member.posterPath)
        }
    }
}

private struct PlaylistPage: Decodable {
    let collections: [Playlist]
}

private struct PlaylistDetailPage: Decodable {
    let collection: Playlist
    let items: [PlaylistMember]
}

extension NectarSession {

    /// The user's playlists (and global ones), `GET /api/v1/collections?kind=playlist`.
    public func playlists() async throws -> [Playlist] {
        let data = try await get("api/v1/collections", query: [URLQueryItem(name: "kind", value: "playlist")])
        return try JSONDecoder().decode(PlaylistPage.self, from: data).collections
    }

    /// One playlist with its owned and wanted members in order.
    public func playlist(_ id: String) async throws -> PlaylistDetail {
        let data = try await get("api/v1/collections/\(id)")
        let page = try JSONDecoder().decode(PlaylistDetailPage.self, from: data)
        return PlaylistDetail(playlist: page.collection, members: page.items)
    }
}
