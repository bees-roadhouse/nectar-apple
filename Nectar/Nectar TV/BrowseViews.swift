import NectarKit
import SwiftUI

/// A person: their photo and name, and every title of theirs in the libraries, newest first.
struct PersonView: View {

    let id: String
    let session: NectarSession
    let playlistAdding: PlaylistAdding

    @State
    private var detail: PersonDetail?
    @State
    private var failed = false
    @State
    private var opened: MediaCard?

    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 40) {
                if let detail {
                    HStack(spacing: 40) {
                        CachedImage(url: detail.person.photo, maxPixelSize: 480) { image in
                            image.resizable().aspectRatio(contentMode: .fill)
                        } placeholder: {
                            Circle().fill(.quaternary)
                        }
                        .frame(width: 220, height: 220)
                        .clipShape(Circle())
                        VStack(alignment: .leading, spacing: 10) {
                            Text(detail.person.name).font(.largeTitle.bold())
                            Text(detail.credits.count == 1 ? "1 title in your libraries" : "\(detail.credits.count) titles in your libraries")
                                .foregroundStyle(.secondary)
                        }
                    }
                    TitleGrid(cards: detail.credits.map(\.card), captions: Dictionary(uniqueKeysWithValues: detail.credits.map { ($0.id, $0.role) }), session: session) {
                        open($0)
                    }
                } else if failed {
                    Text("Couldn't load this person.").foregroundStyle(.secondary)
                } else {
                    ProgressView()
                }
            }
            .padding(80)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.ignoresSafeArea())
        .task {
            do { detail = try await session.person(id) } catch { failed = true }
        }
        .fullScreenCover(item: $opened) { card in
            ItemDetailView(id: card.id, session: session, playlistAdding: playlistAdding)
        }
    }

    private func open(_ card: MediaCard) {
        guard ["movie", "series", "episode"].contains(card.itemType ?? "") else { return }
        opened = card
    }
}

/// A genre across every library, best rated first, a page at a time.
struct GenreView: View {

    let genre: String
    let session: NectarSession
    let playlistAdding: PlaylistAdding

    @State
    private var cards: [MediaCard] = []
    @State
    private var total = 0
    @State
    private var loading = true
    @State
    private var opened: MediaCard?

    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 32) {
                Text(genre).font(.largeTitle.bold())
                if !loading { Text("\(total.formatted()) titles").foregroundStyle(.secondary) }
                TitleGrid(cards: cards, captions: [:], session: session, appeared: { card in
                    Task { await loadMore(after: card) }
                }) { card in
                    if card.itemType == "movie" || card.itemType == "series" { opened = card }
                }
                if loading { ProgressView() }
            }
            .padding(80)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.ignoresSafeArea())
        .task { await load(from: 0) }
        .fullScreenCover(item: $opened) { card in
            ItemDetailView(id: card.id, session: session, playlistAdding: playlistAdding)
        }
    }

    private func query(from offset: Int) -> LibraryQuery {
        var query = LibraryQuery(library: nil)
        query.genre = genre
        query.sort = .rating
        query.descending = true
        query.offset = offset
        return query
    }

    private func load(from offset: Int) async {
        loading = true
        defer { loading = false }
        guard let page = try? await session.media(query(from: offset)) else { return }
        cards += page.items.filter { new in !cards.contains { $0.id == new.id } }
        total = page.total
    }

    private func loadMore(after card: MediaCard) async {
        guard !loading, cards.count < total, cards.suffix(12).contains(where: { $0.id == card.id }) else { return }
        await load(from: cards.count)
    }
}

/// One of the server's collections: its titles.
struct CollectionView: View {

    let collection: Playlist
    let session: NectarSession
    let playlistAdding: PlaylistAdding

    @State
    private var members: [PlaylistMember]?
    @State
    private var opened: MediaCard?

    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 32) {
                Text(collection.name).font(.largeTitle.bold())
                if let description = collection.description, !description.isEmpty {
                    Text(description).foregroundStyle(.secondary).frame(maxWidth: 1100, alignment: .leading)
                }
                if let members {
                    TitleGrid(cards: members.map { MediaCard(id: $0.mediaItemID ?? $0.id, itemType: $0.itemType, title: $0.title, year: $0.year, posterPath: $0.posterPath) },
                              captions: Dictionary(uniqueKeysWithValues: members.filter { $0.entry == .wanted }.map { ($0.mediaItemID ?? $0.id, "Not here yet") }),
                              session: session) { card in
                        guard members.contains(where: { $0.mediaItemID == card.id }), card.itemType == "movie" || card.itemType == "series" else { return }
                        opened = card
                    }
                } else {
                    ProgressView()
                }
            }
            .padding(80)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.ignoresSafeArea())
        .task { members = (try? await session.playlist(collection.id))?.members ?? [] }
        .fullScreenCover(item: $opened) { card in
            ItemDetailView(id: card.id, session: session, playlistAdding: playlistAdding)
        }
    }
}

/// Posters in a grid, each with an optional line under it; nectar's own artwork or a full URL.
struct TitleGrid: View {

    let cards: [MediaCard]
    let captions: [String: String?]
    let session: NectarSession
    var appeared: (MediaCard) -> Void = { _ in }
    let select: (MediaCard) -> Void

    private let shape = LibraryPoster.Shape(.movies)

    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.fixed(shape.size.width), spacing: 48), count: 6), alignment: .leading, spacing: 48) {
            ForEach(cards) { card in
                VStack(alignment: .leading, spacing: 4) {
                    LibraryPoster(card: card, shape: shape, artwork: artwork(card)) { select(card) }
                    if let caption = captions[card.id] ?? nil {
                        Text(caption).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                            .frame(width: shape.size.width, alignment: .leading)
                    }
                }
                .onAppear { appeared(card) }
            }
        }
    }

    private func artwork(_ card: MediaCard) -> URL? {
        guard let path = card.posterPath else { return nil }
        return path.hasPrefix("http") ? URL(string: path) : session.resolve(path, pixelWidth: shape.size.width * 2)
    }
}
