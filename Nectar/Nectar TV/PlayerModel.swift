import AVFoundation
import Foundation
import NectarKit
import VideoToolbox

/// One title playing: ask nectar how, open what it answers, resume, and keep nectar told where we are.
@MainActor
@Observable
final class PlayerModel: Identifiable {

    enum Phase {
        case deciding
        case playing(AVPlayer, PlaybackDecision)
        case failed(String)
    }

    nonisolated let id: String
    let card: MediaCard
    private(set) var phase: Phase = .deciding

    private let session: NectarSession
    private var timeObserver: Any?
    private var statusObservation: NSKeyValueObservation?
    private var lastReported: Double = -1

    /// How often progress goes to nectar while playing.
    private static let reportEvery: Double = 10

    init(card: MediaCard, session: NectarSession) {
        id = card.id
        self.card = card
        self.session = session
    }

    /// AVPlayer on this device, HEVC only when the hardware decodes it (an Apple TV 4K yes, the simulator no).
    static var capabilities: PlaybackCapabilities {
        .avPlayer(hevcHardwareDecode: VTIsHardwareDecodeSupported(kCMVideoCodecType_HEVC))
    }

    func start() async {
        guard case .deciding = phase else { return }
        let resume = card.progressSeconds ?? 0
        do {
            let decision = try await session.decide(card.id, capabilities: Self.capabilities, startOffset: resume > 0 ? resume : nil)
            // The URL carries the access token: it goes to AVPlayer and nowhere else.
            let player = AVPlayer(url: try await session.mediaURL(decision.streamPath))
            let seek = decision.seek(toResumeAt: resume)
            if seek > 0 {
                await player.seek(to: CMTime(seconds: seek, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .positiveInfinity)
            }
            observe(player, decision)
            phase = .playing(player, decision)
            player.play()
        } catch {
            phase = .failed("Couldn't start this title.")
        }
    }

    /// The player is going away: say where it stopped, and whether that's the end.
    func stop() {
        guard case let .playing(player, decision) = phase else { return }
        player.pause()
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        timeObserver = nil
        statusObservation = nil
        let position = position(of: player, decision)
        let duration = decision.durationSeconds ?? card.runtimeSeconds
        let completed = duration.map { position >= $0 * 0.95 } ?? false
        report(position, paused: true, completed: completed ? true : nil, force: true)
    }

    // MARK: - Progress

    private func observe(_ player: AVPlayer, _ decision: PlaybackDecision) {
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: Self.reportEvery, preferredTimescale: 1), queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.report(self.position(of: player, decision), paused: false)
            }
        }
        statusObservation = player.observe(\.timeControlStatus) { [weak self] player, _ in
            guard player.timeControlStatus == .paused else { return }
            Task { @MainActor in
                guard let self else { return }
                self.report(self.position(of: player, decision), paused: true, force: true)
            }
        }
    }

    /// Where the title is, in the title's own seconds: an HLS stream starts at its offset.
    private func position(of player: AVPlayer, _ decision: PlaybackDecision) -> Double {
        let seconds = player.currentTime().seconds
        guard seconds.isFinite else { return card.progressSeconds ?? 0 }
        return seconds + (decision.strategy == .hls ? decision.startOffsetSeconds : 0)
    }

    private func report(_ position: Double, paused: Bool, completed: Bool? = nil, force: Bool = false) {
        guard force || abs(position - lastReported) >= 1 else { return }
        lastReported = position
        let session = session, itemID = card.id
        Task { try? await session.reportProgress(itemID, positionSeconds: position, paused: paused, completed: completed) }
    }
}
