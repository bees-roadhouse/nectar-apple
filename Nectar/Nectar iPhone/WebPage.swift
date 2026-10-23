import NectarKit
import UIKit
import WebKit

/// One of nectar's web pages inside the native frame (#156): a `WKWebView` as the page's content, with the bridge that
/// tells the page it's framed (`__NECTAR_SHELL__.frame = "native"`, Forage's frameless mode) and hears back where it
/// is. Its large title collapses off the web view's own scroll view, which is why the page must scroll the document.
@MainActor
final class WebPage: UIViewController, WKScriptMessageHandlerWithReply, WKNavigationDelegate {

    /// Where the page is, from the web's `shell.route`: kept so a reclaimed view comes back at the same place.
    struct Place: Equatable {
        var path: String
        var scrollY: Double = 0
    }

    let root: String
    private(set) var place: Place
    private let session: NectarSession
    private let signedOut: () -> Void
    private var web: WKWebView?
    private var snapshot: UIView?
    /// Watching the page's size until the person first drags it, to keep a page that's at the top at the top.
    private var sizeWatch: NSKeyValueObservation?
    private var dragged = false
    /// The scroll view's top inset under the large title, before a load collapses it: the page's true top.
    private var largeTop: CGFloat = 0

    /// One process pool and data store for every page, so they share the session's cookie and storage.
    private static let configurationBase: WKWebViewConfiguration = {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        configuration.allowsInlineMediaPlayback = true
        configuration.allowsPictureInPictureMediaPlayback = true
        configuration.mediaTypesRequiringUserActionForPlayback = []
        return configuration
    }()

    init(root: String, title: String, session: NectarSession, signedOut: @escaping () -> Void) {
        self.root = root
        place = Place(path: root)
        self.session = session
        self.signedOut = signedOut
        super.init(nibName: nil, bundle: nil)
        self.title = title
        navigationItem.largeTitleDisplayMode = .always
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not from a storyboard") }

    var isLive: Bool { web != nil }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor(red: 0x11 / 255, green: 0x12 / 255, blue: 0x14 / 255, alpha: 1)
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        guard web == nil else { return }
        // The web view goes in now, before the screen lays out, so UIKit has its scroll view for the large title from
        // the first frame (added later, after the token, the title collapsed on load: Capping, #159). The page loads
        // once the token is in hand.
        let web = makeWeb()
        Task { await start(web) }
    }

    // MARK: - Loading, reclaiming and coming back

