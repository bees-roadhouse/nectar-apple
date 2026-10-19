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
            self.detail = .loaded(detail)
        } catch {
            detail = .failed
        }
        self.similar = await similar ?? []
    }

    func play(_ detail: ItemDetail, from seconds: Double?) {
        playing = PlayerModel(card: detail.card(startingAt: seconds), session: session)
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
