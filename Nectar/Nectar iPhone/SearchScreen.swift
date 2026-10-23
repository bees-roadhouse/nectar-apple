import NectarKit
import SwiftUI
import UIKit

/// The Search tab, native (#158 slice 5): the system's search field with its scope bar for Titles · Dialogue · Scenes ·
/// Audio, the genres and collections to browse before typing, and what nectar found as rows. The TV app's
/// `SearchModel` asks nectar; this controller only feeds it the field and the scope.
final class SearchController: UIHostingController<SearchScreen>, UISearchResultsUpdating, UISearchBarDelegate {

    private let model: SearchModel
    /// The search in flight; a newer keystroke or scope cancels it.
    private var running: Task<Void, Never>?

    init(model: SearchModel, screen: SearchScreen) {
        self.model = model
        super.init(rootView: screen)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not from a storyboard") }

    override func viewDidLoad() {
        super.viewDidLoad()
        let search = UISearchController(searchResultsController: nil)
        search.searchResultsUpdater = self
        search.obscuresBackgroundDuringPresentation = false
        search.searchBar.placeholder = "Titles, lines, scenes"
        search.searchBar.scopeButtonTitles = SearchMode.allCases.map(\.title)
        search.searchBar.delegate = self
        search.scopeBarActivation = .onSearchActivation
        navigationItem.searchController = search
        navigationItem.hidesSearchBarWhenScrolling = false
    }

    func updateSearchResults(for searchController: UISearchController) {
        let text = searchController.searchBar.text ?? ""
        guard text != model.query else { return }
        model.query = text
        rerun()
    }

    func searchBar(_ searchBar: UISearchBar, selectedScopeButtonIndexDidChange selectedScope: Int) {
        model.mode = SearchMode.allCases[selectedScope]
        rerun()
    }

    private func rerun() {
        running?.cancel()
        running = Task { [model] in await model.search() }
    }
}

struct SearchScreen: View {

    let model: SearchModel
    let playback: Playback
    let open: (MediaCard) -> Void
    let openGenre: (String) -> Void
    let openCollection: (Playlist) -> Void

    var body: some View {
        GeometryReader { proxy in
            let margin: CGFloat = proxy.size.width >= 428 ? 20 : 16
            ScrollView {
                content(margin: margin)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 8)
            }
            .contentMargins(.bottom, 32, for: .scrollContent)
            .scrollDismissesKeyboard(.immediately)
        }
        .background(Color.brhNight)
        .task { await model.loadBrowse() }
        // A moment plays in the app's one player (#157), from the line or the frame that matched.
        .onChange(of: model.playing?.id) {
            guard let player = model.playing else { return }
            model.playing = nil
            playback.play(player)
        }
    }

    @ViewBuilder
    private func content(margin: CGFloat) -> some View {
        switch model.results {
        case .idle:
            Browse(model: model, margin: margin, openGenre: openGenre, openCollection: openCollection)
        case .searching:
            Rows(margin: margin)
        case let .titles(hits) where hits.isEmpty:
            line("Nothing matches “\(model.query)”.")
        case let .moments(hits) where hits.isEmpty:
            line("Nothing matches “\(model.query)”.")
        case let .titles(hits):
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(hits) { hit in TitleRow(hit: hit, session: model.session, margin: margin) { open(card(hit)) } }
            }
        case let .moments(hits):
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(hits) { hit in
                    MomentRow(hit: hit, mode: model.mode, frame: model.thumbnails[hit.id], margin: margin) { model.play(hit) }
                }
            }
        case let .disabled(mode):
            line("\(mode.title) search is switched off on this server.")
        case .failed:
            line("Can't reach nectar right now.")
        }
    }

    private func card(_ hit: TitleHit) -> MediaCard {
        MediaCard(id: hit.id, itemType: hit.itemType, title: hit.title, posterPath: hit.posterPath)
    }

    private func line(_ text: String) -> some View {
        Text(text).font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
            .frame(maxWidth: .infinity, minHeight: 240).padding(.horizontal, 32)
    }
}

