import Foundation

/// Someone in the credits (`GET /api/v1/people/{id}`).
public struct Person: Equatable, Identifiable, Sendable {
    public let id: String
    public let name: String
    /// Only a URL the TV can load: nectar sometimes stores a path on its own disk.
    public let photo: URL?
    public let creditCount: Int
}

/// One title a person is in, as their page lists it.
public struct Credit: Equatable, Identifiable, Sendable {
    public let id: String
    public let itemType: String
    public let title: String
    public let year: Int?
    /// "as Louise Banks", or their jobs when they didn't play a part.
    public let role: String?
    public let posterPath: String?
    public let posterBlurHash: String?

    public var card: MediaCard {
        MediaCard(id: id, itemType: itemType, title: title, year: year, posterPath: posterPath, posterBlurHash: posterBlurHash)
    }
}

public struct PersonDetail: Equatable, Sendable {
    public let person: Person
    /// Newest first.
    public let credits: [Credit]
}

private struct PersonPage: Decodable {
    struct Row: Decodable {
        let id: String
        let name: String
        let profileImageURL: String?
        let creditCount: Int?

        enum CodingKeys: String, CodingKey {
            case id, name
            case profileImageURL = "profile_image_url"
            case creditCount = "credit_count"
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decode(String.self, forKey: .id)
            name = try c.decode(String.self, forKey: .name)
            profileImageURL = try c.decodeIfPresent(String.self, forKey: .profileImageURL)
            creditCount = c.lenientInt(.creditCount)
        }
    }

    struct Film: Decodable {
        let id: String
        let itemType: String
        let title: String
        let year: Int?
        let roles: [String]?
        let character: String?
        let posterURL: String?
        let posterBlurHash: String?

        enum CodingKeys: String, CodingKey {
            case id, title, year, roles, character
            case itemType = "item_type"
            case posterURL = "poster_url"
            case posterBlurHash = "poster_blurhash"
        }
    }

    let person: Row
    let filmography: [Film]
}

/// One server-ordered directory page. Credit counts are global credits, not scoped title counts.
public struct PeoplePage: Decodable, Sendable {
    public let people: [Person]
    public let total: Int

    private enum CodingKeys: String, CodingKey { case people, total }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        people = try c.decode([PersonPage.Row].self, forKey: .people).map { row in
            let photo = row.profileImageURL.flatMap(URL.init(string:)).flatMap { $0.scheme?.hasPrefix("http") == true ? $0 : nil }
            return Person(id: row.id, name: row.name, photo: photo, creditCount: row.creditCount ?? 0)
        }
        total = c.lenientInt(.total) ?? people.count
    }
}

extension NectarSession {

    public func people(search: String = "", offset: Int = 0) async throws -> PeoplePage {
        let search = search.trimmingCharacters(in: .whitespacesAndNewlines)
        var query = [URLQueryItem(name: "limit", value: "60"), URLQueryItem(name: "offset", value: String(max(0, offset)))]
        if !search.isEmpty { query.append(URLQueryItem(name: "search", value: search)) }
        return try JSONDecoder().decode(PeoplePage.self, from: try await get("api/v1/people", query: query))
    }

    public func person(_ id: String) async throws -> PersonDetail {
        let page = try JSONDecoder().decode(PersonPage.self, from: try await get("api/v1/people/\(id)"))
        let photo = page.person.profileImageURL.flatMap(URL.init(string:)).flatMap { $0.scheme?.hasPrefix("http") == true ? $0 : nil }
        let person = Person(id: page.person.id, name: page.person.name, photo: photo, creditCount: page.person.creditCount ?? page.filmography.count)
        let credits = page.filmography.map { film in
            let role: String? = if let character = film.character, !character.isEmpty {
                "as \(character)"
            } else if let roles = film.roles, !roles.isEmpty {
                roles.joined(separator: ", ")
            } else {
                nil
            }
            return Credit(id: film.id, itemType: film.itemType, title: film.title, year: film.year, role: role, posterPath: film.posterURL,
                          posterBlurHash: film.posterBlurHash)
        }
        return PersonDetail(person: person, credits: credits)
    }

    /// The server's collections or playlists: `collection` or `playlist`.
    public func collections(kind: String) async throws -> [Playlist] {
        let data = try await get("api/v1/collections", query: [URLQueryItem(name: "kind", value: kind)])
        return try JSONDecoder().decode(CollectionPage.self, from: data).collections
    }
}

private struct CollectionPage: Decodable {
    let collections: [Playlist]
}
