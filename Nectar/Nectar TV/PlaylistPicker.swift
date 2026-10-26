import NectarKit
import SwiftUI

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
