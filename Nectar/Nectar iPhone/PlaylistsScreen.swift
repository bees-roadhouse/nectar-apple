import NectarKit
import SwiftUI

/// More's playlists, using the TV's model and the app's existing navigation stack (#174).
struct CollectionListScreen: View {
    enum Kind: String { case playlist, collection }
    var kind: Kind = .playlist
    @Environment(\.dynamicTypeSize) private var typeSize
    @Bindable var model: PlaylistsModel
    let open: (Playlist) -> Void

    var body: some View {
        List {
            switch model.playlists {
            case .loading:
                ForEach(0..<5) { _ in
                    playlistRow(Playlist(id: "placeholder", name: kind == .playlist ? "Playlist name" : "Collection name", description: nil, itemCount: 12))
                        .redacted(reason: .placeholder)
                        .accessibilityHidden(true)
                }
            case let .loaded(playlists) where playlists.isEmpty:
                ContentUnavailableView(kind == .playlist ? "No playlists yet" : "No collections yet", systemImage: kind == .playlist ? "music.note.list" : "square.stack", description: kind == .playlist ? Text("Add a title to a playlist from its page.") : nil)
            case let .loaded(playlists):
                ForEach(playlists) { playlist in
                    Button { open(playlist) } label: {
                        playlistRow(playlist)
                    }
                    .buttonStyle(.plain)
                }
            case .failed:
                ContentUnavailableView {
                    Label(kind == .playlist ? "Couldn't load your playlists" : "Couldn't load your collections", systemImage: "wifi.exclamationmark")
                } actions: {
                    Button("Retry") { Task { await model.load(kind: kind.rawValue) } }.foregroundStyle(Color.brhGold)
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Color.brhNight)
        .refreshable { await model.load(kind: kind.rawValue) }
        .task { await model.load(kind: kind.rawValue) }
    }

    private func playlistRow(_ playlist: Playlist) -> some View {
        rowLayout {
            Image(systemName: kind == .collection ? "square.stack" : playlist.mediaType == "audio" ? "music.note.list" : "play.rectangle.on.rectangle")
                .font(.system(size: 24)).foregroundStyle(Color.brhGold)
                .frame(width: 56, height: 56)
                .background(Color.brhCard, in: RoundedRectangle(cornerRadius: 6))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(playlist.name).font(.headline).foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(collectionCountLine(playlist))
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            if !typeSize.isAccessibilitySize {
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary).accessibilityHidden(true)
            }
        }
        .frame(minHeight: 44)
        .contentShape(Rectangle())
    }


    private var rowLayout: AnyLayout {
        typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 12)) : AnyLayout(HStackLayout(spacing: 12))
    }
}

func collectionCountLine(_ playlist: Playlist) -> String {
    let total = playlist.titleCount == 1 ? "1 title" : "\(playlist.titleCount) titles"
    return playlist.wantedCount > 0 ? "\(total) · \(playlist.wantedCount) not here yet" : total
}

/// Ordered members stay visible while playback lives in the app-wide player, including its dock and PiP.
struct PlaylistScreen: View {
    @Environment(\.dynamicTypeSize) private var typeSize
    let playlist: Playlist
    let model: PlaylistsModel
    let playback: Playback
    let open: (MediaCard) -> Void

    @State private var detail: PlaylistsModel.Load<PlaylistDetail> = .loading

