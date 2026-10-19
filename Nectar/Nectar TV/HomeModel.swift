import Foundation
import NectarKit

/// The signed-in home's rows, as the web UI's home has them: continue watching, for you,
/// recently added in each library, and the top genres.
@MainActor
@Observable
final class HomeModel {

    enum Row {
        case loading
        case loaded([MediaCard])
        case failed
    }

    /// A row of posters below continue watching.
    struct Shelf: Identifiable {
        let id: String
        let title: String
        let kind: Library.Kind
        let cards: [MediaCard]
    }

    let session: NectarSession
    let playlistAdding: PlaylistAdding
    private(set) var continueWatching: Row = .loading
    private(set) var forYou: [Recommendation] = []
    private(set) var shelves: [Shelf] = []
    /// The title on screen, if one is playing.
    var playing: PlayerModel?
    /// A library title opened from a row.
    var opened: MediaCard?
    /// A recommendation not in the library, opened as Discover shows it.
    var discovering: DiscoverItem?

    /// How many genre rows, as the web's home.
    private static let genreRows = 4
    private let signedOut: () -> Void

    init(session: NectarSession, signedOut: @escaping () -> Void) {
        self.session = session
        self.signedOut = signedOut
        playlistAdding = PlaylistAdding(session: session)
    }

    /// An owned title opens its detail; a recommendation not in the library opens as a Discover result.
    func open(_ recommendation: Recommendation) {
        if let item = recommendation.discoverItem {
            discovering = item
        } else if let id = recommendation.mediaItemID {
            opened = MediaCard(id: id, title: recommendation.title)
        }
    }

    /// Films and series open their detail; albums and the rest wait for their slices.
    func open(_ card: MediaCard) {
        guard card.itemType == "movie" || card.itemType == "series" else { return }
        opened = card
    }

    func play(_ card: MediaCard) {
        playing = PlayerModel(card: card, session: session)
    }

    /// Back from the player: the row's order and progress have moved.
    func finishedPlaying() {
        playing = nil
        Task { await load() }
    }

    func load() async {
        do {
            continueWatching = .loaded(try await session.continueWatching())
        } catch NectarSessionError.signedOut {
            // The refresh token was refused: back to the sign-in code.
            signedOut()
            return
        } catch {
            continueWatching = .failed
        }
        async let recommendations = try? session.recommendations()
        async let shelves = loadShelves()
        forYou = await recommendations ?? []
        self.shelves = await shelves
    }

    /// Recently added in each library, then the top genres best rated; a row with nothing in it is left out.
    private func loadShelves() async -> [Shelf] {
        let session = session
        let libraries = (try? await session.libraries()) ?? []
        let genres = ((try? await session.filters(library: nil))?.genres ?? []).prefix(Self.genreRows)
        return await withTaskGroup(of: (Int, Shelf?).self) { group in
            for (index, library) in libraries.enumerated() {
                group.addTask {
                    let page = try? await session.media(.recentlyAdded(in: library))
                    return (index, page.map { Shelf(id: "recent-\(library.id)", title: "Recently Added · \(library.name)", kind: library.kind, cards: $0.items) })
                }
            }
            for (offset, genre) in genres.enumerated() {
                group.addTask {
                    var query = LibraryQuery(library: nil)
                    query.genre = genre
                    query.sort = .rating
                    query.descending = true
                    query.limit = 20
                    let page = try? await session.media(query)
                    // A genre spans libraries: a row of albums is drawn square, anything else as posters.
                    return (libraries.count + offset, page.map { page in
                        let albums = !page.items.isEmpty && page.items.allSatisfy { $0.itemType == "album" }
                        return Shelf(id: "genre-\(genre)", title: genre, kind: albums ? .music : .movies, cards: page.items)
                    })
                }
            }
            var found: [(Int, Shelf?)] = []
            for await result in group { found.append(result) }
            return found.sorted { $0.0 < $1.0 }.compactMap(\.1).filter { !$0.cards.isEmpty }
        }
    }
}
