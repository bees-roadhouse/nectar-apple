import NectarKit
import SwiftUI

/// The signed-in app: the tvOS top tab bar over Home, a tab per library, Discover and Playlists.
struct SignedInView: View {

    let user: NectarUser
    let home: HomeModel
    let signOut: () -> Void

    @State
    private var discover: DiscoverModel
    @State
    private var playlists: PlaylistsModel
    /// Every library this user can see, each its own tab, as nectar lists them; none until it answers.
    @State
    private var libraries: [Library] = []

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
            ForEach(libraries) { library in
                Tab(library.name, systemImage: library.kind.symbol) {
                    LibraryView(library: library, session: home.session)
                }
            }
            Tab("Discover", systemImage: "sparkles") {
                DiscoverView(model: discover)
            }
            Tab("Playlists", systemImage: "music.note.list") {
                PlaylistsView(model: playlists)
            }
        }
        .task {
            libraries = (try? await home.session.libraries()) ?? []
        }
    }
}
