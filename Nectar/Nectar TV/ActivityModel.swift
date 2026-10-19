import Foundation
import NectarKit

/// What nectar is downloading, kept live: seeded from the queue when this user may read it, then
/// followed over the event stream, reconnecting with backoff. Nothing is polled.
@MainActor
@Observable
final class ActivityModel {

    let session: NectarSession
    private(set) var board = DownloadBoard()
    /// Whether the stream is up, for the Activity page to say.
    private(set) var connected = false

    init(session: NectarSession) {
        self.session = session
    }

    /// Runs for as long as the signed-in app does; a dropped stream reconnects after 2, 4 … 60 s.
    func follow() async {
        var delay: Duration = .seconds(2)
        while !Task.isCancelled {
            if let queue = try? await session.downloadQueue() { board.seed(queue) }
            do {
                connected = true
                for try await event in session.eventStream() {
                    board.apply(event)
                    delay = .seconds(2)
                }
            } catch {
                // Dropped, refused or offline: wait and try again.
            }
            connected = false
            try? await Task.sleep(for: delay)
            delay = min(delay * 2, .seconds(60))
        }
    }

    /// "12 min left", "less than a minute left", or nothing when nectar can't say.
    static func timeLeft(_ download: Download) -> String? {
        guard let eta = download.etaSeconds, eta > 0 else { return nil }
        return eta < 60 ? "less than a minute left" : "\(ItemDetailView.duration(eta)) left"
    }
}
