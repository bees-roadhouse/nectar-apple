import Foundation
import Observation

/// One genre's titles, paged: a reload owns its generation so a late old page cannot replace a newer one, an append
/// failure keeps the rows and Retry asks for the same offset again.
@MainActor
@Observable
public final class GenreBrowser {
    public let session: NectarSession
    public let genre: String
    public private(set) var cards: [MediaCard] = []
    public private(set) var total = 0
    public private(set) var loading = false
    public private(set) var loaded = false
    public private(set) var failed = false
    public private(set) var more = true
    /// Whether the failed request was a first page, so Retry knows to reset.
    public private(set) var failedReset = false
    /// A pull to refresh in flight over titles already shown: the pulled spinner is its indicator, so no placeholders.
    public private(set) var refreshing = false
    private var offset = 0
    private var generation = 0
    private var seen: Set<String> = []

    public init(session: NectarSession, genre: String) {
        self.session = session
        self.genre = genre
    }

    /// Re-entering a retained genre keeps its pages; refresh and Retry call `load(reset:)` explicitly.
    public func start() async {
        guard !loaded, !loading, !failed else { return }
        await load(reset: true)
    }

    public func loadMore() async {
        guard more, !failed else { return }
        await load(reset: false)
    }

    public func load(reset: Bool) async {
        if reset {
            generation += 1
            loading = false
            offset = 0; more = true
        }
        guard !loading, more else { return }
        let request = generation
        loading = true; failed = false
        refreshing = reset && loaded
        defer { if request == generation { loading = false; refreshing = false } }
        var query = LibraryQuery(library: nil)
        query.genre = genre; query.sort = .rating; query.descending = true; query.offset = offset
        do {
            let page = try await session.media(query)
            guard request == generation, !Task.isCancelled else { return }
            if reset {
                cards = page.items
                seen = Set(page.items.map(\.id))
            } else {
                cards += page.items.filter { seen.insert($0.id).inserted }
            }
            offset += page.items.count; total = page.total; loaded = true
            more = !page.items.isEmpty && offset < page.total
        } catch {
            guard request == generation, !Task.isCancelled else { return }
            failed = true; failedReset = reset
        }
    }
}
