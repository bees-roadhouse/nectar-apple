import NectarKit
import SwiftUI

/// The Playlists tab: the user's playlists; one opens full screen.
struct PlaylistsView: View {

    @Bindable
    var model: PlaylistsModel

    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 40) {
                switch model.playlists {
                case .loading:
                    ProgressView().frame(maxWidth: .infinity)
                case let .loaded(lists) where lists.isEmpty:
                    Text("No playlists yet.").foregroundStyle(.secondary)
                case let .loaded(lists):
                    LazyVGrid(columns: Array(repeating: GridItem(.fixed(400), spacing: 48), count: 4), alignment: .leading, spacing: 48) {
                        ForEach(lists) { list in
                            Button { model.open = list } label: {
                                VStack(alignment: .leading, spacing: 8) {
                                    Image(systemName: "music.note.list").font(.largeTitle)
                                    Text(list.name).font(.headline).lineLimit(2)
                                    Text(list.itemCount == 1 ? "1 title" : "\(list.itemCount) titles")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                .frame(width: 360, height: 200, alignment: .bottomLeading)
                                .padding(20)
                            }
                            .buttonStyle(.card)
                        }
                    }
                case .failed:
                    Text("Couldn't load your playlists.").foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 40)
        }
        .task { await model.load() }
        .fullScreenCover(item: $model.open) { list in
            PlaylistPage(playlist: list, model: model)
        }
    }
}

/// One playlist: its members in order, and Play.
private struct PlaylistPage: View {

    let playlist: Playlist
    let model: PlaylistsModel

    @State
    private var detail: PlaylistsModel.Load<PlaylistDetail> = .loading
    @State
    private var playing: PlayQueue?

    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 32) {
                Text(playlist.name).font(.largeTitle.bold())
                if let description = playlist.description, !description.isEmpty {
                    Text(description).foregroundStyle(.secondary)
                }
                switch detail {
                case .loading:
                    ProgressView()
                case let .loaded(detail):
                    Button("Play", systemImage: "play.fill") {
                        playing = PlayQueue(cards: detail.playQueue)
                    }
                    .disabled(detail.playQueue.isEmpty)
                    ScrollView(.horizontal) {
                        LazyHStack(alignment: .top, spacing: 40) {
                            ForEach(detail.members) { member in
                                MemberCard(member: member, artwork: artwork(member))
                            }
                        }
                        .padding(.vertical, 20)
                    }
                    .scrollClipDisabled()
                case .failed:
                    Text("Couldn't load this playlist.").foregroundStyle(.secondary)
                }
            }
            .padding(80)
        }
        // A full-screen cover is transparent on tvOS; without this the playlist grid shows through.
        .background(Color.black.ignoresSafeArea())
        .task { detail = await model.detail(playlist) }
        .fullScreenCover(item: $playing) { queue in
            QueuePlayer(queue: queue, session: model.session) { playing = nil }
        }
    }

    /// Owned posters are nectar paths, sized like the home cards; wanted ones are TMDB URLs as they come.
    private func artwork(_ member: PlaylistMember) -> URL? {
        guard let path = member.posterPath else { return nil }
        if path.hasPrefix("http") { return URL(string: path) }
        return model.session.resolve(path, pixelWidth: 480)
    }
}

private struct MemberCard: View {

    let member: PlaylistMember
    let artwork: URL?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button {} label: {
                CachedImage(url: artwork, maxPixelSize: 720) { image in
                    image.resizable().aspectRatio(contentMode: .fill)
                } placeholder: {
                    ZStack {
                        Rectangle().fill(.quaternary)
                        Text(member.title).font(.caption).multilineTextAlignment(.center).padding()
                    }
                }
                .frame(width: 240, height: 360)
                .clipped()
                .opacity(member.entry == .wanted ? 0.45 : 1)
                .overlay(alignment: .topTrailing) {
                    if member.entry == .wanted {
                        Text(wantedLabel)
                            .font(.caption2.bold())
                            .padding(.horizontal, 10).padding(.vertical, 4)
                            .background(.ultraThinMaterial, in: Capsule())
                            .padding(10)
                    }
                }
            }
            .buttonStyle(.card)
            Text(member.title).font(.caption).lineLimit(2, reservesSpace: true).frame(width: 240, alignment: .leading)
        }
    }

    private var wantedLabel: String {
        switch member.requestStatus {
        case "approved": "Wanted"
        case "pending": "Requested"
        default: "Not here yet"
        }
    }
}
