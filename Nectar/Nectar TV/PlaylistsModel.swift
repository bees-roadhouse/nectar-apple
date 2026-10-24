import Foundation
import NectarKit

/// The user's playlists, and the one open.
@MainActor
@Observable
final class PlaylistsModel {

    enum Load<Value> {
        case loading
        case loaded(Value)
        case failed
    }

    let session: NectarSession
    private(set) var playlists: Load<[Playlist]> = .loading
    /// The playlist whose page is open.
    var open: Playlist?

    init(session: NectarSession) {
        self.session = session
    }

    func load(kind: String = "playlist") async {
        do {
            playlists = .loaded(try await session.collections(kind: kind))
        } catch {
            playlists = .failed
        }
    }

    func detail(_ playlist: Playlist) async -> Load<PlaylistDetail> {
        do {
            return .loaded(try await session.playlist(playlist.id))
        } catch {
            return .failed
        }
    }
}
