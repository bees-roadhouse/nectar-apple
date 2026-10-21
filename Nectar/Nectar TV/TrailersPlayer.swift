import AVKit
import NectarKit
import os
import SwiftUI

private let log = Logger(subsystem: "com.beesroadhouse.nectar.tv", category: "trailers")

/// A title's trailers, one into the next (#119; Nate: "trailers auto play when you click to play them"). It's the
/// system player, and the remote's left and right move between trailers through AVKit's own skip-item behaviour. Unready
/// trailers are asked for once and join the queue when nectar has them (nectar #715).
@MainActor
@Observable
final class TrailersModel: Identifiable {

    let id = UUID()
    let player = AVPlayer()
    private(set) var queue: TrailerQueue
    private let detail: ItemDetail
    private let session: NectarSession
    /// Set by the page that opened the trailers: called after the last one ends.
    @ObservationIgnored
    var close: () -> Void = {}
    @ObservationIgnored
    private weak var controller: AVPlayerViewController?
    @ObservationIgnored
    private var endObserver: NSObjectProtocol?
    @ObservationIgnored
    private var fetching: Task<Void, Never>?

    /// nectar answers an unready trailer with `Retry-After: 20`; look again that often for about two minutes.
    static let lookAgainEvery: Duration = .seconds(20)
    static let looks = 6

    /// Nil when none of the title's trailers is ready yet.
    init?(detail: ItemDetail, session: NectarSession) {
        guard let queue = TrailerQueue(detail.trailers) else { return nil }
        self.queue = queue
        self.detail = detail
        self.session = session
    }

    /// The controller the view made: left and right skip trailers only when there's more than one, else they keep
    /// AVKit's ±10 seconds.
    func attach(_ controller: AVPlayerViewController) {
        self.controller = controller
        controller.skippingBehavior = queue.trailers.count > 1 ? .skipItem : .default
        showSkips()
    }

    func start() {
        Task { await play(queue.current) }
        fetchUnready()
    }

    func stop() {
        fetching?.cancel()
        player.pause()
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
    }

    func skipForward() {
        Task { await move(forward: true, closingAfterLast: false) }
    }

    func skipBack() {
        Task { await move(forward: false, closingAfterLast: false) }
    }

    private func move(forward: Bool, closingAfterLast: Bool) async {
        if !queue.unready.isEmpty { await reread() }
        if let trailer = forward ? queue.advance() : queue.goBack() {
            await play(trailer)
        } else if closingAfterLast {
            close()
        }
    }

    private func play(_ trailer: Trailer?) async {
        // The URL carries the token: it goes to AVPlayer and nowhere else.
        guard let trailer, let url = try? await session.mediaURL(trailer.path) else { return }
        let item = AVPlayerItem(url: url)
        item.externalMetadata = NowPlaying.metadata(for: trailer, of: detail.title, position: queue.position)
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = NotificationCenter.default.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification, object: item, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                Task { await self.move(forward: true, closingAfterLast: true) }
            }
        }
        player.replaceCurrentItem(with: item)
        player.play()
        showSkips()
        log.info("trailer \(trailer.id, privacy: .public) (\(trailer.kind.rawValue, privacy: .public)), \(self.queue.position.map { "\($0.number) of \($0.of)" } ?? "-", privacy: .public)")
    }

    /// Asks nectar once for each unready trailer, which starts its fetch, then reads the list again until they've
    /// landed or failed.
    private func fetchUnready() {
        let unready = queue.unready
        guard !unready.isEmpty else { return }
        fetching = Task { [weak self, session] in
            for trailer in unready {
                do { try await session.head(trailer.path) } catch { log.info("trailer \(trailer.id, privacy: .public) fetch not started: \(String(describing: error), privacy: .public)") }
            }
            for _ in 0 ..< Self.looks {
                try? await Task.sleep(for: Self.lookAgainEvery)
                guard let self, !Task.isCancelled else { return }
                await self.reread()
                if self.queue.unready.isEmpty { return }
            }
        }
    }

    private func reread() async {
        guard let fresh = try? await session.detail(detail.id) else { return }
        queue.refresh(with: fresh.trailers)
        showSkips()
    }

    /// AVKit shows a skip indicator only where there's a trailer to go to.
    private func showSkips() {
        guard let controller, controller.skippingBehavior == .skipItem else { return }
        controller.isSkipForwardEnabled = queue.next != nil
        controller.isSkipBackwardEnabled = queue.previous != nil
    }
}

struct TrailersView: UIViewControllerRepresentable {

    let model: TrailersModel

    func makeCoordinator() -> Coordinator {
        Coordinator(model: model)
    }

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        controller.player = model.player
        controller.delegate = context.coordinator
        model.attach(controller)
        return controller
    }

    func updateUIViewController(_ controller: AVPlayerViewController, context: Context) {}

    /// The remote's left and right, with skip-item behaviour on. AVKit calls its delegate on the main thread.
    final class Coordinator: NSObject, AVPlayerViewControllerDelegate {

        let model: TrailersModel

        init(model: TrailersModel) {
            self.model = model
        }

        func skipToNextItem(for playerViewController: AVPlayerViewController) {
            let model = model
            MainActor.assumeIsolated { model.skipForward() }
        }

        func skipToPreviousItem(for playerViewController: AVPlayerViewController) {
            let model = model
            MainActor.assumeIsolated { model.skipBack() }
        }
    }
}
