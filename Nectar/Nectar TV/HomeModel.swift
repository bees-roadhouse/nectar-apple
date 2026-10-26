import Foundation
import NectarKit
import OSLog
import TVServices

private let log = Logger(subsystem: "com.beesroadhouse.nectar.tv", category: "topshelf")

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
    /// The billboard: what's being watched, then what's new.
    private(set) var hero: [HeroSlide] = []
    private(set) var shelves: [Shelf] = []
    /// The title on screen, if one is playing.
    var playing: PlayerModel?
    /// A library title opened from a row.
    var opened: MediaCard?
    /// A recommendation not in the library, opened as Discover shows it.
    var discovering: DiscoverItem?

    /// A `nectar://` link to open or play once Home is on screen (#78).
    private var link: NectarLink?

    /// How many genre rows, as the web's home.
    private static let genreRows = 4
    private let signedOut: () -> Void
    /// Ends when someone signs out: a load still waiting then must not write their titles to the Top Shelf.
    private let life = ModelLife()

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

    /// A billboard slide: from Continue Watching it resumes as the row does; anything else asks nectar where
    /// this user stopped first, since a list row doesn't say and playing from 0 would overwrite it.
    func play(_ slide: HeroSlide) async {
        if slide.resumable { return play(slide.card) }
        let resume = (try? await session.detail(slide.card.id))?.resumeSeconds
        let card = slide.card
        play(MediaCard(id: card.id, itemType: card.itemType, title: card.title, year: card.year, runtimeSeconds: card.runtimeSeconds,
                       posterPath: card.posterPath, backdropPath: card.backdropPath, progressSeconds: resume))
    }

    /// A link to follow: whatever Home had open closes, and the link's title opens when Home next appears.
    func follow(_ link: NectarLink) {
        playing = nil
        opened = nil
        discovering = nil
        self.link = link
    }

    /// Home is on screen: open or play what a link asked for. A title being watched plays as its Continue
    /// Watching card would; anything else from where nectar says this user stopped, so playing never resets it.
    func followLink() async {
        guard let link else { return }
        self.link = nil
        switch link {
        case let .item(id):
            opened = MediaCard(id: id)
        case let .play(id):
            if let card = (try? await session.continueWatching())?.first(where: { $0.id == id }) {
                return play(card)
            }
            guard let detail = try? await session.detail(id), detail.itemType != "series" else {
                opened = MediaCard(id: id)
                return
            }
            play(detail.card(startingAt: detail.resumeSeconds))
        }
    }

    /// Signed out: nothing this Home was still loading is shown or published any more.
    func retire() {
        life.stop()
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
        // The newest films and series asked for apart: across all libraries the newest twenty are mostly albums here.
        async let films = try? session.media(.recentlyAdded(in: nil, itemType: "movie"))
        async let series = try? session.media(.recentlyAdded(in: nil, itemType: "series"))
        let (newFilms, newSeries) = await ((films)?.items ?? [], (series)?.items ?? [])
        let recent = zip(newFilms, newSeries).flatMap { [$0, $1] } + newFilms.dropFirst(newSeries.count) + newSeries.dropFirst(newFilms.count)
        guard !life.isStopped else { return }
        if case let .loaded(watching) = continueWatching {
            hero = HeroSlide.pick(watching: watching, recent: recent)
            publishTopShelf(watching: watching, recent: recent)
        }
        forYou = await recommendations ?? []
        self.shelves = await shelves
        await refreshTitleCatalog()
    }

    /// Hands the Top Shelf extension what Home shows (#74). The system reloads the shelf only when it changed.
    private func publishTopShelf(watching: [MediaCard], recent: [MediaCard]) {
        guard let store = TopShelfStore() else { return }
        let session = session
        let feed = TopShelfFeed.make(watching: watching, recent: recent) { session.resolve($0, pixelWidth: $1) }
        guard feed != store.feed else { return }
        let status = store.save(feed)
        log.info("top shelf feed: \(feed.watching.count, privacy: .public) watching, \(feed.new.count, privacy: .public) new, saved \(status, privacy: .public)")
        TVTopShelfContentProvider.topShelfContentDidChange()
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
                    return (index, page.map { Shelf(id: "recent-\(library.id)", title: "New in \(library.name)", kind: library.kind, cards: $0.items) })
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
