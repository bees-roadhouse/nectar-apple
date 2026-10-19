import AVFoundation
import Foundation
import NectarKit
import OSLog
import VideoToolbox

/// What playback did, for checking on a device: never a URL, so never the token in it.
private let log = Logger(subsystem: "com.beesroadhouse.nectar.tv", category: "playback")

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
    private var itemStatusObservation: NSKeyValueObservation?
    private var lastReported: Double = -1
    private var started: ContinuousClock.Instant?
    /// AVPlayer starts out paused; only a pause after playing is the viewer's.
    private var hasPlayed = false

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
        let started = ContinuousClock.now
        log.info("play \(self.card.id, privacy: .public) resume=\(resume, privacy: .public)s hevc=\(Self.capabilities.videoCodecs.contains("hevc"), privacy: .public)")
        do {
            let decision = try await session.decide(card.id, capabilities: Self.capabilities, startOffset: resume > 0 ? resume : nil)
            log.info("decide \(decision.strategy.rawValue, privacy: .public) \(decision.playMethod ?? "-", privacy: .public) reason=\(decision.reason ?? "-", privacy: .public) start_offset=\(decision.startOffsetSeconds, privacy: .public)s audio=\(decision.audioStreamIndex.map(String.init) ?? "file default", privacy: .public) because \(String(describing: decision.audioReason), privacy: .public) after \(started.duration(to: .now), privacy: .public)")
            // The URL carries the access token: it goes to AVPlayer and nowhere else.
            let player = AVPlayer(url: try await session.mediaURL(decision.streamPath))
            let seek = decision.seek(toResumeAt: resume)
            if seek > 0 {
                await player.seek(to: CMTime(seconds: seek, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .positiveInfinity)
            }
            observe(player, decision)
            phase = .playing(player, decision)
            player.play()
            self.started = started
        } catch {
            log.error("play failed: \(String(describing: error), privacy: .public)")
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
        itemStatusObservation = nil
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
            let status = player.timeControlStatus
            Task { @MainActor in
                guard let self else { return }
                if status == .playing, !self.hasPlayed { self.logAudio(player) }
                if status == .playing { self.hasPlayed = true }
                if status == .playing, let started = self.started {
                    log.info("playing at \(self.position(of: player, decision), privacy: .public)s (player time \(player.currentTime().seconds, privacy: .public)s), \(started.duration(to: .now), privacy: .public) after select")
                    self.started = nil
                }
                if status == .paused, self.hasPlayed {
                    self.report(self.position(of: player, decision), paused: true, force: true)
                }
            }
        }
        if let item = player.currentItem {
            itemStatusObservation = item.observe(\.status) { item, _ in
                if item.status == .failed {
                    log.error("player item failed: \(String(describing: item.error), privacy: .public)")
                }
            }
        }
    }

    /// Which audio tracks AVPlayer was offered and which it chose; the default-language question (Nate, 2026-10-18).
    private func logAudio(_ player: AVPlayer) {
        guard let item = player.currentItem else { return }
        Task {
            guard let group = try? await item.asset.loadMediaSelectionGroup(for: .audible) else {
                log.info("audio: no selection group (one track muxed in)")
                return
            }
            let describe: (AVMediaSelectionOption) -> String = { "\($0.displayName) [\($0.extendedLanguageTag ?? "und")]" }
            let offered = group.options.map(describe).joined(separator: ", ")
            let chosen = item.currentMediaSelection.selectedMediaOption(in: group).map(describe) ?? "none"
            log.info("audio: chose \(chosen, privacy: .public) of \(offered, privacy: .public)")
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
        Task {
            do {
                try await session.reportProgress(itemID, positionSeconds: position, paused: paused, completed: completed)
                log.info("progress \(position, privacy: .public)s paused=\(paused, privacy: .public) completed=\(completed ?? false, privacy: .public) saved")
            } catch {
                log.error("progress \(position, privacy: .public)s not saved: \(String(describing: error), privacy: .public)")
            }
        }
    }
}
