import Foundation

/// The library's films and series, kept on the TV so Siri (#77) finds a title by name without a network call:
/// the intents resolve against this, and only the app's own session ever talks to nectar (tokens rotate).
public struct TitleCatalog: Codable, Equatable, Sendable {

    public struct Title: Codable, Equatable, Hashable, Identifiable, Sendable {
        public let id: String
        public let title: String
        public let year: Int?
        /// `movie` or `series`, as nectar names them.
        public let itemType: String

        public init(id: String, title: String, year: Int?, itemType: String) {
            self.id = id
            self.title = title
            self.year = year
            self.itemType = itemType
        }
    }

    public let titles: [Title]
    public let fetchedAt: Date

    /// nectar's ceiling for `GET /api/v1/media`.
    static let pageSize = 200

    public init(titles: [Title], fetchedAt: Date) {
        self.titles = titles
        self.fetchedAt = fetchedAt
    }

    /// Over a day old: worth fetching again after the next Home load.
    public func isStale(now: Date = .now) -> Bool {
        now.timeIntervalSince(fetchedAt) > 86_400
    }

    /// The titles Siri heard, best first: the whole title, then one that starts with it, then one holding every
    /// word of it, then one containing it. Ties go to the shorter title, then the newer one.
    public func matching(_ spoken: String, limit: Int = 10) -> [Title] {
        let heard = Self.normalized(spoken)
        guard !heard.isEmpty else { return [] }
        let heardWords = Set(heard.split(separator: " "))
        let ranked = titles.compactMap { title -> (rank: Int, length: Int, year: Int, title: Title)? in
            let name = Self.normalized(title.title)
            let rank: Int
            if name == heard {
                rank = 0
            } else if name.hasPrefix(heard + " ") {
                rank = 1
            } else if heardWords.isSubset(of: Set(name.split(separator: " "))) {
                rank = 2
            } else if name.contains(heard) {
                rank = 3
            } else {
                return nil
            }
            return (rank, name.count, title.year ?? 0, title)
        }
        return ranked
            .sorted { a, b in
                if a.rank != b.rank { return a.rank < b.rank }
                if a.length != b.length { return a.length < b.length }
                if a.year != b.year { return a.year > b.year }
                return a.title.id < b.title.id
            }
            .prefix(limit)
            .map(\.title)
    }

    /// How a title sounds when spoken: lowercase, no accents, apostrophes dropped ("handmaid's" → "handmaids"),
    /// other punctuation as spaces, "&" as "and", and a leading "the" gone.
    static func normalized(_ text: String) -> String {
        let folded = text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX")).lowercased()
        let joined = folded
            .replacingOccurrences(of: "&", with: " and ")
            .replacingOccurrences(of: "'", with: "")
            .replacingOccurrences(of: "\u{2019}", with: "")
        let words = String(joined.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? Character($0) : " " })
            .split(separator: " ")
            .map(String.init)
        let kept = words.count > 1 && words.first == "the" ? Array(words.dropFirst()) : words
        return kept.joined(separator: " ")
    }
}

extension NectarSession {

    /// Every film and series, a page at a time.
    public func titleCatalog(now: Date = .now) async throws -> TitleCatalog {
        var titles: [TitleCatalog.Title] = []
        for type in ["movie", "series"] {
            var query = LibraryQuery(library: nil, itemType: type)
            query.limit = TitleCatalog.pageSize
            // A ceiling on pages, so a server that never says it's done can't keep the TV fetching.
            for _ in 0 ..< 100 {
                let page = try await media(query)
                titles += page.items.compactMap { card in
                    card.title.map { TitleCatalog.Title(id: card.id, title: $0, year: card.year, itemType: card.itemType ?? type) }
                }
                query.offset += page.items.count
                if page.items.isEmpty || query.offset >= page.total { break }
            }
        }
        return TitleCatalog(titles: titles, fetchedAt: now)
    }
}

/// The catalog as a file in Caches: tvOS may purge it, and the next Home load fetches it again.
public final class TitleCatalogStore: Sendable {

    private let file: URL

    public init(directory: URL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]) {
        file = directory.appendingPathComponent("nectar-title-catalog.json")
    }

    public var catalog: TitleCatalog? {
        guard let data = try? Data(contentsOf: file) else { return nil }
        return try? JSONDecoder().decode(TitleCatalog.self, from: data)
    }

    public func save(_ catalog: TitleCatalog) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(catalog).write(to: file, options: .atomic)
    }
}
