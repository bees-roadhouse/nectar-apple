import Foundation

/// A title in the library, as its detail page shows it (`GET /api/v1/media/{id}`).
public struct ItemDetail: Decodable, Equatable, Identifiable, Sendable {

    public struct CastMember: Equatable, Identifiable, Sendable {
        public let id: String
        public let name: String
        public let character: String?
        /// Only a URL the TV can load: nectar sometimes stores a path on its own disk instead.
        public let photo: URL?
    }

    public struct Chapter: Decodable, Equatable, Identifiable, Sendable {
        public let index: Int
        public let title: String?
        public let startSeconds: Double
        public var id: Int { index }

        enum CodingKeys: String, CodingKey {
            case index = "idx"
            case title
            case startSeconds = "start_seconds"
        }

        /// The chapter's thumbnail; it needs the token, so it goes through ``NectarSession/mediaURL(_:)``.
        public func thumbnailPath(item: String) -> String {
            "/api/v1/media/\(item)/chapters/\(index)"
        }
    }

    public let id: String
    public let itemType: String
    public let title: String
    public let year: Int?
    public let overview: String?
    public let tagline: String?
    public let contentRating: String?
    public let communityRating: Double?
    public let runtimeSeconds: Double?
    public let posterPath: String?
    public let backdropPath: String?
    public let genres: [String]
    public let cast: [CastMember]
    public let directors: [String]
    /// Root-relative; the file needs the token.
    public let trailerPath: String?
    public let chapters: [Chapter]
    public let seasonCount: Int?
    public let episodeCount: Int?
    /// Where this user stopped; nil when they haven't started, or finished.
    public let resumeSeconds: Double?
    /// What the file is, for Playback info (#82).
    public let source: PlaybackSource

    /// The card the player takes, starting at `seconds` (or the start).
    public func card(startingAt seconds: Double?) -> MediaCard {
        MediaCard(id: id, itemType: itemType, title: title, year: year, runtimeSeconds: runtimeSeconds,
                  posterPath: posterPath, backdropPath: backdropPath, progressSeconds: seconds)
    }

    private enum Outer: String, CodingKey { case item, progress }

    private enum Keys: String, CodingKey {
        case id, title, year, overview, tagline, genres, images, credits, chapters
        case itemType = "item_type"
        case contentRating = "content_rating"
        case communityRating = "community_rating"
        case runtimeSeconds = "runtime_seconds"
        case posterPath = "poster_url"
        case trailerPath = "trailer_url"
        case seasonCount = "season_count"
        case episodeCount = "episode_count"
    }

    private struct Image: Decodable {
        let imageType: String
        let url: String

        enum CodingKeys: String, CodingKey {
            case imageType = "image_type"
            case url
        }
    }

    private struct Credits: Decodable {
        struct Cast: Decodable {
            let personID: String
            let name: String
            let character: String?
            let profileImageURL: String?

            enum CodingKeys: String, CodingKey {
                case name, character
                case personID = "person_id"
                case profileImageURL = "profile_image_url"
            }
        }

        struct Crew: Decodable {
            let name: String
            let job: String?
        }

        let cast: [Cast]
        let crew: [Crew]
    }

    private struct Progress: Decodable {
        let positionSeconds: Double?
        let completed: Bool?

        enum CodingKeys: String, CodingKey {
            case positionSeconds = "position_seconds"
            case completed
        }
    }

    public init(from decoder: Decoder) throws {
        let outer = try decoder.container(keyedBy: Outer.self)
        let c = try outer.nestedContainer(keyedBy: Keys.self, forKey: .item)
        id = try c.decode(String.self, forKey: .id)
        itemType = try c.decode(String.self, forKey: .itemType)
        title = (try c.decodeIfPresent(String.self, forKey: .title)) ?? "Untitled"
        year = c.lenientInt(.year)
        overview = try c.decodeIfPresent(String.self, forKey: .overview)
        tagline = try c.decodeIfPresent(String.self, forKey: .tagline)
        contentRating = try c.decodeIfPresent(String.self, forKey: .contentRating)
        communityRating = c.lenientDouble(.communityRating)
        runtimeSeconds = c.lenientDouble(.runtimeSeconds)
        posterPath = try c.decodeIfPresent(String.self, forKey: .posterPath)
        let images = (try? c.decodeIfPresent([Image].self, forKey: .images)) ?? []
        backdropPath = images.first { $0.imageType == "backdrop" }?.url
        genres = (try? c.decodeIfPresent([String].self, forKey: .genres)) ?? []
        let credits = try? c.decodeIfPresent(Credits.self, forKey: .credits)
        cast = (credits?.cast ?? []).map { person in
            let photo = person.profileImageURL.flatMap(URL.init(string:)).flatMap { $0.scheme?.hasPrefix("http") == true ? $0 : nil }
            return CastMember(id: person.personID, name: person.name, character: person.character, photo: photo)
        }
        directors = (credits?.crew ?? []).filter { $0.job == "Director" }.map(\.name)
        trailerPath = try c.decodeIfPresent(String.self, forKey: .trailerPath)
        chapters = (try? c.decodeIfPresent([Chapter].self, forKey: .chapters)) ?? []
        seasonCount = c.lenientInt(.seasonCount)
        episodeCount = c.lenientInt(.episodeCount)
        source = (try? outer.decode(PlaybackSource.self, forKey: .item))
            ?? PlaybackSource(container: nil, videoCodec: nil, resolution: nil, hdr: nil, bitrate: nil, sizeBytes: nil, audioTracks: [])
        let progress = try? outer.decodeIfPresent(Progress.self, forKey: .progress)
        if let progress, progress.completed != true, let position = progress.positionSeconds, position > 0 {
            resumeSeconds = position
        } else {
            resumeSeconds = nil
        }
    }
}

private struct Similar: Decodable {
    let items: [MediaCard]
}

extension KeyedDecodingContainer {
    /// A numeric column postgres.js may send as a string.
    func lenientDouble(_ key: Key) -> Double? {
        if let number = try? decode(Double.self, forKey: key) { return number }
        return (try? decode(String.self, forKey: key)).flatMap(Double.init)
    }
}

extension NectarSession {

    public func detail(_ id: String) async throws -> ItemDetail {
        try JSONDecoder().decode(ItemDetail.self, from: try await get("api/v1/media/\(id)"))
    }

    /// Up to twelve titles like this one, of its type.
    public func similar(to id: String) async throws -> [MediaCard] {
        try JSONDecoder().decode(Similar.self, from: try await get("api/v1/media/\(id)/similar")).items
    }
}
