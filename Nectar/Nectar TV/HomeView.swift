import NectarKit
import SwiftUI

/// The signed-in home: continue watching, for you, recently added in each library, the top genres,
/// then who is signed in.
struct HomeView: View {

    let user: NectarUser
    @Bindable
    var model: HomeModel
    /// Discover's model, for a recommendation that isn't in the library yet.
    let discover: DiscoverModel
    let signOut: () -> Void

    /// Focus starts on the row, not on Sign out.
    @Namespace
    private var focusScope

    @Environment(\.resetFocus)
    private var resetFocus

    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 48) {
                ContinueWatchingRow(row: model.continueWatching, session: model.session, focusScope: focusScope, play: model.play)

                if !model.forYou.isEmpty {
                    PosterShelf(title: "For you", kind: .movies, session: model.session,
                                cards: model.forYou.map { MediaCard(id: $0.id, itemType: $0.kind, title: $0.title, year: $0.year, posterPath: $0.posterPath) }) { card in
                        if let recommendation = model.forYou.first(where: { $0.id == card.id }) { model.open(recommendation) }
                    }
                }

                ForEach(model.shelves) { shelf in
                    PosterShelf(title: shelf.title, kind: shelf.kind, session: model.session, cards: shelf.cards) { model.open($0) }
                }

                HStack(spacing: 24) {
                    Text("Signed in as \(user.username)")
                        .foregroundStyle(.secondary)
                    Button("Sign out", action: signOut)
                }
            }
            .padding(.vertical, 40)
            .focusScope(focusScope)
        }
        .fullScreenCover(item: $model.playing, onDismiss: model.finishedPlaying) { player in
            PlayerView(model: player) { model.playing = nil }
        }
        .fullScreenCover(item: $model.opened, onDismiss: { Task { await model.load() } }) { card in
            ItemDetailView(id: card.id, session: model.session, playlistAdding: model.playlistAdding)
        }
        .fullScreenCover(item: $model.discovering) { item in
            DiscoverDetail(item: item, model: discover)
        }
        .task {
            await model.load()
            // The row arrives after the first layout, when focus has already settled on Sign out.
            resetFocus(in: focusScope)
        }
    }
}

private struct ContinueWatchingRow: View {

    let row: HomeModel.Row
    let session: NectarSession
    let focusScope: Namespace.ID
    let play: (MediaCard) -> Void

    /// 2 on an Apple TV 4K, so a 480 pt card asks nectar for 960 px artwork (#26).
    @Environment(\.displayScale)
    private var displayScale

    private func artwork(_ card: MediaCard) -> URL? {
        session.resolve(card.artworkPath, pixelWidth: CardView.size.width * displayScale)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Continue watching")
                .font(.title3.bold())

            switch row {
            case .loading:
                ProgressView()
                    .frame(height: CardView.size.height)
            case let .loaded(cards) where cards.isEmpty:
                Text("Nothing in progress")
                    .foregroundStyle(.secondary)
            case let .loaded(cards):
                ScrollView(.horizontal) {
                    LazyHStack(spacing: 40) {
                        ForEach(cards) { card in
                            CardView(
                                card: card,
                                artwork: artwork(card),
                                maxPixelSize: Int(CardView.size.width * displayScale),
                                isDefaultFocus: card.id == cards.first?.id,
                                focusScope: focusScope
                            ) { play(card) }
                        }
                    }
                    .padding(.vertical, 20)
                }
                .scrollClipDisabled()
                .onAppear { ImageCache.shared.prefetch(cards.map(artwork)) }
            case .failed:
                Text("Couldn't load what you were watching.")
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct CardView: View {

    static let size = CGSize(width: 480, height: 270)

    let card: MediaCard
    let artwork: URL?
    let maxPixelSize: Int
    let isDefaultFocus: Bool
    let focusScope: Namespace.ID
    let select: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // The card style lifts the artwork alone; the caption stays put.
            Button(action: select) { artworkView }
                .buttonStyle(.card)
                .prefersDefaultFocus(isDefaultFocus, in: focusScope)

            Text(caption)
                .font(.callout)
                .lineLimit(2, reservesSpace: true)
                .frame(width: Self.size.width, alignment: .leading)
                .padding(.top, 16)
        }
    }

    private var artworkView: some View {
        CachedImage(url: artwork, maxPixelSize: maxPixelSize) { image in
            image.resizable().aspectRatio(contentMode: .fill)
        } placeholder: {
            ZStack {
                Rectangle().fill(.quaternary)
                Text(card.title ?? "Untitled")
                    .font(.headline)
                    .multilineTextAlignment(.center)
                    .padding()
            }
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .clipped()
        .overlay(alignment: .bottom) {
            if let progress = card.progress {
                ProgressView(value: progress)
                    .tint(.white)
                    .padding(12)
            }
        }
    }

    private var caption: String {
        let title = card.title ?? "Untitled"
        if let season = card.seasonNumber, let episode = card.episodeNumber {
            let numbered = "S\(season) E\(episode) · \(title)"
            return (card.seriesTitle.map { "\($0) · \(numbered)" } ?? numbered) + left
        }
        if let year = card.year {
            return "\(title) (\(String(year)))" + left
        }
        return title + left
    }

    /// " · 42m left", from nectar's runtime and this user's progress.
    private var left: String {
        guard let runtime = card.runtimeSeconds, let progress = card.progressSeconds, runtime > progress else { return "" }
        return " · \(ItemDetailView.duration(runtime - progress)) left"
    }
}

/// A titled row of posters, in the shape of what's in it; prefetches its artwork as it appears.
private struct PosterShelf: View {

    let title: String
    let kind: Library.Kind
    let session: NectarSession
    let cards: [MediaCard]
    let select: (MediaCard) -> Void

    private var shape: LibraryPoster.Shape { .init(kind) }

    private func artwork(_ card: MediaCard) -> URL? {
        session.resolve(card.posterPath, pixelWidth: shape.size.width * 2)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(title).font(.title3.bold())
            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: 40) {
                    ForEach(cards) { card in
                        LibraryPoster(card: card, shape: shape, artwork: artwork(card)) { select(card) }
                    }
                }
                .padding(.vertical, 20)
            }
            .scrollClipDisabled()
            .onAppear { ImageCache.shared.prefetch(cards.map(artwork)) }
        }
    }
}
