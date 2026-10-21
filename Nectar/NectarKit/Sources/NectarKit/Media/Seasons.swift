import Foundation

/// One episode of a series, with this user's watched state (`GET /api/v1/media/{series}/children`).
public struct Episode: Decodable, Equatable, Identifiable, Sendable {
    public let id: String
    public let number: Int?
    public let seasonNumber: Int?
    public let title: String
    public let overview: String?
    public let runtimeSeconds: Double?
    public let watched: Bool
    /// How far in this user is; 0 when never started.
    public let progressSeconds: Double
    public let thumbPath: String?
    public let thumbBlurHash: String?

    enum CodingKeys: String, CodingKey {
        case id, title, overview, watched
        case number = "episode_number"
        case seasonNumber = "season_number"
        case runtimeSeconds = "runtime_seconds"
        case progressSeconds = "progress_seconds"
        case thumbPath = "thumb_url"
        case thumbBlurHash = "thumb_blurhash"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        number = c.lenientInt(.number)
        seasonNumber = c.lenientInt(.seasonNumber)
        title = (try c.decodeIfPresent(String.self, forKey: .title)) ?? "Untitled"
        overview = try c.decodeIfPresent(String.self, forKey: .overview)
        runtimeSeconds = c.lenientDouble(.runtimeSeconds)
        watched = (try c.decodeIfPresent(Bool.self, forKey: .watched)) ?? false
        progressSeconds = c.lenientDouble(.progressSeconds) ?? 0
        thumbPath = try c.decodeIfPresent(String.self, forKey: .thumbPath)
        thumbBlurHash = try c.decodeIfPresent(String.self, forKey: .thumbBlurHash)
    }

    /// The still's blurred preview while it loads (#114).
    public var thumbPreview: BlurPreview? {
        thumbBlurHash.map { BlurPreview(hash: $0, aspect: BlurPreview.still) }
    }

    /// Started and not finished.
    public var isInProgress: Bool { !watched && progressSeconds > 0 }

    /// "E3 · The Grim Barbarity of Optics and Design"
    public var label: String {
        number.map { "E\($0) · \(title)" } ?? title
    }

    /// "S2 E4"
    public var code: String? {
        guard let seasonNumber, let number else { return nil }
        return "S\(seasonNumber) E\(number)"
    }

    /// The card the player takes: from where this user stopped, or the start when finished or new.
    public func card(series: String?) -> MediaCard {
        MediaCard(id: id, itemType: "episode", title: title, seriesTitle: series, runtimeSeconds: runtimeSeconds,
                  seasonNumber: seasonNumber, episodeNumber: number, posterPath: thumbPath,
                  progressSeconds: isInProgress ? progressSeconds : nil)
    }
}

public struct Season: Decodable, Equatable, Identifiable, Sendable {
    /// nil for episodes nectar couldn't number.
    public let number: Int?
    public let episodes: [Episode]

    public var id: Int { number ?? -1 }

    public var title: String {
        number.map { $0 == 0 ? "Specials" : "Season \($0)" } ?? "Other episodes"
    }

    enum CodingKeys: String, CodingKey {
        case number = "season_number"
        case episodes
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        number = c.lenientInt(.number)
        episodes = try c.decode([Episode].self, forKey: .episodes)
    }

    /// What to watch next, and where to start it.
    public struct NextUp: Equatable, Sendable {
        public let episode: Episode
        /// Seconds in, when it's resumed rather than started.
        public let resume: Double?
    }

    /// The furthest-along episode this user touched: resumed if unfinished, else the one after it.
    /// Nothing touched starts at the first; everything watched has nothing next. Specials (season 0,
    /// which nectar sorts first) are never next-up: they're picked from the season list.
    public static func nextUp(in seasons: [Season]) -> NextUp? {
        let all = seasons.filter { $0.number != 0 }.flatMap(\.episodes)
        guard let last = all.lastIndex(where: { $0.watched || $0.progressSeconds > 0 }) else {
            return all.first.map { NextUp(episode: $0, resume: nil) }
        }
        if all[last].isInProgress {
            return NextUp(episode: all[last], resume: all[last].progressSeconds)
        }
        let after = all.index(after: last)
        return all.indices.contains(after) ? NextUp(episode: all[after], resume: nil) : nil
    }
}

extension Season {
    /// What plays from `episode` on: it, then every later episode in order. Specials only when the
    /// queue starts in them, because nectar sorts them first and a season's last episode mustn't lead into one.
    public static func queue(from episode: Episode, in seasons: [Season]) -> [Episode] {
        let inSpecials = episode.seasonNumber == 0
        let all = seasons.filter { inSpecials || $0.number != 0 }.flatMap(\.episodes)
        guard let start = all.firstIndex(where: { $0.id == episode.id }) else { return [episode] }
        return Array(all[start...])
    }
}

private struct Children: Decodable {
    let seasons: [Season]
}

extension NectarSession {
    /// A series' episodes by season, in order.
    public func children(of series: String) async throws -> [Season] {
        try JSONDecoder().decode(Children.self, from: try await get("api/v1/media/\(series)/children")).seasons
    }
}
