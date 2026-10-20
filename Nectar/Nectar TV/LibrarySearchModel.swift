import Foundation
import NectarKit

/// One library's search (#96): nectar scopes it to the library, and the results come back in its order.
@MainActor
@Observable
final class LibrarySearchModel {

    enum Results {
        case idle
        case searching
        /// Titles in the library's sections, and the lines said in its titles (video libraries only).
        case found([LibrarySearch.Section], [SearchHit])
        case failed
    }

    let library: Library
    let session: NectarSession
    let playlistAdding: PlaylistAdding
    var query = ""
    private(set) var results: Results = .idle
    /// Skeleton cards, once a search has gone this long without an answer: a quick one never flashes them.
    private(set) var showsSkeleton = false
    /// Frames for dialogue hits carry the token, so they're made once the hits are in.
    private(set) var thumbnails: [String: URL] = [:]
    /// What was searched here lately, shown before typing.
    private(set) var recent: [String]
    var opened: MediaCard?
    var playing: PlayerModel?

    private static let skeletonAfter: Duration = .milliseconds(150)
    private let recents: RecentSearches

    init(library: Library, session: NectarSession, playlistAdding: PlaylistAdding) {
        self.library = library
        self.session = session
        self.playlistAdding = playlistAdding
        recents = RecentSearches(library: library.id)
        recent = recents.list
    }

    /// Typing settles for a moment before nectar is asked; a newer query cancels this one.
    func search() async {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            results = .idle
            return
        }
        try? await Task.sleep(for: .milliseconds(400))
        guard !Task.isCancelled else { return }
        results = .searching
        let skeleton = Task {
            try? await Task.sleep(for: Self.skeletonAfter)
            if !Task.isCancelled, case .searching = results { showsSkeleton = true }
        }
        defer {
            skeleton.cancel()
            showsSkeleton = false
        }
        do {
            async let titles = session.searchTitles(query, library: library.id)
            // A line said in a title; a library of albums has none, and a failure here costs only this row.
            let lines = library.kind.isVideo ? ((try? await session.searchMoments(query, in: .dialogue, library: library.id)) ?? []) : []
            let sections = LibrarySearch.sections(library.kind, try await titles)
            var frames: [String: URL] = [:]
            for hit in lines {
                if let thumb = hit.thumbPath { frames[hit.id] = try? await session.mediaURL(thumb) }
            }
            guard !Task.isCancelled else { return }
            thumbnails = frames
            results = .found(sections, lines)
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled else { return }
            results = .failed
        }
    }

    /// Keeps the query among this library's recent searches.
    func remember() {
        recents.record(query)
        recent = recents.list
    }

    /// Films, series and episodes open their detail; albums and songs wait for music's own slice, as in the grid.
    func open(_ hit: TitleHit) {
        remember()
        guard ["movie", "series", "episode"].contains(hit.itemType) else { return }
        opened = MediaCard(id: hit.id, itemType: hit.itemType, title: hit.title, year: hit.year, posterPath: hit.posterPath)
    }

    /// A line plays from the moment it's said.
    func play(_ hit: SearchHit) {
        remember()
        guard hit.seconds != nil, ["movie", "episode"].contains(hit.itemType) else { return }
        playing = PlayerModel(card: hit.card, session: session)
    }
}
