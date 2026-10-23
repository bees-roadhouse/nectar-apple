import NectarKit
import SwiftUI

/// A library tab: the controls along the top, then every title as a poster, a page at a time.
struct LibraryView: View {

    @State
    private var model: LibraryModel
    /// The library's own search, pushed over the grid so Back returns to it as it was (#96).
    @State
    private var searching = false

    init(library: Library, session: NectarSession) {
        _model = State(initialValue: LibraryModel(library: library, session: session))
    }

    private var shape: LibraryPoster.Shape { .init(model.library.kind) }
    private var columns: [GridItem] {
        Array(repeating: GridItem(.fixed(shape.size.width), spacing: 48), count: shape.columns)
    }

    var body: some View {
        NavigationStack {
            grid
                .navigationDestination(isPresented: $searching) {
                    LibrarySearchView(library: model.library, session: model.session, playlistAdding: model.playlistAdding)
                }
        }
    }

    private var grid: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 32) {
                controls
                switch model.state {
                case .loading where model.items.isEmpty:
                    ProgressView().frame(maxWidth: .infinity)
                case .failed:
                    Text("Couldn't load \(model.library.name).").foregroundStyle(.secondary)
                default:
                    if model.items.isEmpty {
                        Text("Nothing here with these filters.").foregroundStyle(.secondary)
                    }
                    LazyVGrid(columns: columns, alignment: .leading, spacing: 48) {
                        ForEach(model.items) { card in
                            LibraryPoster(card: card, shape: shape, artwork: model.session.resolve(card.posterPath, pixelWidth: shape.size.width * 2)) {
                                model.open(card)
                            }
                            .onAppear { Task { await model.loadMore(after: card) } }
                        }
                    }
                }
            }
            .padding(.vertical, 40)
        }
        .task { await model.start() }
        .fullScreenCover(item: $model.opened) { card in
            ItemDetailView(id: card.id, session: model.session, playlistAdding: model.playlistAdding)
        }
    }

    /// Search first, then sort, order, genre and resolution; a count of what the filters leave.
    private var controls: some View {
        HStack(spacing: 30) {
            Button { searching = true } label: {
                Image(systemName: "magnifyingglass")
            }
            .accessibilityLabel("Search \(model.library.name)")
            Menu {
                ForEach(LibraryQuery.Sort.allCases, id: \.self) { sort in
                    Button(label(sort)) { Task { await model.change { $0.sort = sort } } }
                }
            } label: {
                Label(label(model.query.sort), systemImage: "arrow.up.arrow.down")
            }
            Button(model.query.descending ? "Descending" : "Ascending", systemImage: model.query.descending ? "chevron.down" : "chevron.up") {
                Task { await model.change { $0.descending.toggle() } }
            }
            if !model.filters.genres.isEmpty {
                Menu {
                    Button("All genres") { Task { await model.change { $0.genre = nil } } }
                    ForEach(model.filters.genres, id: \.self) { genre in
                        Button(genre) { Task { await model.change { $0.genre = genre } } }
                    }
                } label: {
                    Label(model.query.genre ?? "All genres", systemImage: "theatermasks")
                }
            }
            // Video only: nectar's facets cover the whole library, and a resolution means nothing for an album.
            if model.library.kind.isVideo, model.filters.resolutions.count > 1 {
                Menu {
                    Button("Any resolution") { Task { await model.change { $0.resolution = nil } } }
                    ForEach(model.filters.resolutions, id: \.self) { resolution in
                        Button(resolution) { Task { await model.change { $0.resolution = resolution } } }
                    }
                } label: {
                    Label(model.query.resolution ?? "Any resolution", systemImage: "4k.tv")
                }
            }
            Spacer()
            if case .loaded = model.state {
                Text(model.library.kind.count(model.total)).foregroundStyle(.secondary)
            }
        }
    }

    private func label(_ sort: LibraryQuery.Sort) -> String {
        switch sort {
        case .title: "Title"
        case .year: "Year"
        case .dateAdded: "Date added"
        case .rating: "Rating"
        }
    }
}

/// A poster and its title; chosen, a film or series opens its detail.
struct LibraryPoster: View {

    /// Posters for films, shows and books; squares for albums; landscape for photos.
    struct Shape {
        let size: CGSize
        let columns: Int

        init(_ kind: Library.Kind) {
            switch kind {
            case .music: size = CGSize(width: 300, height: 300); columns = 5
            case .photos: size = CGSize(width: 400, height: 225); columns = 4
            case .movies, .shows, .books, .other: size = CGSize(width: 240, height: 360); columns = 6
            }
        }
    }

    let card: MediaCard
    let shape: Shape
    let artwork: URL?
    let select: () -> Void
    @FocusState
    private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button(action: select) {
                CachedImage(
                    url: artwork, maxPixelSize: Int(max(shape.size.width, shape.size.height) * 2), blurHash: card.posterBlurHash
                ) { image in
                    image.resizable().aspectRatio(contentMode: .fill)
                } placeholder: {
                    ZStack {
                        Rectangle().fill(.quaternary)
                        Text(card.title ?? "Untitled").font(.caption).multilineTextAlignment(.center).padding()
                    }
                }
                .frame(width: shape.size.width, height: shape.size.height)
                .clipped()
                .preloadBadge(card.id)
                .cardStatus(status)
            }
            .buttonStyle(.card)
            .focused($focused)
            // The title on one line and the year on its own, so a long title truncates instead of orphaning
            // "· 2011" (Capping, #103).
            VStack(alignment: .leading, spacing: 2) {
                Text(card.title ?? "Untitled").font(.caption).lineLimit(1)
                // Focused, a title on its way in says where it is in place of its year (#125, Capping).
                Text(focused ? (status?.words ?? year) : year).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            .frame(width: shape.size.width, alignment: .leading)
        }
    }

    private var status: CardStatus? { CardStatus.of(card.pipeline) }
    private var year: String { card.year.map(String.init) ?? " " }
}
