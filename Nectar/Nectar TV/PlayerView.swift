import AVKit
import NectarKit
import SwiftUI

/// Full screen: the system player, so the Siri Remote, the transport bar and the info panel behave as on any Apple TV app.
struct PlayerView: View {

    let model: PlayerModel
    let dismiss: () -> Void

    @State
    private var showsMethod = true

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.ignoresSafeArea()

            switch model.phase {
            case .deciding:
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case let .playing(player, decision):
                SystemPlayer(player: player)
                    .ignoresSafeArea()
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
                Text(reason.replacingOccurrences(of: "_", with: " "))
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
        switch decision.playMethod {
        case "DirectPlay": "Direct play"
        case "DirectStream": "Remux"
        case "Transcode": "Transcode"
        default: decision.strategy == .direct ? "Direct play" : "Streaming"
        }
    }
}

private struct SystemPlayer: UIViewControllerRepresentable {

    let player: AVPlayer

    /// The player model sets the item's metadata (Now Playing, #42); the controller publishes it.
    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        controller.player = player
        return controller
    }

    func updateUIViewController(_ controller: AVPlayerViewController, context: Context) {}
}
