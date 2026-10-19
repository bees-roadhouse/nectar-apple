import AVFoundation
import Foundation
import NectarKit

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
    /// The trailer playing, if one is.
    var trailer: TrailerPlayer?
    /// A "More like this" title opened on top of this one.
    var opened: MediaCard?
    /// Someone from the cast, opened on top.
    var person: ItemDetail.CastMember?
    /// A series' episodes by season; empty for anything else.
    private(set) var seasons: [Season] = []
    /// The season whose episodes are showing.
    var selectedSeason: Int?

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
        } catch {
            detail = .failed
        }
        self.similar = await similar ?? []
    }

    func play(_ detail: ItemDetail, from seconds: Double?) {
        playing = PlayerModel(card: detail.card(startingAt: seconds), session: session)
    }

    /// An episode of this series, from where this user stopped in it.
    func play(_ episode: Episode, of detail: ItemDetail) {
        playing = PlayerModel(card: episode.card(series: detail.title), session: session)
    }

    /// Back from the player: the resume point has moved.
    func finishedPlaying() {
        playing = nil
        Task { await load() }
    }

    func playTrailer(_ detail: ItemDetail) async {
        guard let path = detail.trailerPath, let url = try? await session.mediaURL(path) else { return }
        // The URL carries the token: it goes to AVPlayer and nowhere else.
        trailer = TrailerPlayer(player: AVPlayer(url: url))
    }
}

/// A trailer is a plain file: no decide, no progress.
struct TrailerPlayer: Identifiable {
    let id = UUID()
    let player: AVPlayer
}
