import NectarKit
import SwiftUI

/// Discover: trending movies and shows, and a search across everything TMDB knows.
struct DiscoverView: View {

    @Bindable
    var model: DiscoverModel

    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 56) {
                switch model.results {
                case .idle:
                    trending
                case .searching:
                    ProgressView()
                        .frame(maxWidth: .infinity, minHeight: PosterCard.size.height)
                case let .found(items) where items.isEmpty:
                    Text("Nothing found for “\(model.query)”.")
                        .foregroundStyle(.secondary)
                case let .found(items):
                    DiscoverRow(title: "Results", items: items, state: model.state(of:)) { model.selected = $0 }
                case let .failed(message):
                    Text(message).foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 40)
        }
        .searchable(text: $model.query, prompt: "Movies and shows")
        .task(id: model.query) { await model.search() }
        .task { await model.loadTrending() }
        .fullScreenCover(item: $model.selected) { item in
            DiscoverDetail(item: item, model: model)
        }
    }

    @ViewBuilder
    private var trending: some View {
        switch model.trending {
        case .loading:
            ProgressView()
                .frame(maxWidth: .infinity, minHeight: PosterCard.size.height)
        case let .loaded(movies, shows):
            DiscoverRow(title: "Trending movies", items: movies, state: model.state(of:)) { model.selected = $0 }
            DiscoverRow(title: "Trending shows", items: shows, state: model.state(of:)) { model.selected = $0 }
        case let .failed(message):
            Text(message).foregroundStyle(.secondary)
        }
    }
}

private struct DiscoverRow: View {

    let title: String
    let items: [DiscoverItem]
    let state: (DiscoverItem) -> DiscoverState?
    let select: (DiscoverItem) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(title).font(.title3.bold())
            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: 40) {
                    ForEach(items) { item in
                        PosterCard(item: item, state: state(item)) { select(item) }
                    }
                }
                .padding(.vertical, 20)
            }
            .scrollClipDisabled()
            .onAppear { ImageCache.shared.prefetch(items.map(\.posterURL)) }
        }
    }
}

private struct PosterCard: View {

    static let size = CGSize(width: 240, height: 360)

    let item: DiscoverItem
    let state: DiscoverState?
    let select: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button(action: select) {
                // TMDB's poster is already a fixed width; decode it at the card's height.
                CachedImage(url: item.posterURL, maxPixelSize: Int(Self.size.height * 2)) { image in
                    image.resizable().aspectRatio(contentMode: .fill)
                } placeholder: {
                    ZStack {
                        Rectangle().fill(.quaternary)
                        Text(item.title).font(.caption).multilineTextAlignment(.center).padding()
                    }
                }
                .frame(width: Self.size.width, height: Self.size.height)
                .clipped()
                .overlay(alignment: .topTrailing) {
                    if let state {
                        StateTag(state: state).padding(10)
                    }
                }
            }
            .buttonStyle(.card)

            Text(item.title)
                .font(.caption)
                .lineLimit(2, reservesSpace: true)
                .frame(width: Self.size.width, alignment: .leading)
        }
    }
}

/// Where a title stands for this user.
enum DiscoverState {
    case inLibrary
    /// Approved: nectar is downloading it.
    case wanted
    /// Pending: waiting for an admin.
    case requested
    /// Someone has an open request for it and we don't know where it stands.
    case alreadyRequested

    var label: String {
        switch self {
        case .inLibrary: "In library"
        case .wanted: "Wanted"
        case .requested, .alreadyRequested: "Requested"
        }
    }

    /// The longer line in the detail sheet.
    var detail: String {
        switch self {
        case .inLibrary: "In your library"
        case .wanted: "Wanted · downloading"
        case .requested: "Requested · awaiting approval"
        case .alreadyRequested: "Already requested"
        }
    }
}

private struct StateTag: View {

    let state: DiscoverState

    var body: some View {
        Text(state.label)
            .font(.caption2.bold())
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(.ultraThinMaterial, in: Capsule())
    }
}

/// A title's detail: what it is, where it stands, and "Want it" when it's neither owned nor asked for.
struct DiscoverDetail: View {

    let item: DiscoverItem
    let model: DiscoverModel

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            CachedImage(url: item.backdropURL, maxPixelSize: 3840) { image in
                image.resizable().aspectRatio(contentMode: .fill)
            } placeholder: {
                Rectangle().fill(.black)
            }
            .ignoresSafeArea()
            .overlay(LinearGradient(colors: [.clear, .black.opacity(0.85)], startPoint: .top, endPoint: .bottom).ignoresSafeArea())

            VStack(alignment: .leading, spacing: 20) {
                Text(item.title).font(.largeTitle.bold())
                Text(facts).foregroundStyle(.secondary)
                if let overview = item.overview, !overview.isEmpty {
                    Text(overview)
                        .frame(maxWidth: 1100, alignment: .leading)
                        .lineLimit(6)
                }
                if let state = model.state(of: item) {
                    Text(state.detail).font(.headline)
                }
                if let playlist = model.playlistAdding.addedTo[PlaylistAdding.Target.discover(item).id] {
                    Text("Added to \(playlist)").font(.headline)
                }
                HStack(spacing: 30) {
                    if model.state(of: item) == nil {
                        if model.asking == item.id {
                            ProgressView()
                        } else {
                            Button("Want it") {
                                Task { await model.want(item) }
                            }
                        }
                    }
                    Button("Add to playlist", systemImage: "text.badge.plus") {
                        model.playlistAdding.target = .discover(item)
                    }
                }
            }
            .padding(80)
        }
        .fullScreenCover(item: Bindable(model.playlistAdding).target) { target in
            PlaylistPicker(target: target, model: model.playlistAdding)
        }
    }

    private var facts: String {
        var parts = [item.kind == .movie ? "Movie" : "Series"]
        if let year = item.year { parts.append(String(year)) }
        if let rating = item.rating, rating > 0 { parts.append(String(format: "★ %.1f", rating)) }
        return parts.joined(separator: " · ")
    }
}
