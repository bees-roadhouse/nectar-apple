import AVKit
import NectarKit
import SwiftUI

/// Full screen: the system player, so the Siri Remote, the transport bar and the info panel behave as on any Apple TV app.
struct PlayerView: View {

    let model: PlayerModel
    let dismiss: () -> Void

    @State
    private var showsMethod = true
    @Environment(\.isAdmin)
    private var isAdmin

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.ignoresSafeArea()

            switch model.phase {
            case .deciding:
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case let .playing(player, decision):
                SystemPlayer(
                    player: player,
                    info: isAdmin ? PlaybackInfoPanel(model: model, player: player) : nil,
                    // An image track plays only burned, so while burns are off there's nothing to offer.
                    imageTracks: PlayerModel.burnsEnabled ? model.subtitles.filter(\.burnOnly) : [],
                    burnedID: model.burned?.id
                ) { track in
                    Task { await model.switchSubtitle(burning: track) }
                }
                .ignoresSafeArea()
                // A burned stream being swapped in: the last frame holds under the system spinner (Capping's spec).
                if model.switching {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                // Where tvOS shows its own passing notices: a capsule at the top centre, clear of the transport
                // bar, never in the title's metadata, never focusable (Capping's spec on #98).
                if let notice = model.notice {
                    Label {
                        Text(notice.text).foregroundStyle(.primary)
                    } icon: {
                        Image(systemName: notice.isFailure ? "exclamationmark.triangle.fill" : "captions.bubble.fill")
                            .foregroundStyle(notice.isFailure ? .red : .secondary)
                    }
                    .font(.callout)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 12)
                    .background(.ultraThinMaterial, in: Capsule())
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .padding(.top, 60)
                    .allowsHitTesting(false)
                    .transition(.opacity)
                }
                if showsMethod {
                    MethodBadge(decision: decision)
                        .padding(60)
                        .transition(.opacity)
                }
            case let .failed(message):
                VStack(spacing: 32) {
                    Text(message).font(.title2)
                    Button("Back", action: dismiss)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        // The notice fades in and out: opacity only, so it's the same under Reduce Motion.
        .animation(.easeInOut(duration: 0.3), value: model.notice)
        .task {
            await model.start()
            // How nectar is playing it, long enough to read, then out of the picture.
            try? await Task.sleep(for: .seconds(6))
            withAnimation { showsMethod = false }
        }
        .onDisappear { model.stop() }
    }
}

/// "Direct play", "Remux" or "Transcode", and why it isn't the tier above (#4, #8).
private struct MethodBadge: View {

    let decision: PlaybackDecision

    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            Text(label).font(.headline)
            if let reason = decision.reason, decision.playMethod != "DirectPlay" {
                Text(PlaybackInfo.reason(reason))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let audio {
                Text(audio)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    /// Why this audio, when nectar chose by preference; quiet when it's simply the file's default.
    private var audio: String? {
        switch decision.audioReason {
        case .preferredLanguage: "Audio in your language"
        case .originalLanguage: "Audio in the original language"
        case .requested: "The audio you chose"
        case .fileDefault, .first, .other, nil: nil
        }
    }

    private var label: String {
        PlaybackInfo.method(decision)
    }
}

private struct SystemPlayer: UIViewControllerRepresentable {

    let player: AVPlayer
    /// An admin's Playback tab in the info panel (#82); nil for everyone else.
    let info: PlaybackInfoPanel?
    /// Image tracks (PGS, VobSub): AVKit can't list them, so they get "More subtitles" (#97). None, no menu.
    let imageTracks: [SubtitleTrack]
    /// The image track burned into the current stream, checked in the menu.
    let burnedID: String?
    /// Burn a track, or nil for Off.
    let burn: (SubtitleTrack?) -> Void

    /// The player model sets the item's metadata (Now Playing, #42); the controller publishes it.
    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        controller.player = player
        if let info {
            let tab = UIHostingController(rootView: info)
            tab.title = "Playback"
            tab.preferredContentSize = CGSize(width: 0, height: 280)
            controller.customInfoViewControllers = [tab]
        }
        controller.transportBarCustomMenuItems = moreSubtitles
        return controller
    }

    /// A burned stream replaces the player; the menu's checkmark follows what's burned.
    func updateUIViewController(_ controller: AVPlayerViewController, context: Context) {
        if controller.player !== player { controller.player = player }
        controller.transportBarCustomMenuItems = moreSubtitles
    }

    /// One transport-bar item after AVKit's own, only when the title has image tracks: Off, then each by its
    /// language (Capping's spec on #97). Text tracks stay in AVKit's Subtitles menu.
    private var moreSubtitles: [UIMenuElement] {
        guard !imageTracks.isEmpty else { return [] }
        let off = UIAction(title: "Off", state: burnedID == nil ? .on : .off) { _ in burn(nil) }
        let rows = imageTracks.map { track in
            UIAction(title: track.menuTitle(), state: burnedID == track.id ? .on : .off) { _ in burn(track) }
        }
        return [UIMenu(title: "More subtitles", image: UIImage(systemName: "captions.bubble.fill"), children: [off] + rows)]
    }
}
