import Foundation
import NectarKit

/// Discover: what's trending, or what a search finds, owned or not.
@MainActor
@Observable
final class DiscoverModel {

    enum Rows {
        case loading
        case loaded(movies: [DiscoverItem], shows: [DiscoverItem])
        case failed(String)
    }

    enum Results {
        case idle
        case searching
        case found([DiscoverItem])
        case failed(String)
    }

    let session: NectarSession
    private(set) var trending: Rows = .loading
    private(set) var results: Results = .idle
    var query = ""
    /// The title whose detail sheet is open.
    var selected: DiscoverItem?

    init(session: NectarSession) {
        self.session = session
    }

    func loadTrending() async {
        guard case .loading = trending else { return }
        do {
            async let movies = session.discoverTrending(.movie)
            async let shows = session.discoverTrending(.tv)
            trending = .loaded(movies: try await movies, shows: try await shows)
        } catch {
            trending = .failed(Self.message(for: error))
        }
    }

    /// Runs when the query changes; the caller debounces by cancelling the previous task.
    func search() async {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else {
            results = .idle
            return
        }
        results = .searching
        try? await Task.sleep(for: .milliseconds(350))
        guard !Task.isCancelled else { return }
        do {
            let found = try await session.discoverSearch(q)
            guard !Task.isCancelled else { return }
            results = .found(found)
        } catch {
            guard !Task.isCancelled else { return }
            results = .failed(Self.message(for: error))
        }
    }

    private static func message(for error: Error) -> String {
        if case NectarSessionError.unexpectedStatus(400) = error {
            return "Discover isn't set up on this nectar yet."
        }
        return "Couldn't reach Discover."
    }
}
