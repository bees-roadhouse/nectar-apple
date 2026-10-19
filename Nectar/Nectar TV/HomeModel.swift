import Foundation
import NectarKit

/// The signed-in home's rows. One so far: continue watching.
@MainActor
@Observable
final class HomeModel {

    enum Row {
        case loading
        case loaded([MediaCard])
        case failed
    }

    let session: NectarSession
    private(set) var continueWatching: Row = .loading
    /// The title on screen, if one is playing.
    var playing: PlayerModel?
    private let signedOut: () -> Void

    init(session: NectarSession, signedOut: @escaping () -> Void) {
        self.session = session
        self.signedOut = signedOut
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
        } catch {
            continueWatching = .failed
        }
    }
}
