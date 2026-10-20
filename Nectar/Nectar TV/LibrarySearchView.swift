import NectarKit
import SwiftUI

/// Search inside one library (#96, Capping's spec): the system search screen, results in the library's own
/// cards and order, this library's recent searches before typing, and a way out to the whole of nectar.
struct LibrarySearchView: View {

    @State
    private var model: LibrarySearchModel
    @Environment(\.searchEverywhere)
    private var searchEverywhere

    init(library: Library, session: NectarSession, playlistAdding: PlaylistAdding) {
        _model = State(initialValue: LibrarySearchModel(library: library, session: session, playlistAdding: playlistAdding))
    }

    private var shape: LibraryPoster.Shape { .init(model.library.kind) }

    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 40) {
                results
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 40)
        }
        .searchable(text: $model.query, prompt: "Search \(model.library.name)")
        .onSubmit(of: .search) { model.remember() }
        .task(id: model.query) { await model.search() }
        .fullScreenCover(item: $model.opened) { card in
            ItemDetailView(id: card.id, session: model.session, playlistAdding: model.playlistAdding)
        }
        .fullScreenCover(item: $model.playing) { player in
            PlayerView(model: player) { model.playing = nil }
        }
    }

    @ViewBuilder
    private var results: some View {
        switch model.results {
        case .idle:
            recent
        case .searching:
            if model.showsSkeleton { skeleton }
        case let .found(sections, lines) where sections.isEmpty && lines.isEmpty:
            VStack(spacing: 30) {
                ContentUnavailableView.search(text: model.query)
                // A title in another library is the likeliest reason for nothing here.
                Button("Search all of nectar") { searchEverywhere(model.query) }
            }
            .frame(maxWidth: .infinity)
        case let .found(sections, lines):
            ForEach(Array(sections.enumerated()), id: \.offset) { _, section in
                if let title = section.title {
                    Text(title).font(.title3)
                }
                switch section.style {
                case .posters: posters(section.hits)
                case .stills: stills(section.hits)
                case .list: list(section.hits)
                }
            }
            if !lines.isEmpty {
                Text("Said in").font(.title3)
                saidIn(lines)
            }
        case .failed:
            Text("Couldn't search \(model.library.name) right now.").foregroundStyle(.secondary)
        }
    }

    /// Before typing: what was searched here lately, or nothing at all.
    @ViewBuilder
    private var recent: some View {
        if !model.recent.isEmpty {
            VStack(alignment: .leading, spacing: 16) {
                ForEach(model.recent, id: \.self) { query in
                    Button(query) { model.query = query }
                }
            }
        }
    }

    /// The library's own grid, as the results come in.
    private func posters(_ hits: [TitleHit]) -> some View {
        LazyVGrid(columns: Array(repeating: GridItem(.fixed(shape.size.width), spacing: 48), count: shape.columns), alignment: .leading, spacing: 48) {
            ForEach(hits) { hit in
                LibraryPoster(card: MediaCard(id: hit.id, itemType: hit.itemType, title: hit.title, year: hit.year, posterPath: hit.posterPath),
                              shape: shape,
                              artwork: model.session.resolve(hit.posterPath, pixelWidth: shape.size.width * 2)) {
                    model.open(hit)
                }
            }
        }
    }

    /// Episodes as a row of stills.
    private func stills(_ hits: [TitleHit]) -> some View {
        ScrollView(.horizontal) {
            LazyHStack(spacing: 48) {
                ForEach(hits) { hit in
                    StillCard(title: hit.title, artwork: model.session.resolve(hit.posterPath, pixelWidth: StillCard.size.width * 2)) {
                        model.open(hit)
                    }
                }
            }
            .padding(.vertical, 20)
        }
        .scrollClipDisabled()
    }

    /// Songs as Music lists them.
    private func list(_ hits: [TitleHit]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(hits) { hit in
                Button { model.open(hit) } label: {
                    Text([hit.title, hit.year.map(String.init)].compactMap(\.self).joined(separator: " · "))
                        .frame(maxWidth: 1200, alignment: .leading)
                }
            }
        }
    }

    /// The moment each line is said; choosing one plays from there.
    private func saidIn(_ lines: [SearchHit]) -> some View {
        ScrollView(.horizontal) {
            LazyHStack(alignment: .top, spacing: 48) {
                ForEach(lines) { hit in
                    MomentCard(hit: hit, size: StillCard.size, frame: model.thumbnails[hit.id] ?? model.session.resolve(hit.posterPath, pixelWidth: StillCard.size.width * 2)) {
                        model.play(hit)
                    }
                }
            }
            .padding(.vertical, 20)
        }
        .scrollClipDisabled()
    }

    /// Cards in the library's own shape while nectar answers; no spinner (the web's rule too).
    private var skeleton: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.fixed(shape.size.width), spacing: 48), count: shape.columns), alignment: .leading, spacing: 48) {
            ForEach(0 ..< shape.columns, id: \.self) { _ in
                RoundedRectangle(cornerRadius: 12).fill(.quaternary).frame(width: shape.size.width, height: shape.size.height)
            }
        }
        .accessibilityLabel("Searching")
    }
}

/// An episode still and its name.
private struct StillCard: View {

    static let size = CGSize(width: 400, height: 225)

    let title: String
    let artwork: URL?
    let select: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button(action: select) {
                CachedImage(url: artwork, maxPixelSize: Int(Self.size.width * 2)) { image in
                    image.resizable().aspectRatio(contentMode: .fill)
                } placeholder: {
                    ZStack {
                        Rectangle().fill(.quaternary)
                        Text(title).font(.caption).multilineTextAlignment(.center).padding()
                    }
                }
                .frame(width: Self.size.width, height: Self.size.height)
                .clipped()
            }
            .buttonStyle(.card)
            Text(title).font(.caption).lineLimit(2, reservesSpace: true).frame(width: Self.size.width, alignment: .leading)
        }
    }
}

extension EnvironmentValues {
    /// Hands a query to the Search tab: "Search all of nectar" from a library's own search (#96).
    @Entry var searchEverywhere: @MainActor (String) -> Void = { _ in }
}
