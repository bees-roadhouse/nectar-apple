import Foundation
import NectarKit
import os

private let log = Logger(subsystem: "com.beesroadhouse.nectar.tv", category: "detail")

/// One library title's detail page: what nectar says about it, titles like it, and what's playing from it.
@MainActor
@Observable
final class ItemDetailModel {

    enum Load {
        case loading
        case loaded(ItemDetail)
        case failed
    }

    let id: String
    let session: NectarSession
    let playlistAdding: PlaylistAdding
    private(set) var detail: Load = .loading
    private(set) var similar: [MediaCard] = []
    /// Chapter thumbnails carry the token, so they're made once the detail is in.
    private(set) var chapterThumbnails: [Int: URL] = [:]
    /// The title playing from this page.
    var playing: PlayerModel?
    /// A series playing from an episode on, one into the next.
    var queue: PlayQueue?
    /// The trailers playing, if they are.
    var trailers: TrailersModel?
    /// A "More like this" title opened on top of this one.
    var opened: MediaCard?
    /// Someone from the cast, opened on top.
    var person: ItemDetail.CastMember?
    /// A series' episodes by season; empty for anything else.
    private(set) var seasons: [Season] = []
    /// The season whose episodes are showing.
    var selectedSeason: Int?
    /// Trailers already asked for, so reloading the page doesn't ask again.
    @ObservationIgnored
    private var askedTrailers: Set<String> = []
    @ObservationIgnored
    private var warming: Task<Void, Never>?

    /// nectar answers an unready trailer with `Retry-After: 20`; look again that often for about two minutes.
    static let lookAgainEvery: Duration = .seconds(20)
    static let looks = 6

    init(id: String, session: NectarSession, playlistAdding: PlaylistAdding) {
        self.id = id
        self.session = session
        self.playlistAdding = playlistAdding
    }

    func load() async {
        async let similar = try? session.similar(to: id)
        do {
            let detail = try await session.detail(id)
            var thumbnails: [Int: URL] = [:]
            for chapter in detail.chapters {
                thumbnails[chapter.index] = try? await session.mediaURL(chapter.thumbnailPath(item: id))
            }
            chapterThumbnails = thumbnails
            if detail.itemType == "series" {
                seasons = (try? await session.children(of: id)) ?? []
                // Open on the season of what's next, or the first; keep the viewer's choice across reloads.
                if selectedSeason == nil || !seasons.contains(where: { $0.id == selectedSeason }) {
                    let next = Season.nextUp(in: seasons)?.episode
                    selectedSeason = seasons.first { $0.episodes.contains { $0.id == next?.id } }?.id ?? seasons.first?.id
                }
            }
            self.detail = .loaded(detail)
            warmTrailers(detail)
        } catch {
            detail = .failed
        }
        self.similar = await similar ?? []
    }

    func play(_ detail: ItemDetail, from seconds: Double?) {
        playing = PlayerModel(card: detail.card(startingAt: seconds), session: session)
    }

    /// An episode of this series, from where this user stopped in it, then on through the rest.
    func play(_ episode: Episode, of detail: ItemDetail) {
        queue = PlayQueue(cards: Season.queue(from: episode, in: seasons).map { $0.card(series: detail.title) })
    }

    /// Back from a queue: next-up and the marks have moved on.
    func finishedQueue() {
        queue = nil
        Task { await load() }
    }

    /// Back from the player: the resume point has moved.
    func finishedPlaying() {
        playing = nil
        Task { await load() }
    }

    /// Asks nectar once for each unready trailer as the page opens, which starts its fetch (nectar #715), then reads the
    /// title again until they've landed or failed, so the Trailers button can arrive on its own.
    private func warmTrailers(_ detail: ItemDetail) {
        let unready = detail.trailers.filter { !$0.isReady && !askedTrailers.contains($0.id) }
        guard !unready.isEmpty, warming == nil else { return }
        askedTrailers.formUnion(unready.map(\.id))
        warming = Task { [weak self, session, id] in
            for trailer in unready {
                do { try await session.head(trailer.path) } catch { log.info("trailer \(trailer.id, privacy: .public) fetch not started: \(String(describing: error), privacy: .public)") }
            }
            for _ in 0 ..< Self.looks {
                try? await Task.sleep(for: Self.lookAgainEvery)
                guard let self, !Task.isCancelled else { return }
                guard let fresh = try? await session.detail(id) else { continue }
                if case .loaded = self.detail { self.detail = .loaded(fresh) }
                if fresh.trailers.allSatisfy(\.isReady) { break }
            }
            self?.warming = nil
        }
    }

    func playTrailers(_ detail: ItemDetail) {
        trailers = TrailersModel(detail: detail, session: session)
    }
}
