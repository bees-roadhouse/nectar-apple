import NectarKit
import SwiftUI

/// Add to playlist, from Discover or a title's detail: what's being added, where it went, and why it didn't.
@MainActor
@Observable
final class PlaylistAdding {

    /// What goes in: a Discover result (nectar decides owned or wanted from its TMDB ref) or a library title.
    enum Target: Identifiable {
        case discover(DiscoverItem)
        case owned(id: String, title: String)

        var id: String {
            switch self {
            case let .discover(item): "discover-\(item.id)"
            case let .owned(id, _): "owned-\(id)"
            }
        }

        var title: String {
            switch self {
            case let .discover(item): item.title
            case let .owned(_, title): title
            }
        }

        /// Films and series are video; music arrives with #39.
        var mediaType: String { "video" }
    }

    let session: NectarSession
    /// The title whose picker is open.
    var target: Target?
    /// Where each target went this session: the playlist's name.
    private(set) var addedTo: [String: String] = [:]
    /// Why the last add didn't happen, for the picker to say.
    private(set) var failure: String?

    init(session: NectarSession) {
        self.session = session
    }

    /// The playlists this target can go in: those holding its media type (nectar #444).
    func playlists(for target: Target) async -> [Playlist]? {
        try? await session.playlists().filter { $0.holds(target.mediaType) }
    }

    /// Adds it and closes the picker; on failure the picker stays and says why.
    func add(_ target: Target, to playlist: Playlist) async {
        failure = nil
        do {
            switch target {
            case let .discover(item): try await session.add(item, toPlaylist: playlist.id)
            case let .owned(id, _): try await session.add(mediaItemID: id, toPlaylist: playlist.id)
            }
            addedTo[target.id] = playlist.name
            self.target = nil
        } catch NectarSessionError.unexpectedStatus(400) {
            failure = "That playlist can't hold this title."
        } catch {
            failure = "Couldn't add it. Try again in a moment."
        }
    }

    /// A new playlist of the target's media type, then the target in it.
    func add(_ target: Target, toNewPlaylistNamed name: String) async {
        failure = nil
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        do {
            let playlist = try await session.createPlaylist(named: name, mediaType: target.mediaType)
            await add(target, to: playlist)
        } catch {
            failure = "Couldn't make that playlist."
        }
    }
}
