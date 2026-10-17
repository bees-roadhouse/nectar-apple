import NectarKit
import SwiftUI

/// Slice 1's home: proof of who is signed in. Rows of media arrive in slice 2.
struct HomeView: View {

    let user: NectarUser
    let signOut: () -> Void

    var body: some View {
        VStack(spacing: 40) {
            Text("Signed in as \(user.username)")
                .font(.largeTitle.bold())
            Button("Sign out", action: signOut)
        }
    }
}
