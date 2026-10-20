import Foundation

/// A library's own search (#96): its results in that library's order.
public enum LibrarySearch {

    /// One kind of result under one heading.
    public struct Section: Equatable, Sendable {

        /// How the section draws its cards.
        public enum Style: Equatable, Sendable {
            /// The library's own posters (or album squares).
            case posters
            /// Episode stills, landscape.
            case stills
            /// A plain list, as Music lists songs.
            case list
        }

        /// Nil when the library has one kind of result: the prompt already says what's being searched.
        public let title: String?
        public let style: Style
        public let hits: [TitleHit]
    }

    /// The sections a library's results show in, each only when it has hits, in nectar's order within:
    /// Shows then Episodes for TV, Albums then Songs for music (nectar's search has no artist entity),
    /// one grid otherwise. Seasons are left out: a show's own page reaches them.
    public static func sections(_ kind: Library.Kind, _ hits: [TitleHit]) -> [Section] {
        let layout: [(title: String?, itemType: String?, style: Section.Style)] = switch kind {
        case .shows: [("Shows", "series", .posters), ("Episodes", "episode", .stills)]
        case .music: [("Albums", "album", .posters), ("Songs", "track", .list)]
        case .movies: [(nil, "movie", .posters)]
        case .books: [(nil, "book", .posters)]
        case .photos: [(nil, "photo", .stills)]
        case .other: [(nil, nil, .posters)]
        }
        return layout.compactMap { slot in
            let found = hits.filter { slot.itemType == nil || $0.itemType == slot.itemType }
            return found.isEmpty ? nil : Section(title: slot.title, style: slot.style, hits: found)
        }
    }
}

/// What was searched in one library lately, newest first, kept on this device (#96).
public struct RecentSearches {

    /// Enough to come back to; more would push the keyboard's row off the screen.
    static let keep = 5

    private let key: String
    private let defaults: UserDefaults

    public init(library: String, defaults: UserDefaults = .standard) {
        key = "nectar.recentSearches.\(library)"
        self.defaults = defaults
    }

    public var list: [String] {
        defaults.stringArray(forKey: key) ?? []
    }

    /// Remembers a search; the same words again move to the top, in the casing typed last.
    public func record(_ query: String) {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return }
        let rest = list.filter { $0.caseInsensitiveCompare(query) != .orderedSame }
        defaults.set(Array(([query] + rest).prefix(Self.keep)), forKey: key)
    }
}
