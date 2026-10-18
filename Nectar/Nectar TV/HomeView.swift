import NectarKit
import SwiftUI

/// The signed-in home: one row, continue watching, under who is signed in.
struct HomeView: View {

    let user: NectarUser
    let model: HomeModel
    let signOut: () -> Void

    /// Focus starts on the row, not on Sign out.
    @Namespace
    private var focusScope

    @Environment(\.resetFocus)
    private var resetFocus

    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 48) {
                ContinueWatchingRow(row: model.continueWatching, session: model.session, focusScope: focusScope)

                HStack(spacing: 24) {
                    Text("Signed in as \(user.username)")
                        .foregroundStyle(.secondary)
                    Button("Sign out", action: signOut)
                }
            }
            .padding(.vertical, 40)
            .focusScope(focusScope)
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
                                artwork: session.resolve(card.artworkPath),
                                isDefaultFocus: card.id == cards.first?.id,
                                focusScope: focusScope
                            )
                        }
                    }
                    .padding(.vertical, 20)
                }
                .scrollClipDisabled()
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
    let isDefaultFocus: Bool
    let focusScope: Namespace.ID

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Playback is slice 3; until then a card only takes focus. The card style lifts the artwork alone.
            Button {} label: { artworkView }
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
        AsyncImage(url: artwork) { image in
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
            return card.seriesTitle.map { "\($0) · \(numbered)" } ?? numbered
        }
        if let year = card.year {
            return "\(title) (\(String(year)))"
        }
        return title
    }
}
