import NectarKit
import SwiftUI

/// Nectar for iPhone (#156): the native frame around nectar's web, sharing NectarKit with Nectar TV.
@main
struct NectarPhoneApp: App {

    @State
    private var model = PhoneModel()

    var body: some Scene {
        WindowGroup {
            Group {
                switch model.state {
                case .starting:
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity).background(Color.brhNight)
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
