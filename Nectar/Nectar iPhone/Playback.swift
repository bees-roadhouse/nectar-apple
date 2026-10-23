import AVKit
import MediaPlayer
import NectarKit
import SwiftUI

/// What's playing, app-wide (#157): one player, shown full screen as the system's own or minimised to the dock above
/// the tab bar, so Home and the title pages keep working under it. The TV app's `PlayerModel` decides, plays and
/// reports progress; a queue runs a season through.
@MainActor
@Observable
final class Playback {

    let session: NectarSession
    private(set) var current: PlayerModel?
    /// Full screen, or the mini player on the dock.
    var expanded = false
    /// The rest of a season after the current episode.
    private var queue: [MediaCard] = []
    /// Told when a title or a queue ends, so the screen that started it can refresh its rows and marks.
    private var ended: (() -> Void)?

    init(session: NectarSession) {
        self.session = session
    }

    func play(_ model: PlayerModel, then ended: (() -> Void)? = nil) {
        stopCurrent()
        queue = []
        self.ended = ended
        begin(model)
    }

    func play(_ queue: PlayQueue, then ended: (() -> Void)? = nil) {
        guard let first = queue.cards.first else { return }
        stopCurrent()
        self.queue = Array(queue.cards.dropFirst())
        self.ended = ended
        begin(PlayerModel(card: first, session: session))
    }

    /// Close: the player stops, says goodbye and saves the place.
    func close() {
        stopCurrent()
        queue = []
        expanded = false
        ended?()
        ended = nil
    }

    private func begin(_ model: PlayerModel) {
        model.finished = { [weak self] in self?.next() }
        current = model
        expanded = true
        Task { await model.start() }
    }

    private func next() {
        guard !queue.isEmpty else { return close() }
        let card = queue.removeFirst()
        current?.stop()
        begin(PlayerModel(card: card, session: session))
    }

    private func stopCurrent() {
        current?.stop()
        current = nil
    }
}

/// The system's player, full screen, for whatever `Playback` has: its controls, PiP, AirPlay and track menus, nothing
/// of ours over them. Dismissing it minimises to the dock; it doesn't stop.
@MainActor
final class FullPlayer: AVPlayerViewController {

    private let playback: Playback
    private var failure: UIHostingController<Failure>?

    init(playback: Playback) {
        self.playback = playback
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .fullScreen
        allowsPictureInPicturePlayback = true
        canStartPictureInPictureAutomaticallyFromInline = true
        updatesNowPlayingInfoCenter = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not from a storyboard") }

    override func viewDidLoad() {
        super.viewDidLoad()
        follow()
    }

    /// Follows the model: the player once decided, the one-thing error if it failed.
    private func follow() {
        withObservationTracking {
            show(playback.current?.phase)
        } onChange: { [weak self] in
            Task { @MainActor in self?.follow() }
        }
    }

    private func show(_ phase: PlayerModel.Phase?) {
        switch phase {
        case let .playing(player, _):
            if self.player !== player { self.player = player }
            failure?.view.removeFromSuperview()
            failure = nil
        case let .failed(why):
            player = nil
            guard failure == nil, let overlay = contentOverlayView else { return }
            let host = UIHostingController(rootView: Failure(why: why.why ?? "This title can't be played right now.") { [weak self] in
                self?.playback.close()
            })
            host.view.backgroundColor = .clear
            host.view.frame = overlay.bounds
            host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            overlay.addSubview(host.view)
            failure = host
        default:
            break
        }
    }

    /// Whether it was playing as the dismissal began: the system pauses its player on the way out.
    private var wasPlaying = false

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        wasPlaying = (player?.rate ?? 0) > 0
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        // Gone by the system's close or a swipe down: down to the dock, still playing.
        guard isBeingDismissed || presentingViewController == nil else { return }
        if playback.expanded { playback.expanded = false }
        // The system pauses after this returns, so play on the next beat.
        guard wasPlaying, let player else { return }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(150))
            if player.rate == 0 { player.play() }
        }
    }
}

/// A title that can't be played: one sentence from the server's reason, one way out, over the player's black.
private struct Failure: View {
    let why: String
    let close: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Text(PlaybackFailure.headline).font(.headline)
            Text(why).font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
            Button("Close", action: close).buttonStyle(CapsuleStyle(primary: true))
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black)
    }
}

/// The mini player on the dock (#157): 64 pt on the bar's material, the live picture, the title and a line under it,
/// Play/Pause and Close, and the gold hairline along the top. Tap or drag up to expand; swipe down to close.
struct MiniPlayer: View {
    let playback: Playback

