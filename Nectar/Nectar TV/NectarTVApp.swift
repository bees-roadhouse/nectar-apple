import AppIntents
import NectarKit
import SwiftUI

@main
struct NectarTVApp: App {

    @State
    private var model: AppModel
    /// Hands back pre-load downloads that finished while the app was away (#85).
    @UIApplicationDelegateAdaptor(AppDelegate.self)
    private var appDelegate

    init() {
        let model = AppModel()
        _model = State(initialValue: model)
        // Siri's intents (#77) follow their links through the same model the screen shows.
        AppDependencyManager.shared.add(dependency: model)
    }

    var body: some Scene {
        WindowGroup {
            Group {
                switch model.state {
                case .starting:
                    ProgressView()
                case let .signingIn(signIn):
                    SignInView(model: signIn)
                case let .signedIn(user, home):
                    SignedInView(user: user, home: home) { model.signOut() }
                        // A new identity for each followed link: whatever any tab had open closes, and Home presents it.
                        .id(model.linkGeneration)
                case .unreachable:
                    UnreachableView { await model.retry() }
                }
            }
            .task { await model.start() }
            .task { PreloadManager.shared.reconnect() }
            .onOpenURL { model.open($0) }
        }
    }
}
