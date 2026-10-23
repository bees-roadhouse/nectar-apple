import NectarKit
import SwiftUI

/// "Approve this iPhone", to Capping's shape for the shell's code screen (#131, #144): on a phone the primary action
/// is signing in here, in the system sheet; the code is one line for another device, and a share sends the link.
struct SignInView: View {

    let model: SignInModel
    private let kind = UIDevice.current.model

    var body: some View {
        VStack(spacing: 0) {
            Spacer()
            Image("Lockup")
                .resizable()
                .scaledToFit()
                .frame(height: 44)
                .padding(.bottom, 28)
                .accessibilityLabel("nectar")
            switch model.phase {
            case .requestingCode:
                ProgressView().tint(.secondary)
            case let .waiting(authorization):
                waiting(authorization)
            case .declined:
                Text("The code was declined on the other device.").foregroundStyle(.secondary)
                Button("Get a new code") { model.run() }
                    .buttonStyle(Capsule(primary: false))
                    .padding(.top, 24)
            case let .failed(why):
                Text(why).foregroundStyle(.secondary)
                Button("Try again") { model.run() }
                    .buttonStyle(Capsule(primary: false))
                    .padding(.top, 24)
            }
            Spacer()
            Spacer()
        }
        .padding(.horizontal, 24)
        .frame(maxWidth: 520)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.brhNight)
        .onChange(of: model.phase) { _, phase in
            if case .waiting = phase {} else { WebAuth.shared.close() }
        }
        .onDisappear { WebAuth.shared.close() }
    }

    private func waiting(_ authorization: DeviceAuthorization) -> some View {
        let link = authorization.verificationURIComplete ?? authorization.verificationURI
        return VStack(spacing: 0) {
            Text("Approve this \(kind)")
                .font(.largeTitle.bold())
                .multilineTextAlignment(.center)
                .padding(.bottom, 12)
            Button("Sign in on this \(kind)") { WebAuth.shared.open(link) }
                .buttonStyle(Capsule(primary: true))
                .padding(.vertical, 12)
            (Text("Or enter ") + Text(authorization.userCode).bold() + Text(" on a device that's signed in."))
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.bottom, 8)
            Label("Waiting for approval…", systemImage: "circle.fill")
                .labelStyle(Waiting())
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(.bottom, 16)
            // The approval link, with the code in it, to the Mac or another phone (#148).
            ShareLink("Send this code to another device", item: link)
                .font(.callout)
                .frame(minHeight: 44)
        }
    }
}

/// The capsule rule from page 2451's media-app variant: gold with gold-ink lettering, or the card with a dim line.
private struct Capsule: ButtonStyle {
    let primary: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .foregroundStyle(primary ? Color.brhGoldInk : .primary)
            .frame(maxWidth: .infinity, minHeight: 48)
            .background(primary ? Color.brhGold : Color.brhCard, in: .capsule)
            .overlay { if !primary { SwiftUI.Capsule().stroke(Color.brhLineDim) } }
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.snappy(duration: 0.2), value: configuration.isPressed)
    }
}

/// A gold dot that breathes beside "Waiting for approval…", still under Reduce Motion.
private struct Waiting: LabelStyle {
    @Environment(\.accessibilityReduceMotion)
    private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 10) {
            Circle().fill(Color.brhGold).frame(width: 8, height: 8)
                .phaseAnimator(reduceMotion ? [1.0] : [1.0, 0.25]) { dot, opacity in dot.opacity(opacity) } animation: { _ in .easeInOut(duration: 0.9) }
            configuration.title
        }
    }
}

extension Color {
    /// The Brand & Visual Identity Standard's media-app roles (KB page 2451), as the shell's launch page uses them.
    static let brhNight = Color(red: 0x11 / 255, green: 0x12 / 255, blue: 0x14 / 255)
    static let brhCard = Color(red: 0x1D / 255, green: 0x20 / 255, blue: 0x24 / 255)
    static let brhLineDim = Color(red: 0x2A / 255, green: 0x2D / 255, blue: 0x32 / 255)
    static let brhGold = Color(red: 0xE8 / 255, green: 0xA0 / 255, blue: 0x3A / 255)
    static let brhGoldInk = Color(red: 0x1A / 255, green: 0x14 / 255, blue: 0x07 / 255)
}
