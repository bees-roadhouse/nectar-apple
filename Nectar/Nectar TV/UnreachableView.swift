import SwiftUI

/// nectar didn't answer at launch. The sign-in is kept; this only offers to ask again.
struct UnreachableView: View {

    let retry: () async -> Void

    var body: some View {
        VStack(spacing: 40) {
            Text("Can't reach Nectar")
                .font(.largeTitle.bold())
            Text("You're still signed in. Nectar may be restarting; try again in a moment.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Try again") {
                Task { await retry() }
            }
        }
        .padding(80)
    }
}