    private func makeWeb() -> WKWebView {
        let configuration = Self.configurationBase.copy() as! WKWebViewConfiguration
        configuration.userContentController = WKUserContentController()
        configuration.userContentController.addScriptMessageHandler(self, contentWorld: .page, name: Bridge.handler)

        let web = WKWebView(frame: view.bounds, configuration: configuration)
        web.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        web.isOpaque = false
        web.backgroundColor = view.backgroundColor
        web.scrollView.backgroundColor = view.backgroundColor
        web.allowsBackForwardNavigationGestures = true
        // The bars' heights are the native side's (the frame contract): the scroll view is inset under them, so the
        // page starts below the large title and scrolls under the glass. WKWebView doesn't adjust on its own.
        web.scrollView.contentInsetAdjustmentBehavior = .always
        web.navigationDelegate = self
        view.insertSubview(web, at: 0)
        setContentScrollView(web.scrollView, for: .top)
        web.layoutIfNeeded()
        largeTop = web.scrollView.adjustedContentInset.top
        self.web = web
        dragged = false
        web.scrollView.panGestureRecognizer.addTarget(self, action: #selector(beganDragging))
        // UIKit shows the large title only with the scroll view at -adjustedContentInset.top, not at 0, where the page
        // puts itself whenever it lays out. Until the person drags, a page meant to be at the top is put back at the
        // true top each time its content changes size.
        sizeWatch = web.scrollView.observe(\.contentSize, options: [.new]) { [weak self] scroll, _ in
            MainActor.assumeIsolated { self?.keepAtTop(scroll) }
        }
        return web
    }

    /// The bridge, with the token for the page's first load, then the page.
    private func start(_ web: WKWebView) async {
        guard let token = try? await session.webToken() else { return signedOut() }
        guard self.web === web else { return }
        web.configuration.userContentController.addUserScript(WKUserScript(
            source: Bridge.script(origin: PhoneModel.server, token: token, device: UIDevice.current.model),
            injectionTime: .atDocumentStart, forMainFrameOnly: true))
        web.load(URLRequest(url: PhoneModel.server.appending(path: place.path)))
    }

    /// Gives the web view's process back, keeping where the page was and a picture of it for the return.
    func reclaim() {
        guard let web else { return }
        place.scrollY = web.scrollView.contentOffset.y + web.scrollView.adjustedContentInset.top
        if let picture = web.snapshotView(afterScreenUpdates: false) {
            picture.frame = view.bounds
            picture.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            snapshot?.removeFromSuperview()
            snapshot = picture
            view.addSubview(picture)
        }
        sizeWatch = nil
        web.configuration.userContentController.removeAllScriptMessageHandlers()
        web.removeFromSuperview()
        self.web = nil
    }

    /// Back at the same route and scroll: then the picture fades away over 200 ms (Capping, #156).
    private func settle() {
        guard let web, let snapshot else { return }
        let y = place.scrollY
        web.evaluateJavaScript("window.scrollTo(0, \(y))") { [weak self] _, _ in
            UIView.animate(withDuration: 0.2, animations: { snapshot.alpha = 0 }) { _ in
                snapshot.removeFromSuperview()
                if self?.snapshot === snapshot { self?.snapshot = nil }
            }
        }
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        // iOS took the page's process back while it was away: come back the same way as a reclaim.
        reclaim()
        if viewIfLoaded?.window != nil {
            let web = makeWeb()
            Task { await start(web) }
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        keepAtTop(webView.scrollView)
        if snapshot != nil, place.scrollY == 0 { settle() }
    }

    /// A load puts WKWebView at its own zero, which reads as scrolled under the large title and collapses it; going
    /// back to the large bar's top (past the collapsed one) is what makes UIKit open the title again.
    private func keepAtTop(_ scroll: UIScrollView) {
        let top = -max(largeTop, scroll.adjustedContentInset.top)
        guard !dragged, place.scrollY == 0, scroll.contentOffset.y > top else { return }
        scroll.setContentOffset(CGPoint(x: 0, y: top), animated: false)
    }

    @objc private func beganDragging(_ pan: UIPanGestureRecognizer) {
        if pan.state == .began {
            dragged = true
            sizeWatch = nil
        }
    }

    // MARK: - The tab bar's taps

    /// A re-tap of the active tab: to the tab's root, at the top.
    func backToRoot() {
        web?.evaluateJavaScript("window.__NECTAR_NAV__ ? window.__NECTAR_NAV__(\(Bridge.quoted(root))) : location.assign(\(Bridge.quoted(root)))")
        web?.scrollView.setContentOffset(CGPoint(x: 0, y: -(web?.scrollView.adjustedContentInset.top ?? 0)), animated: true)
    }

    @objc private func goBack() {
        web?.evaluateJavaScript("window.__NECTAR_BACK__ ? window.__NECTAR_BACK__() : history.back()")
    }

    // MARK: - The bridge

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) async -> (Any?, String?) {
        guard let body = message.body as? [String: Any], let kind = body["kind"] as? String else { return (nil, nil) }
        switch kind {
        case "refresh":
            // The page was refused with `stale`; the session refreshes once for every page.
            return ((try? await session.webToken(replacing: body["stale"] as? String)) as Any?, nil)
        case "signedOut":
            signedOut()
        case "route":
            heard(Bridge.Route(body))
        default:
            break
        }
        return (nil, nil)
    }

    private func heard(_ route: Bridge.Route) {
        place.path = route.path
        if let title = route.title, !title.isEmpty { self.title = title }
        navigationItem.leftBarButtonItem = route.canGoBack && !route.root
            ? UIBarButtonItem(image: UIImage(systemName: "chevron.backward"), style: .plain, target: self, action: #selector(goBack))
            : nil
        if snapshot != nil, route.path == place.path { settle() }
    }
}

/// The script every framed page gets before its own, and the shapes it sends back.
enum Bridge {

    static let handler = "nectar"

    struct Route {
        let path: String
        let title: String?
        let root: Bool
        let canGoBack: Bool

        init(_ body: [String: Any]) {
            path = body["path"] as? String ?? "/"
            title = body["title"] as? String
            root = body["root"] as? Bool ?? false
            canGoBack = body["canGoBack"] as? Bool ?? false
        }
    }

    /// The shell's `__NECTAR_SHELL__` (version 4: `frame` and `route`), the token for the page's first load, and the
    /// guard that hands nectar's own sign-in page back to the app (#144), on the server's origin only.
    static func script(origin: URL, token: String, device: String) -> String {
        """
        (() => {
          if (location.origin !== \(quoted(origin.absoluteString.trimmingCharacters(in: ["/"])))) return;
          const send = (body) => window.webkit.messageHandlers.\(handler).postMessage(body);
          try {
            if (!sessionStorage.getItem("nectar_token")) sessionStorage.setItem("nectar_token", \(quoted(token)));
          } catch (e) {}
          document.cookie = "nectar_session=" + encodeURIComponent(sessionStorage.getItem("nectar_token") || \(quoted(token))) + "; Path=/; SameSite=Lax";
          window.__NECTAR_SHELL__ = {
            version: 4,
            device: \(quoted(device)),
            nativeHls: true,
            frame: "native",
            refreshToken: () => send({ kind: "refresh", stale: (() => { try { return sessionStorage.getItem("nectar_token"); } catch (e) { return null; } })() }),
            signedOut: () => send({ kind: "signedOut" }),
            route: (route) => send(Object.assign({ kind: "route" }, route)),
          };
          const SIGN_IN = /^\\/(login|setup)(\\/|$)/;
          const away = () => {
            if (!SIGN_IN.test(location.pathname)) return;
            try { sessionStorage.removeItem("nectar_token"); } catch (e) {}
            document.cookie = "nectar_session=; Path=/; Max-Age=0; SameSite=Lax";
            send({ kind: "signedOut" });
          };
          for (const name of ["pushState", "replaceState"]) {
            const original = history[name].bind(history);
            history[name] = (...args) => { const result = original(...args); away(); return result; };
          }
          addEventListener("popstate", away);
          away();
        })();
        """
    }

    /// A string as a JavaScript literal.
    static func quoted(_ text: String) -> String {
        let data = try? JSONSerialization.data(withJSONObject: [text])
        let array = data.flatMap { String(data: $0, encoding: .utf8) } ?? "[\"\"]"
        return String(array.dropFirst().dropLast())
    }
}
