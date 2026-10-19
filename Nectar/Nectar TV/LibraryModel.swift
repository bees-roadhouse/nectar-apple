import Foundation
import NectarKit

/// One library's grid: the query the viewer has set, the pages loaded so far, and what's playing.
@MainActor
@Observable
final class LibraryModel {

    enum State {
        case loading
        case loaded
        case failed
    }

    let library: Library
    let session: NectarSession
    private(set) var state: State = .loading
    private(set) var items: [MediaCard] = []
    private(set) var total = 0
    private(set) var filters = LibraryFilters(genres: [], resolutions: [])
    private(set) var query: LibraryQuery
    /// The title on screen, if one is playing.
    var playing: PlayerModel?
    private var loadingMore = false

    init(library: Library, session: NectarSession) {
        self.library = library
        self.session = session
        query = LibraryQuery(library)
    }

    /// The first page, and the filter choices once.
    func start() async {
        guard items.isEmpty, case .loading = state else { return }
        async let facets = try? session.filters(library: library.id)
        await reload()
        if let facets = await facets { filters = facets }
    }

    /// Sort, order or a filter changed: back to the first page.
    func change(_ edit: (inout LibraryQuery) -> Void) async {
        var next = query
        edit(&next)
        next.offset = 0
        guard next != query else { return }
        query = next
        await reload()
    }

    /// The next page, when the end of the grid comes into view.
    func loadMore(after card: MediaCard) async {
        guard !loadingMore, items.count < total, items.suffix(12).contains(where: { $0.id == card.id }) else { return }
        loadingMore = true
        defer { loadingMore = false }
        var next = query
        next.offset = items.count
        guard let page = try? await session.media(next), next.library == query.library, next.sort == query.sort else { return }
        items += page.items.filter { new in !items.contains { $0.id == new.id } }
        total = page.total
        prefetch(page.items)
    }

    /// Movies play from where this user stopped; a list row doesn't say, so ask first.
    func play(_ card: MediaCard) async {
        guard card.itemType == "movie" else { return }
        let resume = try? await session.resumePoint(of: card.id)
        playing = PlayerModel(card: card.resuming(at: resume), session: session)
    }

    private func reload() async {
        state = .loading
        do {
            let page = try await session.media(query)
            items = page.items
            total = page.total
            state = .loaded
            prefetch(page.items)
        } catch {
            state = .failed
        }
    }

    private func prefetch(_ cards: [MediaCard]) {
        let width = LibraryPoster.Shape(library.kind).size.width * 2
        ImageCache.shared.prefetch(cards.map { session.resolve($0.posterPath, pixelWidth: width) })
    }
}

extension MediaCard {
    /// The same card, starting at `seconds` (or the start).
    func resuming(at seconds: Double?) -> MediaCard {
        MediaCard(id: id, itemType: itemType, title: title, seriesTitle: seriesTitle, year: year, runtimeSeconds: runtimeSeconds,
                  seasonNumber: seasonNumber, episodeNumber: episodeNumber, posterPath: posterPath, backdropPath: backdropPath,
                  progressSeconds: seconds)
    }
}

extension Library.Kind {
    /// The tab's icon.
    var symbol: String {
        switch self {
        case .movies: "film"
        case .shows: "tv"
        case .music: "music.note"
        case .books: "book"
        case .photos: "photo.on.rectangle"
        case .other: "square.grid.2x2"
        }
    }
}

extension Library.Kind {
    var isVideo: Bool {
        switch self {
        case .movies, .shows, .other: true
        case .music, .books, .photos: false
        }
    }

    /// "854 movies", "2,234 albums", "1 show".
    func count(_ n: Int) -> String {
        let (one, many) = switch self {
        case .movies: ("movie", "movies")
        case .shows: ("show", "shows")
        case .music: ("album", "albums")
        case .books: ("book", "books")
        case .photos: ("photo", "photos")
        case .other: ("title", "titles")
        }
        return "\(n.formatted()) \(n == 1 ? one : many)"
    }
}
