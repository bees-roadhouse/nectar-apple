import NectarKit
import SwiftUI

/// The Search tab: titles by name and meaning, or moments by what's said, seen or heard.
struct SearchView: View {

    @Bindable
    var model: SearchModel

    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 40) {
                Picker("Search", selection: $model.mode) {
                    ForEach(SearchMode.allCases, id: \.self) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 1000)
                results
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 40)
        }
        .searchable(text: $model.query, prompt: prompt)
        .task(id: "\(model.mode.rawValue)|\(model.query)") { await model.search() }
        .fullScreenCover(item: $model.opened) { card in
            ItemDetailView(id: card.id, session: model.session, playlistAdding: model.playlistAdding)
        }
        .fullScreenCover(item: $model.playing) { player in
            PlayerView(model: player) { model.playing = nil }
        }
        .fullScreenCover(item: $model.openedGenre) { genre in
            GenreView(genre: genre.name, session: model.session, playlistAdding: model.playlistAdding)
        }
        .fullScreenCover(item: $model.openedCollection) { collection in
            CollectionView(collection: collection, session: model.session, playlistAdding: model.playlistAdding)
        }
        .task { await model.loadBrowse() }
    }

    private var prompt: String {
        switch model.mode {
        case .titles: "Titles, people, what it's about"
        case .dialogue: "A line someone says"
        case .scenes: "What's on screen"
        case .audio: "What it sounds like"
        }
    }

    @ViewBuilder
    private var results: some View {
        switch model.results {
        case .idle:
            Text(hint).foregroundStyle(.secondary)
            if model.mode == .titles { browse }
        case .searching:
            ProgressView()
        case let .titles(hits) where hits.isEmpty:
            Text("Nothing found.").foregroundStyle(.secondary)
        case let .moments(hits) where hits.isEmpty:
            Text("Nothing found.").foregroundStyle(.secondary)
        case let .titles(hits):
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(LibraryPoster.Shape(.movies).size.width), spacing: 48), count: 6), alignment: .leading, spacing: 48) {
                ForEach(hits) { hit in
                    LibraryPoster(card: MediaCard(id: hit.id, itemType: hit.itemType, title: hit.title, year: hit.year, posterPath: hit.posterPath),
                                  shape: .init(.movies),
                                  artwork: model.session.resolve(hit.posterPath, pixelWidth: 480)) {
                        model.open(hit)
                    }
                }
            }
        case let .moments(hits):
            // Audio hits are tracks: their album art is square. Dialogue and scenes are frames of a picture.
            let size = model.mode == .audio ? CGSize(width: 300, height: 300) : CGSize(width: 400, height: 225)
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(size.width), spacing: 48), count: model.mode == .audio ? 5 : 4), alignment: .leading, spacing: 48) {
                ForEach(hits) { hit in
                    MomentCard(hit: hit, size: size, frame: model.thumbnails[hit.id] ?? model.session.resolve(hit.posterPath, pixelWidth: size.width * 2)) {
                        model.play(hit)
                    }
                }
            }
        case let .disabled(mode):
            Text("\(mode.title) search is switched off on this nectar.").foregroundStyle(.secondary)
        case .failed:
            Text("Couldn't search right now.").foregroundStyle(.secondary)
        }
    }

    /// Before typing: collections, if the server has any, then every genre.
    @ViewBuilder
    private var browse: some View {
        if !model.collections.isEmpty {
            Text("Collections").font(.title3.bold())
            ScrollView(.horizontal) {
                LazyHStack(spacing: 40) {
                    ForEach(model.collections) { collection in
                        Button { model.openedCollection = collection } label: {
                            VStack(alignment: .leading, spacing: 8) {
                                Image(systemName: "square.stack").font(.largeTitle)
                                Text(collection.name).font(.headline).lineLimit(2)
                                Text(collection.titleCount == 1 ? "1 title" : "\(collection.titleCount) titles").font(.caption).foregroundStyle(.secondary)
                            }
                            .frame(width: 320, height: 180, alignment: .bottomLeading)
                            .padding(20)
                        }
                        .buttonStyle(.card)
                    }
                }
                .padding(.vertical, 20)
            }
            .scrollClipDisabled()
        }
        GenreChips(title: "Genres", genres: model.genres) { model.openedGenre = .init(name: $0) }
        GenreChips(title: "Music genres", genres: model.musicGenres) { model.openedGenre = .init(name: $0) }
    }

    private var hint: String {
        switch model.mode {
        case .titles: "Search your libraries."
        case .dialogue: "Find the moment a line is said, and play from it."
        case .scenes: "Describe a scene to find it."
        case .audio: "Describe a sound or a song."
        }
    }
}

/// A moment: the frame (or the poster), the title, when, and the line.
private struct MomentCard: View {

    let hit: SearchHit
    let size: CGSize
    let frame: URL?
    let select: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button(action: select) {
                CachedImage(url: frame, maxPixelSize: Int(size.width * 2)) { image in
                    image.resizable().aspectRatio(contentMode: .fill)
                } placeholder: {
                    ZStack {
                        Rectangle().fill(.quaternary)
                        Text(hit.title).font(.caption).multilineTextAlignment(.center).padding()
                    }
                }
                .frame(width: size.width, height: size.height)
                .clipped()
            }
            .buttonStyle(.card)
            Text(caption).font(.caption).lineLimit(1).frame(width: size.width, alignment: .leading)
            if let snippet = hit.snippet {
                Text("\u{201C}\(snippet)\u{201D}").font(.caption2).foregroundStyle(.secondary).lineLimit(2, reservesSpace: true)
                    .frame(width: size.width, alignment: .leading)
            }
        }
    }

    private var caption: String {
        guard let seconds = hit.seconds else { return hit.title }
        return "\(hit.title) · at \(ItemDetailView.clock(seconds))"
    }
}

/// A titled grid of genre buttons; nothing when there are none.
private struct GenreChips: View {

    let title: String
    let genres: [String]
    let open: (String) -> Void

    var body: some View {
        if !genres.isEmpty {
            Text(title).font(.title3.bold())
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 30), count: 5), alignment: .leading, spacing: 30) {
                ForEach(genres, id: \.self) { genre in
                    Button(genre) { open(genre) }
                        .lineLimit(1)
                }
            }
        }
    }
}
