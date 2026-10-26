import NectarKit
import SwiftUI

/// Collections are browsing shelves, not an ordered play queue (#177).
struct CollectionScreen: View {
    let collection: Playlist
    let session: NectarSession
    let open: (MediaCard) -> Void

    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var detail: PlaylistsModel.Load<PlaylistDetail> = .loading

    var body: some View {
        GeometryReader { proxy in
            let margin: CGFloat = proxy.size.width >= 428 ? 20 : 16
            let inner = max(1, proxy.size.width - margin * 2)
            // Library's 120pt sizing and 12pt gaps; AX gives the words the full column.
            let count = typeSize.isAccessibilitySize ? 1 : max(3, Int((inner + 12) / 132))
            let cell = max(1, (inner - CGFloat(count - 1) * 12) / CGFloat(count))
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    switch detail {
                    case .loading:
                        header(collection)
                        grid(columns: count) {
                            ForEach(0..<6) { _ in
                                VStack(alignment: .leading, spacing: 6) {
                                    RoundedRectangle(cornerRadius: 8).fill(Color.brhCard)
                                        .frame(width: cell, height: artworkHeight(cell))
                                    Text("Collection title").font(.subheadline.weight(.medium))
                                    Text("2026").font(.footnote).foregroundStyle(.secondary)
                                }
                                .frame(width: cell, alignment: .leading)
                                .redacted(reason: .placeholder).accessibilityHidden(true)
                            }
                        }
                    case let .loaded(detail):
                        header(detail.playlist)
                        if detail.members.isEmpty {
                            ContentUnavailableView("No titles yet", systemImage: "square.stack")
                                .frame(maxWidth: .infinity)
                        } else {
                            grid(columns: count) {
                                ForEach(detail.members) { member in
                                    if member.entry == .owned, let id = member.mediaItemID {
                                        Button {
                                            open(MediaCard(id: id, itemType: member.itemType, title: member.title, year: member.year, posterPath: member.posterPath))
                                        } label: { tile(member, width: cell) }
                                        .buttonStyle(Pressed())
                                    } else {
                                        tile(member, width: cell)
                                    }
                                }
                            }
                        }
                    case .failed:
                        ContentUnavailableView {
                            Label("Couldn't load this collection", systemImage: "wifi.exclamationmark")
                        } actions: {
                            Button("Retry") { Task { await load() } }.foregroundStyle(Color.brhGold)
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
                .padding(.horizontal, margin)
                .padding(.vertical, 16)
                .padding(.bottom, 32)
            }
            .refreshable { await load() }
        }
        .background(Color.brhNight)
        .task { await load() }
    }

    private func header(_ collection: Playlist) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(collection.name).font(.title2.bold())
                .fixedSize(horizontal: false, vertical: true)
            Text(collectionCountLine(collection)).font(.subheadline).foregroundStyle(.secondary)
            if let description = collection.description, !description.isEmpty {
                Text(description).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func grid<Content: View>(columns: Int, @ViewBuilder content: () -> Content) -> some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12, alignment: .top), count: columns), alignment: .leading, spacing: 18, content: content)
    }

    private func artworkHeight(_ width: CGFloat) -> CGFloat {
        collection.mediaType == "audio" ? width : width * 1.5
    }

    private func tile(_ member: PlaylistMember, width: CGFloat) -> some View {
        let url = member.posterPath.flatMap { path in
            path.hasPrefix("http") ? URL(string: path) : session.resolve(path, pixelWidth: Double(width * 3))
        }
        return VStack(alignment: .leading, spacing: 6) {
            CachedImage(url: url, maxPixelSize: Int(width * 3)) { image in
                image.resizable().scaledToFill()
            } placeholder: {
                ZStack {
                    Color.brhCard
                    Image(systemName: "square.stack").font(.system(size: 24)).foregroundStyle(.secondary)
                }
            }
            .frame(width: width, height: artworkHeight(width))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .accessibilityHidden(true)
            Text(member.title).font(.subheadline.weight(.medium)).foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
            if let year = member.year {
                Text(String(year)).font(.footnote).foregroundStyle(.secondary)
            }
            if member.entry == .wanted {
                Text(wantedLabel(member)).font(.footnote).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(width: width, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private func wantedLabel(_ member: PlaylistMember) -> String {
        switch member.requestStatus {
        case "pending": "Requested"
        case "approved": "Wanted"
        case "denied": "Request declined"
        default: "Not here yet"
        }
    }

    private func load() async {
        do { detail = .loaded(try await session.playlist(collection.id)) }
        catch { detail = .failed }
    }
}