    @State
    private var drag: CGFloat = 0
    @Environment(\.accessibilityReduceMotion)
    private var reduceMotion

    var body: some View {
        if let model = playback.current {
            TimelineView(.periodic(from: .now, by: 1)) { _ in
                bar(model)
            }
            .offset(y: max(drag, -24))
            .gesture(
                DragGesture(minimumDistance: 8)
                    .onChanged { drag = $0.translation.height }
                    .onEnded { end in
                        let throwDown = end.predictedEndTranslation.height
                        withAnimation(reduceMotion ? .easeOut(duration: 0.2) : snappy) {
                            drag = 0
                            if end.translation.height < -40 { playback.expanded = true }
                            if throwDown > 80 { playback.close() }
                        }
                    }
            )
        }
    }

    private func bar(_ model: PlayerModel) -> some View {
        let playing: (AVPlayer, PlaybackDecision)? = if case let .playing(player, decision) = model.phase { (player, decision) } else { nil }
        let player = playing?.0
        let (position, duration) = times(playing, model)
        return HStack(spacing: 12) {
            PictureView(player: player)
                .frame(width: 71, height: 40)
                .background(Color.black)
                .clipShape(.rect(cornerRadius: 6))
            VStack(alignment: .leading, spacing: 1) {
                Text(model.card.title ?? "Untitled").font(.subheadline.weight(.semibold)).lineLimit(1)
                Text(secondLine(model, player: player, position: position, duration: duration))
                    .font(.footnote).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
            Button {
                guard let player else { return }
                if player.rate > 0 { player.pause() } else { player.play() }
            } label: {
                Image(systemName: (player?.rate ?? 0) > 0 ? "pause.fill" : "play.fill").font(.title3).frame(width: 44, height: 44)
            }
            .accessibilityLabel((player?.rate ?? 0) > 0 ? "Pause" : "Play")
            Button { playback.close() } label: {
                Image(systemName: "xmark").font(.body.weight(.semibold)).frame(width: 44, height: 44)
            }
            .accessibilityLabel("Close")
        }
        .foregroundStyle(.primary)
        .padding(.horizontal, 12)
        .frame(height: 64)
        .background(.bar, in: .rect(cornerRadius: 16))
        .overlay(alignment: .top) {
            GeometryReader { box in
                Rectangle().fill(Color.brhGold)
                    .frame(width: duration > 0 ? box.size.width * min(position / duration, 1) : 0, height: 2)
            }
            .frame(height: 2)
            .padding(.horizontal, 12)
        }
        .overlay { RoundedRectangle(cornerRadius: 16).stroke(Color.brhLineDim) }
        .contentShape(.rect)
        .onTapGesture { playback.expanded = true }
        .accessibilityAction(named: "Expand") { playback.expanded = true }
    }

    /// Where it is in the title's own seconds: a transcode's stream starts at its resume offset, as the model counts.
    private func times(_ playing: (AVPlayer, PlaybackDecision)?, _ model: PlayerModel) -> (Double, Double) {
        guard let (player, decision) = playing else { return (model.card.progressSeconds ?? 0, model.card.runtimeSeconds ?? 0) }
        let offset = decision.strategy == .hls ? decision.startOffsetSeconds : 0
        let raw = player.currentTime().seconds
        let stream = player.currentItem?.duration.seconds ?? .nan
        let duration = model.card.runtimeSeconds ?? (stream.isFinite ? stream + offset : 0)
        return ((raw.isFinite ? raw : 0) + offset, duration)
    }

    /// The show and episode, or the time left; "Converting for this phone" while a transcode starts.
    private func secondLine(_ model: PlayerModel, player: AVPlayer?, position: Double, duration: Double) -> String {
        if player == nil {
            if case .failed = model.phase { return "Couldn't play" }
            return "Converting for this phone"
        }
        if let series = model.card.seriesTitle { return series }
        guard duration > position, duration > 0 else { return "" }
        return "\(Durations.duration(duration - position)) left"
    }
}

/// The live picture at thumbnail size.
private struct PictureView: UIViewRepresentable {
    let player: AVPlayer?

    func makeUIView(context: Context) -> PlayerLayerView { PlayerLayerView() }

    func updateUIView(_ view: PlayerLayerView, context: Context) {
        if view.playerLayer.player !== player { view.playerLayer.player = player }
    }

    final class PlayerLayerView: UIView {
        override class var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }

        override init(frame: CGRect) {
            super.init(frame: frame)
            playerLayer.videoGravity = .resizeAspectFill
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("not from a storyboard") }
    }
}
