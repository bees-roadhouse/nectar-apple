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

/// Which playlist a title goes in, or a new one.
struct PlaylistPicker: View {

    let target: PlaylistAdding.Target
    let model: PlaylistAdding

    @State
    private var playlists: [Playlist]?
    @State
    private var loadFailed = false
    @State
    private var newName = ""
    @State
    private var working = false

    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 32) {
                Text("Add \u{201C}\(target.title)\u{201D} to").font(.title2.bold())
                if let failure = model.failure {
                    Text(failure).foregroundStyle(.secondary)
                }
                if let playlists {
                    ForEach(playlists) { playlist in
                        Button {
                            add { await model.add(target, to: playlist) }
                        } label: {
                            HStack {
                                Image(systemName: "music.note.list")
                                Text(playlist.name)
                                Spacer()
                                Text(playlist.titleCount == 1 ? "1 title" : "\(playlist.titleCount) titles").foregroundStyle(.secondary)
                            }
                            .frame(width: 900)
                        }
                    }
                } else if loadFailed {
                    Text("Couldn't load your playlists.").foregroundStyle(.secondary)
                } else {
                    ProgressView()
                }
                HStack(spacing: 30) {
                    TextField("New playlist", text: $newName)
                        .frame(width: 600)
                        .onSubmit { addToNew() }
                    Button("Create and add") { addToNew() }
                        .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                if working { ProgressView() }
            }
            .padding(80)
            .disabled(working)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        // A full-screen cover is see-through and only as wide as its content; fill the screen.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.ignoresSafeArea())
        .task {
            if let lists = await model.playlists(for: target) {
                playlists = lists
            } else {
                loadFailed = true
            }
        }
    }

    private func addToNew() {
        let name = newName
        add { await model.add(target, toNewPlaylistNamed: name) }
    }

    private func add(_ action: @escaping @MainActor () async -> Void) {
        working = true
        Task {
            await action()
            working = false
        }
    }
}