/// Before typing: every film and TV genre as a tile, the biggest music genres, and the server's collections.
private struct Browse: View {
    let model: SearchModel
    let margin: CGFloat
    let openGenre: (String) -> Void
    let openCollection: (Playlist) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 28) {
            if !model.genres.isEmpty { section("Genres", model.genres) }
            if !model.musicGenres.isEmpty { section("Music", model.musicGenres) }
            if !model.collections.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Collections").font(.title3.weight(.bold)).padding(.horizontal, margin)
                    ForEach(model.collections) { collection in
                        Button { openCollection(collection) } label: {
                            HStack {
                                Image(systemName: "square.stack").foregroundStyle(Color.brhGold).frame(width: 28)
                                Text(collection.name).foregroundStyle(.primary)
                                Spacer()
                                Text("\(collection.itemCount)").foregroundStyle(.secondary)
                                Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
                            }
                            .font(.body)
                            .padding(.horizontal, margin)
                            .frame(minHeight: 44)
                            .contentShape(.rect)
                        }
                        .buttonStyle(Pressed())
                    }
                }
            }
        }
    }

    private func section(_ title: String, _ genres: [String]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.title3.weight(.bold)).padding(.horizontal, margin)
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                ForEach(genres, id: \.self) { genre in
                    Button { openGenre(genre) } label: {
                        Text(genre).font(.subheadline.weight(.semibold)).foregroundStyle(.primary).lineLimit(1)
                            .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
                            .padding(.horizontal, 14)
                            .background(Color.brhCard, in: .rect(cornerRadius: 10))
                            .overlay { RoundedRectangle(cornerRadius: 10).stroke(Color.brhLineDim) }
                    }
                    .buttonStyle(Pressed())
                }
            }
            .padding(.horizontal, margin)
        }
    }
}

/// A title nectar found: the poster when it sends one, the name, the year and the kind.
private struct TitleRow: View {
    let hit: TitleHit
    let session: NectarSession
    let margin: CGFloat
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                CachedImage(url: session.resolve(hit.posterPath, pixelWidth: 180), maxPixelSize: 180, blurHash: hit.posterBlurHash) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    Color.brhCard.overlay { Image(systemName: symbol).foregroundStyle(.tertiary) }
                }
                .frame(width: 48, height: 72)
                .clipShape(.rect(cornerRadius: 6))
                VStack(alignment: .leading, spacing: 2) {
                    Text(hit.title).font(.body.weight(.medium)).foregroundStyle(.primary).lineLimit(2)
                    Text([hit.year.map(String.init), kind].compactMap(\.self).joined(separator: " · "))
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, margin)
            .padding(.vertical, 6)
            .contentShape(.rect)
        }
        .buttonStyle(Pressed())
    }

    private var kind: String? {
        switch hit.itemType {
        case "movie": "Movie"
        case "series": "Series"
        case "episode": "Episode"
        case "album": "Album"
        case "track": "Song"
        default: nil
        }
    }

    private var symbol: String {
        ["album", "track"].contains(hit.itemType) ? "music.note" : "film"
    }
}

/// A moment: the frame at it, the title, the line that matched, and where it is. A tap plays from there.
private struct MomentRow: View {
    let hit: SearchHit
    let mode: SearchMode
    let frame: URL?
    let margin: CGFloat
    let play: () -> Void

    var body: some View {
        Button(action: play) {
            HStack(alignment: .top, spacing: 12) {
                CachedImage(url: frame, maxPixelSize: 336, blurHash: nil) { image in
                    image.resizable().scaledToFill()
                } placeholder: { Color.brhCard }
                .frame(width: 112, height: 63)
                .clipShape(.rect(cornerRadius: 6))
                .overlay(alignment: .bottomTrailing) {
                    if let seconds = hit.seconds {
                        Text(Durations.clock(seconds)).font(.caption2.monospacedDigit().weight(.semibold))
                            .padding(.horizontal, 5).padding(.vertical, 2)
                            .background(.black.opacity(0.7), in: .rect(cornerRadius: 4))
                            .padding(4)
                    }
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(hit.title).font(.subheadline.weight(.semibold)).foregroundStyle(.primary).lineLimit(1)
                    if mode == .dialogue, let snippet = hit.snippet {
                        Text("“\(snippet)”").font(.footnote).foregroundStyle(.secondary).lineLimit(3)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, margin)
            .padding(.vertical, 6)
            .contentShape(.rect)
        }
        .buttonStyle(Pressed())
        .disabled(hit.seconds == nil)
    }
}

/// Results arriving: rows at their size, never a spinner.
private struct Rows: View {
    let margin: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(0 ..< 6, id: \.self) { _ in
                HStack(spacing: 12) {
                    RoundedRectangle(cornerRadius: 6).fill(Color.brhCard).frame(width: 48, height: 72)
                    VStack(alignment: .leading, spacing: 6) {
                        RoundedRectangle(cornerRadius: 3).fill(Color.brhCard).frame(width: 180, height: 14)
                        RoundedRectangle(cornerRadius: 3).fill(Color.brhCard).frame(width: 90, height: 10)
                    }
                }
            }
        }
        .padding(.horizontal, margin)
        .accessibilityLabel("Searching")
    }
}
