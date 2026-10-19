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
