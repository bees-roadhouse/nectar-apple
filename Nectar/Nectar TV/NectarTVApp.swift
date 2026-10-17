import NectarKit
import SwiftUI

@main
struct NectarTVApp: App {

    @State
    private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            Group {
                switch model.state {
                case .starting:
                    ProgressView()
                case let .signingIn(signIn):
                    SignInView(model: signIn)
                case let .signedIn(user):
                    HomeView(user: user) { model.signOut() }
                }
            }
            .task { await model.start() }
        }
    }
}
