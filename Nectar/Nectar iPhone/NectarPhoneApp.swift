import AVFoundation
import NectarKit
import SwiftUI

/// Nectar for iPhone (#156): the native frame around nectar's web, sharing NectarKit with Nectar TV.
@main
struct NectarPhoneApp: App {

    @State
    private var model = PhoneModel()

    init() {
        // Playback, so nectar's sound keeps going with the phone locked or another app in front.
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
    }

    var body: some Scene {
        WindowGroup {
            Group {
                switch model.state {
                case .starting:
                    // The stored sign-in is checked in a moment: the night, never a spinner (Capping, #158).
                    Color.brhNight.ignoresSafeArea()
                case let .signingIn(signIn):
                    SignInView(model: signIn)
                case let .signedIn(session):
                    FrameView(session: session) { model.signOut() }
                        .ignoresSafeArea()
                case .unreachable:
                    VStack(spacing: 16) {
                        Text("Can't reach nectar right now.").foregroundStyle(.secondary)
                        Button("Try again") { Task { await model.retry() } }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.brhNight)
                }
            }
            .preferredColorScheme(.dark)
            .tint(.brhGold)
            .task { await model.start() }
        }
    }
}
