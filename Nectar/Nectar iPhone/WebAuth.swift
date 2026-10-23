import AuthenticationServices
import UIKit

/// The system sign-in sheet over the app, for approving this phone's code on the phone itself (#144, ported from the
/// shell). nectar's `/activate` has no callback to return through, so the code's poll ends it: `close()` when the
/// sign-in finishes, whichever device approved.
@MainActor
final class WebAuth: NSObject, ASWebAuthenticationPresentationContextProviding {

    static let shared = WebAuth()

    private var session: ASWebAuthenticationSession?

    func open(_ url: URL) {
        close()
        // A scheme nothing opens: the sheet only ever ends by being closed, here or by the person.
        let session = ASWebAuthenticationSession(url: url, callback: .customScheme("nectar-unused")) { [weak self] _, _ in
            self?.session = nil
        }
        session.presentationContextProvider = self
        // Not ephemeral, so Safari's saved nectar password, passkey and session carry over.
        session.prefersEphemeralWebBrowserSession = false
        self.session = session
        session.start()
    }

    func close() {
        session?.cancel()
        session = nil
    }

    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        MainActor.assumeIsolated {
            UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.keyWindow }.first ?? ASPresentationAnchor()
        }
    }
}
