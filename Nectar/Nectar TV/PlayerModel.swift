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
    /// What the file is, once the item route answers: for Playback info (#82).
    private(set) var source: PlaybackSource?

    private let session: NectarSession
    private var timeObserver: Any?
    private var statusObservation: NSKeyValueObservation?
    private var itemStatusObservation: NSKeyValueObservation?
    private var lastReported: Double = -1
    private var started: ContinuousClock.Instant?
    /// AVPlayer starts out paused; only a pause after playing is the viewer's.
    private var hasPlayed = false
    private var endObserver: NSObjectProtocol?
    private var startDeadline: Task<Void, Never>?
    /// Every subtitle the title carries or sits beside (#97); the image tracks among them make "More subtitles".
    private(set) var subtitles: [SubtitleTrack] = []
    /// The image track drawn into the current stream, if one is.
    private(set) var burned: SubtitleTrack?
    /// A burned stream being swapped in: the last frame holds under a spinner meanwhile.
    private(set) var switching = false
    /// One line over the picture: a subtitle that couldn't be had, or one that's coming. Playback carries on.
    struct Notice: Equatable {
        let text: String
        /// A failure shows the error glyph; anything else is news.
        let isFailure: Bool
    }

    private(set) var notice: Notice?
    /// A notice decided before anything plays, shown with the first frame so it isn't spent on a spinner.
    private var noticeAtStart: Notice?
    /// A burned start that never showed a frame has fallen back to the unburned stream; a second failure is final.
    private var fellBack = false
    /// The rendition to select once the stream is ready: the person's default, or the AVKit track picked while burned.
    private var pendingRendition: String?
    private var selectionObserver: NSObjectProtocol?
    /// Called when the title plays to its end; a playlist moves on to the next.
    var finished: (() -> Void)?

    /// How often progress goes to nectar while playing.
    private static let reportEvery: Double = 10

    /// How long AVPlayer may wait to start, with no first frame, before the TV says so (#91). It can wait forever,
    /// never failing, when the server answers the playlists but not the media; real starts on the TV take under 5 s.
    /// A cold transcode of a 4K source took 52 s to its first segment (nectar #644), and AVPlayer gave up on it at
    /// 43 s by itself. Only waiting counts: a start the system paused (a screensaver over the app, the app in the
    /// background) is not a failure, and on the TV that pause looked like one.
    private static let firstFrameDeadline: Duration = .seconds(45)

    /// A burned start gets less. A DVD burn shows its first frame in about 5 s, and a 4K one never keeps up (nectar
    /// #644); the fallback plays the film unburned, so waiting the full deadline would only hold the film back.
    private static let burnedStartDeadline: Duration = .seconds(15)

    init(card: MediaCard, session: NectarSession) {
        id = card.id
        self.card = card
        self.session = session
    }

    /// AVPlayer on this device, HEVC only when the hardware decodes it (an Apple TV 4K yes, the simulator no).
    /// The poster width Now Playing hands the system; pre-loading warms the cache at this width too (#85).
    static let nowPlayingArtworkWidth: Double = 600

    static var capabilities: PlaybackCapabilities {
        .avPlayer(hevcHardwareDecode: VTIsHardwareDecodeSupported(kCMVideoCodecType_HEVC))
    }

    func start() async {
        guard case .deciding = phase else { return }
        let resume = card.progressSeconds ?? 0
        let started = ContinuousClock.now
        log.info("play \(self.card.id, privacy: .public) resume=\(resume, privacy: .public)s hevc=\(Self.capabilities.videoCodecs.contains("hevc"), privacy: .public)")
        // Pre-loaded (#85): the TV's own copy plays without asking nectar how to send it.
        if let file = PreloadManager.shared.store.file(for: card.id) {
            log.info("playing the pre-loaded copy")
            let decision = PlaybackDecision.local(file)
            let player = AVPlayer(url: file)
            if resume > 0 {
                await player.seek(to: CMTime(seconds: resume, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .positiveInfinity)
            }
            observe(player, decision)
            phase = .playing(player, decision)
            player.play()
            describe(player.currentItem)
            self.started = started
            PreloadManager.shared.store.markPlayed(card.id)
            return
        }
        do {
            async let tracks = try? session.subtitles(card.id)
            var decision = try await session.decide(card.id, capabilities: Self.capabilities, startOffset: resume > 0 ? resume : nil)
            subtitles = await tracks ?? []
            decision = await applyDefault(to: decision, resume: resume)
            log.info("decide \(decision.strategy.rawValue, privacy: .public) \(decision.playMethod ?? "-", privacy: .public) reason=\(decision.reason ?? "-", privacy: .public) start_offset=\(decision.startOffsetSeconds, privacy: .public)s audio=\(decision.audioStreamIndex.map(String.init) ?? "file default", privacy: .public) because \(String(describing: decision.audioReason), privacy: .public) after \(started.duration(to: .now), privacy: .public)")
            try await begin(decision, at: resume)
            self.started = started
        } catch {
            log.error("play failed: \(String(describing: error), privacy: .public)")
            phase = .failed("Couldn't start this title.")
        }
    }

    /// What the system's player surfaces show (#42): the info panel, Control Center, a paired iPhone. The card's
    /// title at once; the overview, genres, rating and poster when nectar and the image cache answer, without
    /// holding up the first frame.
    private func describe(_ item: AVPlayerItem?) {
        guard let item else { return }
        item.externalMetadata = NowPlaying.metadata(for: card, detail: nil, artwork: nil)
        let session = session, card = card
        Task { [weak self, weak item] in
            async let detail = try? session.detail(card.id)
            let poster = session.resolve(card.posterPath, pixelWidth: Self.nowPlayingArtworkWidth)
            let artwork = await (poster != nil ? try? ImageCache.shared.data(for: poster!) : nil)
            let fetched = await detail
            let full = NowPlaying.metadata(for: card, detail: fetched, artwork: artwork)
            await MainActor.run {
                item?.externalMetadata = full
                self?.source = fetched?.source
            }
        }
    }

    /// Opens what nectar decided at the resume point and plays it.
    private func begin(_ decision: PlaybackDecision, at resume: Double) async throws {
        // The URL carries the access token: it goes to AVPlayer and nowhere else.
        let player = AVPlayer(url: try await session.mediaURL(decision.streamPath))
        let seek = decision.seek(toResumeAt: resume)
        if seek > 0 {
            await player.seek(to: CMTime(seconds: seek, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .positiveInfinity)
        }
        observe(player, decision)
        phase = .playing(player, decision)
        player.play()
        describe(player.currentItem)
    }

    /// The player is going away: say where it stopped, and whether that's the end.
    func stop() {
        guard case let .playing(player, decision) = phase else { return }
        tearDown(player)
        let position = position(of: player, decision)
        let duration = decision.durationSeconds ?? card.runtimeSeconds
        let completed = duration.map { position >= $0 * 0.95 } ?? false
        report(position, paused: true, completed: completed ? true : nil, force: true)
    }

    /// AVPlayer gave up on the item, or never started it (#91): say so, instead of leaving a dead player on screen.
    /// Where it had got to is saved as a stop would save it; a start that never played reports nothing, so the old
    /// resume point stands.
    private func failed() {
        guard case let .playing(player, _) = phase else { return }
        if let track = burned, !hasPlayed, !fellBack {
            tearDown(player)
            Task { await playUnburned(instead: track) }
            return
        }
        if hasPlayed {
            stop()
        } else {
            tearDown(player)
        }
        phase = .failed("Couldn't play this title.")
    }

    /// A burned start that never showed a frame (a burn nectar can't encode in time, nectar #644): the title plays
    /// unburned rather than not at all, and says which subtitles it couldn't show.
    private func playUnburned(instead track: SubtitleTrack) async {
        fellBack = true
        burned = nil
        phase = .deciding
        let resume = card.progressSeconds ?? 0
        log.error("subtitles: the stream burning \(track.label, privacy: .public) never started; playing unburned")
        do {
            let decision = try await session.decide(card.id, capabilities: Self.capabilities, startOffset: resume > 0 ? resume : nil, subtitle: .off)
            started = .now
            noticeAtStart = Notice(text: "Couldn't turn on \(track.menuTitle()) subtitles", isFailure: true)
            try await begin(decision, at: resume)
        } catch {
            log.error("play failed: \(String(describing: error), privacy: .public)")
            phase = .failed("Couldn't play this title.")
        }
    }

    /// One line over the picture for about 4 s (Capping's spec on #98).
    private func show(_ shown: Notice) {
        notice = shown
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            if self?.notice == shown { self?.notice = nil }
        }
    }

    private func tearDown(_ player: AVPlayer) {
        startDeadline?.cancel()
        startDeadline = nil
        player.pause()
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        timeObserver = nil
        statusObservation = nil
        itemStatusObservation = nil
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = nil
        if let selectionObserver { NotificationCenter.default.removeObserver(selectionObserver) }
        selectionObserver = nil
    }

    // MARK: - Progress

    /// Runs the first-frame deadline while AVPlayer is waiting to start, and stops it when it plays or is paused.
    private func waitingToStart(_ waiting: Bool, _ player: AVPlayer) {
        guard waiting else {
            startDeadline?.cancel()
            startDeadline = nil
            return
        }
        guard startDeadline == nil else { return }
        let deadline = burned != nil ? Self.burnedStartDeadline : Self.firstFrameDeadline
        startDeadline = Task { [weak self, weak player] in
            try? await Task.sleep(for: deadline)
            guard let self, let player, !Task.isCancelled, !self.hasPlayed else { return }
            log.error("no first frame after \(deadline, privacy: .public) of waiting: \(player.reasonForWaitingToPlay?.rawValue ?? "-", privacy: .public), item status \(player.currentItem?.status.rawValue ?? -1, privacy: .public)")
            self.failed()
        }
    }

    private func observe(_ player: AVPlayer, _ decision: PlaybackDecision) {
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: Self.reportEvery, preferredTimescale: 1), queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.report(self.position(of: player, decision), paused: false)
            }
        }
        if let item = player.currentItem {
            endObserver = NotificationCenter.default.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification, object: item, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.finished?() }
            }
        }
        statusObservation = player.observe(\.timeControlStatus) { [weak self] player, _ in
            let status = player.timeControlStatus
            Task { @MainActor in
                guard let self else { return }
                self.waitingToStart(status == .waitingToPlayAtSpecifiedRate && !self.hasPlayed, player)
                if status == .playing, !self.hasPlayed {
                    self.logAudio(player)
                    if let shown = self.noticeAtStart {
                        self.noticeAtStart = nil
                        self.show(shown)
                    }
                }
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
            itemStatusObservation = item.observe(\.status) { [weak self] item, _ in
                if item.status == .readyToPlay {
                    Task { @MainActor in await self?.applySubtitles(item) }
                    return
                }
                guard item.status == .failed else { return }
                log.error("player item failed: \(String(describing: item.error), privacy: .public)")
                Task { @MainActor in self?.failed() }
            }
            selectionObserver = NotificationCenter.default.addObserver(forName: AVPlayerItem.mediaSelectionDidChangeNotification, object: item, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.selectionChanged(item) }
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

    // MARK: - Subtitles (#97, Capping's spec)

    /// The person's default does the work at start: their language as an image track only is burned from the
    /// first frame (by nectar in the same answer since #627, else by a second decide before anything plays); as a
    /// text track, AVKit's rendition is selected once the stream is ready. A burn that can't be had plays the
    /// stream unburned rather than not at all.
    private func applyDefault(to decision: PlaybackDecision, resume: Double) async -> PlaybackDecision {
        switch SubtitleStart.plan(decision, subtitles) {
        case .none:
            return decision
        case let .burned(track):
            burned = track
            log.info("subtitles: nectar burned the default \(track.label, privacy: .public) from the first frame")
            return decision
        case let .rendition(track):
            pendingRendition = track.label
            log.info("subtitles: the default is the rendition \(track.label, privacy: .public)")
            return decision
        case let .declined(track, declined):
            log.info("subtitles: nectar declined burning \(track?.label ?? "stream \(declined.streamIndex)", privacy: .public): \(declined.message, privacy: .public); OCR \(String(describing: declined.ocr), privacy: .public)")
            if let track {
                noticeAtStart = declined.ocr == .queued
                    ? Notice(text: "\(track.menuTitle()) subtitles will be ready next time", isFailure: false)
                    : Notice(text: "Couldn't turn on \(track.menuTitle()) subtitles", isFailure: true)
            }
            return decision
        case let .burn(track):
            do {
                let burnedDecision = try await session.decide(card.id, capabilities: Self.capabilities, startOffset: resume > 0 ? resume : nil, subtitle: .burn(track))
                burned = track
                log.info("subtitles: the default \(track.label, privacy: .public) is an image track, burned from the first frame")
                return burnedDecision
            } catch {
                log.error("subtitles: burning the default failed, playing unburned: \(String(describing: error), privacy: .public)")
                return decision
            }
        }
    }

    /// The stream is ready: one subtitle at a time. A burned stream shows no AVKit rendition; otherwise the
    /// pending rendition (the default, or a text track chosen while burned) is selected by its track.
    private func applySubtitles(_ item: AVPlayerItem) async {
        guard let group = try? await item.asset.loadMediaSelectionGroup(for: .legible) else {
            log.info("subtitles: the stream offers no legible group")
            return
        }
        var options: [SubtitleOption] = []
        for option in group.options {
            options.append(SubtitleOption(name: await Self.renditionName(option), language: option.extendedLanguageTag, forced: option.hasMediaCharacteristic(.containsOnlyForcedSubtitles)))
        }
        log.info("subtitles: AVKit offers \(options.map { "\($0.name) [\($0.language ?? "und")\($0.forced ? ", forced" : "")]" }.joined(separator: ", "), privacy: .public)")
        if burned != nil {
            if group.allowsEmptySelection { item.select(nil, in: group) }
            return
        }
        guard let name = pendingRendition else { return }
        pendingRendition = nil
        let wanted = subtitles.first { $0.label == name } ?? SubtitleTrack(id: name, kind: .other("chosen"), label: name)
        guard let index = wanted.option(among: options) else {
            log.info("subtitles: no rendition matches \(name, privacy: .public)")
            return
        }
        item.select(group.options[index], in: group)
        log.info("subtitles: selected \(options[index].name, privacy: .public)")
    }

    /// An HLS rendition's `NAME`, which nectar sets to the track's label. AVFoundation exposes it as the option's
    /// common-metadata title; `displayName` is only the localized language ("Chinese" for three Chinese renditions).
    private static func renditionName(_ option: AVMediaSelectionOption) async -> String {
        let title = option.commonMetadata.first { $0.commonKey == .commonKeyTitle }
        let name = try? await title?.load(.stringValue)
        return name ?? option.displayName
    }

    /// AVKit's own menu changed the selection. While a track is burned, a text track chosen there means the
    /// unburned stream with that rendition: the two menus never show two subtitles at once.
    private func selectionChanged(_ item: AVPlayerItem) {
        guard burned != nil, !switching, let group = item.asset.mediaSelectionGroup(forMediaCharacteristic: .legible),
              let chosen = item.currentMediaSelection.selectedMediaOption(in: group) else { return }
        Task {
            let name = await Self.renditionName(chosen)
            log.info("subtitles: \(name, privacy: .public) chosen in AVKit's menu while burned; back to the unburned stream")
            await switchSubtitle(burning: nil, thenSelect: name)
        }
    }

    /// "More subtitles": an image track burned in, or Off. The picture holds on its last frame under a spinner
    /// until the new stream is ready at the same position; if it can't be had, the old stream carries on.
    func switchSubtitle(burning track: SubtitleTrack?, thenSelect rendition: String? = nil) async {
        guard case let .playing(old, oldDecision) = phase, !switching, track?.id != burned?.id || rendition != nil else { return }
        switching = true
        notice = nil
        defer { switching = false }
        let at = position(of: old, oldDecision)
        old.pause()
        do {
            let decision = try await session.decide(card.id, capabilities: Self.capabilities, startOffset: at, subtitle: track.map { .burn($0) } ?? .off)
            let player = AVPlayer(url: try await session.mediaURL(decision.streamPath))
            try await Self.ready(player, within: Self.switchDeadline)
            await player.seek(to: CMTime(seconds: decision.seek(toResumeAt: at), preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
            tearDown(old)
            burned = track
            pendingRendition = rendition
            observe(player, decision)
            phase = .playing(player, decision)
            player.play()
            describe(player.currentItem)
            if let item = player.currentItem, item.status == .readyToPlay { await applySubtitles(item) }
            log.info("subtitles: switched to \(track?.label ?? "unburned", privacy: .public) at \(at, privacy: .public)s")
        } catch {
            log.error("subtitles: switch to \(track?.label ?? "unburned", privacy: .public) failed: \(String(describing: error), privacy: .public)")
            show(Notice(text: track.map { "Couldn't turn on \($0.menuTitle()) subtitles" } ?? "Couldn't turn off subtitles", isFailure: true))
            old.play()
        }
    }

    /// How long a burned stream may take to be ready before the switch gives up and the old stream carries on:
    /// a burn is a transcode, a DVD burn starts in about 3 s, and a 4K one in 52 s (nectar #644), which this
    /// deliberately doesn't wait out: the picture is held meanwhile, and a 4K burn can't keep up once it starts.
    private static let switchDeadline: Duration = .seconds(40)

    private struct NotReady: Error {}

    /// Waits for the player's item to be ready to play, or throws.
    private static func ready(_ player: AVPlayer, within deadline: Duration) async throws {
        guard let item = player.currentItem else { throw NotReady() }
        let clock = ContinuousClock.now
        while clock.duration(to: .now) < deadline {
            switch item.status {
            case .readyToPlay: return
            case .failed: throw item.error ?? NotReady()
            default: try await Task.sleep(for: .milliseconds(100))
            }
        }
        throw NotReady()
    }
}
