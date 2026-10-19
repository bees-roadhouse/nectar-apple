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
    /// This user's open requests, by ``DiscoverItem/id``; updated as they ask.
    private(set) var wants: [String: WantState] = [:]
    /// The title being asked for right now.
    private(set) var asking: String?
    /// The title whose playlist picker is open.
    var adding: DiscoverItem?
    /// Where each title was added this session, by ``DiscoverItem/id``: the playlist's name.
    private(set) var addedTo: [String: String] = [:]
    /// Why the last add didn't happen, for the picker to say.
    private(set) var addFailure: String?

    init(session: NectarSession) {
        self.session = session
    }

    func loadTrending() async {
        guard case .loading = trending else { return }
        wants = (try? await session.myRequestStates()) ?? [:]
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

    /// Where a title stands for this user: owned, wanted (downloading), or awaiting approval.
    func state(of item: DiscoverItem) -> DiscoverState? {
        if item.inLibrary { return .inLibrary }
        switch wants[item.id] {
        case .wanted: return .wanted
        case .awaitingApproval: return .requested
        case .alreadyRequested: return .alreadyRequested
        case nil: return item.alreadyRequested ? .alreadyRequested : nil
        }
    }

    /// "Want it": a household member's title starts downloading; a guest's waits for an admin.
    func want(_ item: DiscoverItem) async {
        asking = item.id
        defer { asking = nil }
        if let state = try? await session.want(item) {
            wants[item.id] = state
        }
    }

    /// The playlists a title can go in. Every playlist holds video today; when nectar gives playlists
    /// a media type (#39), this keeps the ones matching the title's.
    func playlists() async -> [Playlist]? {
        try? await session.playlists()
    }

    /// Adds the title (owned or not: nectar decides) and closes the picker; on failure the picker stays and says why.
    func add(_ item: DiscoverItem, to playlist: Playlist) async {
        addFailure = nil
        do {
            try await session.add(item, toPlaylist: playlist.id)
            addedTo[item.id] = playlist.name
            adding = nil
        } catch NectarSessionError.unexpectedStatus(400) {
            addFailure = "That playlist can't hold this title."
        } catch {
            addFailure = "Couldn't add it. Try again in a moment."
        }
    }

    /// A new playlist, then the title in it.
    func add(_ item: DiscoverItem, toNewPlaylistNamed name: String) async {
        addFailure = nil
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        do {
            let playlist = try await session.createPlaylist(named: name)
            await add(item, to: playlist)
        } catch {
            addFailure = "Couldn't make that playlist."
        }
    }

    private static func message(for error: Error) -> String {
        if case NectarSessionError.unexpectedStatus(400) = error {
            return "Discover isn't set up on this nectar yet."
        }
        return "Couldn't reach Discover."
    }
}
