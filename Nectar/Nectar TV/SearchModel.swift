import Foundation
import NectarKit

/// The Search tab: the query, the mode, and what it found.
@MainActor
@Observable
final class SearchModel {

    enum Results {
        case idle
        case searching
        case titles([TitleHit])
        case moments([SearchHit])
        /// nectar has this mode switched off.
        case disabled(SearchMode)
        case failed
    }

    let session: NectarSession
    let playlistAdding: PlaylistAdding
    var query = ""
    var mode: SearchMode = .titles
    private(set) var results: Results = .idle
    /// Frames for dialogue and scene hits carry the token, so they're made once the hits are in.
    private(set) var thumbnails: [String: URL] = [:]
    /// A title opened from the results.
    var opened: MediaCard?
    /// A moment playing.
    var playing: PlayerModel?
    /// What to browse before typing: the film and TV genres, the biggest music genres, and the server's collections.
    private(set) var genres: [String] = []
    private(set) var musicGenres: [String] = []
    private(set) var collections: [Playlist] = []
    var openedGenre: GenreRef?
    var openedCollection: Playlist?

    /// A genre, to open as a page.
    struct GenreRef: Identifiable, Hashable {
        let name: String
        var id: String { name }
    }

    /// Every genre stays reachable, but a music library brings hundreds; they get their own, shorter section.
    private static let musicGenreLimit = 30

    func loadBrowse() async {
        guard genres.isEmpty, musicGenres.isEmpty, collections.isEmpty else { return }
        async let collections = try? session.collections(kind: "collection")
        let libraries = (try? await session.libraries()) ?? []
        var video: [String] = [], music: [String] = []
        for library in libraries {
            // nectar sends each library's genres biggest first.
            let found = (try? await session.filters(library: library.id).genres) ?? []
            if library.kind == .music {
                music += found.filter { !music.contains($0) }
            } else {
                video += found.filter { !video.contains($0) }
            }
        }
        genres = video
        musicGenres = Array(music.filter { !video.contains($0) }.prefix(Self.musicGenreLimit))
        self.collections = await collections ?? []
    }

    init(session: NectarSession) {
        self.session = session
        playlistAdding = PlaylistAdding(session: session)
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
        do {
            if mode == .titles {
                results = .titles(try await session.searchTitles(query))
            } else {
                let hits = try await session.searchMoments(query, in: mode)
                var frames: [String: URL] = [:]
                for hit in hits {
                    if let thumb = hit.thumbPath { frames[hit.id] = try? await session.mediaURL(thumb) }
                }
                thumbnails = frames
                results = .moments(hits)
            }
        } catch SearchError.disabled {
            results = .disabled(mode)
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled else { return }
            results = .failed
        }
    }

    /// Films, series and episodes have a detail; music waits for its own slice.
    func open(_ hit: TitleHit) {
        guard ["movie", "series", "episode"].contains(hit.itemType) else { return }
        opened = MediaCard(id: hit.id, itemType: hit.itemType, title: hit.title)
    }

    /// A dialogue line or a scene plays from its moment; an audio hit waits for music playback.
    func play(_ hit: SearchHit) {
        guard hit.seconds != nil, ["movie", "episode"].contains(hit.itemType) else { return }
        playing = PlayerModel(card: hit.card, session: session)
    }
}
