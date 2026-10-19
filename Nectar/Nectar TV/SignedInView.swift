import NectarKit
import SwiftUI

/// The signed-in app: the tvOS top tab bar over Home and Discover.
struct SignedInView: View {

    let user: NectarUser
    let home: HomeModel
    let signOut: () -> Void

    @State
    private var discover: DiscoverModel
    @State
    private var playlists: PlaylistsModel

    init(user: NectarUser, home: HomeModel, signOut: @escaping () -> Void) {
        self.user = user
        self.home = home
        self.signOut = signOut
        _discover = State(initialValue: DiscoverModel(session: home.session))
        _playlists = State(initialValue: PlaylistsModel(session: home.session))
    }

    var body: some View {
        TabView {
            Tab("Home", systemImage: "house") {
                HomeView(user: user, model: home, signOut: signOut)
            }
            Tab("Discover", systemImage: "sparkles") {
                DiscoverView(model: discover)
            }
            Tab("Playlists", systemImage: "music.note.list") {
                PlaylistsView(model: playlists)
            }
        }
    }
}