    var body: some View {
        List {
            switch detail {
            case .loading:
                ForEach(0..<5) { _ in
                    memberLayout {
                        RoundedRectangle(cornerRadius: 6).fill(Color.brhCard)
                            .frame(width: playlist.mediaType == "audio" ? 56 : 48, height: playlist.mediaType == "audio" ? 56 : 72)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Playlist title").font(.headline)
                            Text("2026 · Movie").font(.subheadline).foregroundStyle(.secondary)
                        }
                    }
                    .frame(minHeight: 44, alignment: .leading)
                    .redacted(reason: .placeholder).accessibilityHidden(true)
                }
            case let .loaded(detail):
                VStack(alignment: .leading, spacing: 12) {
                    Text(detail.playlist.name).font(.title2.bold()).fixedSize(horizontal: false, vertical: true)
                    Text(collectionCountLine(detail.playlist)).font(.subheadline).foregroundStyle(.secondary)
                    if let description = detail.playlist.description, !description.isEmpty {
                        Text(description).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .listRowSeparator(.hidden)
                if !detail.playQueue.isEmpty {
                    Button {
                        playback.play(PlayQueue(cards: detail.playQueue))
                    } label: {
                        Label("Play", systemImage: "play.fill")
                            .font(.headline).frame(maxWidth: .infinity, minHeight: 48)
                            .foregroundStyle(Color.brhGoldInk)
                            .background(Color.brhGold, in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                }
                if !detail.playQueue.isEmpty, detail.playQueue.count < detail.members.count {
                    Text("Plays the \(detail.playQueue.count) films and episodes available now.")
                        .font(.subheadline).foregroundStyle(.secondary)
                        .listRowSeparator(.hidden)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if detail.playlist.mediaType == "audio", !detail.members.isEmpty {
                    Text("Audio playback is not available in this app yet.")
                        .font(.subheadline).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if detail.members.isEmpty {
                    ContentUnavailableView("No titles yet", systemImage: "music.note.list", description: Text("Add a title to this playlist from its title page."))
                } else {
                    Section("Titles") {
                        ForEach(detail.members) { member in
                            if member.entry == .owned, let id = member.mediaItemID {
                                Button {
                                    open(MediaCard(id: id, itemType: member.itemType, title: member.title, year: member.year, posterPath: member.posterPath))
                                } label: { memberRow(member, navigable: true) }
                                .buttonStyle(.plain)
                            } else {
                                memberRow(member, navigable: false)
                            }
                        }
                    }
                }
            case .failed:
                ContentUnavailableView {
                    Label("Couldn't load this playlist", systemImage: "wifi.exclamationmark")
                } actions: {
                    Button("Retry") { Task { await load() } }.foregroundStyle(Color.brhGold)
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Color.brhNight)
        .refreshable { await load() }
        .task { await load() }
    }

    private var memberLayout: AnyLayout {
        typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 12)) : AnyLayout(HStackLayout(alignment: .top, spacing: 12))
    }

    private func memberRow(_ member: PlaylistMember, navigable: Bool) -> some View {
        memberLayout {
            artwork(member).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(member.title).font(.headline).foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                Text([member.year.map(String.init), member.itemType.capitalized].compactMap { $0 }.joined(separator: " · "))
                    .font(.subheadline).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if member.entry == .wanted {
                    Text(wantedLabel(member)).font(.subheadline).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if !typeSize.isAccessibilitySize { Spacer(minLength: 0) }
            if navigable && !typeSize.isAccessibilitySize {
                Image(systemName: "chevron.right").font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary).accessibilityHidden(true)
            }
        }
        .accessibilityElement(children: .combine)
        .frame(minHeight: 44, alignment: .leading)
        .contentShape(Rectangle())
    }

    private func artwork(_ member: PlaylistMember) -> some View {
        let audio = playlist.mediaType == "audio"
        let url = member.posterPath.flatMap { path in
            path.hasPrefix("http") ? URL(string: path) : model.session.resolve(path, pixelWidth: 168)
        }
        return CachedImage(url: url, maxPixelSize: 216) { image in
            image.resizable().aspectRatio(contentMode: .fill)
        } placeholder: {
            ZStack {
                Color.brhCard
                Image(systemName: audio ? "music.note" : "film").font(.system(size: 24)).foregroundStyle(.secondary)
            }
        }
        .frame(width: audio ? 56 : 48, height: audio ? 56 : 72)
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private func wantedLabel(_ member: PlaylistMember) -> String {
        switch member.requestStatus {
        case "approved": "Wanted"
        case "pending": "Requested"
        case "denied": "Request declined"
        default: "Not here yet"
        }
    }

    private func load() async {
        detail = await model.detail(playlist)
    }
}
