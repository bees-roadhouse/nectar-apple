import CoreImage.CIFilterBuiltins
import NectarKit
import SwiftUI

/// The only way to sign in on the TV: a code to approve on a phone. No username or password here.
struct SignInView: View {

    let model: SignInModel

    var body: some View {
        VStack(spacing: 48) {
            Text("Sign in to Nectar")
                .font(.largeTitle.bold())

            switch model.phase {
            case .requestingCode:
                ProgressView()
            case let .waiting(authorization):
                waiting(authorization)
            case .declined:
                message("Sign-in was declined on your phone.")
            case let .failed(reason):
                message(reason)
            }
        }
        .padding(80)
    }

    private func waiting(_ authorization: DeviceAuthorization) -> some View {
        HStack(alignment: .center, spacing: 96) {
            if let image = QRCode.image(for: authorization.verificationURIComplete ?? authorization.verificationURI) {
                Image(uiImage: image)
                    .interpolation(.none)
                    .resizable()
                    .frame(width: 360, height: 360)
                    .accessibilityLabel("QR code to approve this TV")
            }

            VStack(alignment: .leading, spacing: 24) {
                Text("Scan the code with your phone, or go to")
                    .foregroundStyle(.secondary)
                Text(Self.typeable(authorization.verificationURI))
                    .font(.title2.weight(.semibold))
                Text("and enter")
                    .foregroundStyle(.secondary)
                Text(authorization.userCode)
                    .font(.system(size: 88, weight: .bold, design: .monospaced))
                    .accessibilityLabel(authorization.userCode.map(String.init).joined(separator: " "))
            }
        }
    }

    /// The address as someone would type it on a phone: host (and port) plus path, no scheme.
    static func typeable(_ url: URL) -> String {
        guard let host = url.host() else { return url.absoluteString }
        let port = url.port.map { ":\($0)" } ?? ""
        return host + port + (url.path() == "/" ? "" : url.path())
    }

    private func message(_ text: String) -> some View {
        VStack(spacing: 32) {
            Text(text)
            Button("Get a new code") { model.run() }
        }
    }
}

enum QRCode {

    static func image(for url: URL) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(url.absoluteString.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 12, y: 12)),
              let cgImage = CIContext().createCGImage(output, from: output.extent)
        else { return nil }
        return UIImage(cgImage: cgImage)
    }
}
