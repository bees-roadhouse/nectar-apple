import NectarKit
import SwiftUI
import UIKit

/// The native frame (#156): the system tab bar with Home · Library · Search · Discover · More, a navigation controller
/// per tab with large titles, and nectar's web as each tab's content. At most three web views stay alive (#156's
/// engineering note); the least recently seen gives its process back and comes back as if it never left.
@MainActor
final class Frame: UITabBarController, UITabBarControllerDelegate {

    private static let liveLimit = 3

    private let session: NectarSession
    private let signedOut: () -> Void
    /// The web pages most recently seen first, for choosing which to reclaim.
    private var recent: [WebPage] = []

    init(session: NectarSession, signedOut: @escaping () -> Void) {
        self.session = session
        self.signedOut = signedOut
        super.init(nibName: nil, bundle: nil)
        delegate = self
        let tabs: [(String, String, String)] = [
            ("Home", "house", "/"),
            ("Library", "square.grid.2x2", "/movies"),
            ("Search", "magnifyingglass", "/search"),
            ("Discover", "sparkles", "/discover"),
        ]
        var stacks: [UINavigationController] = tabs.map { title, symbol, path in
            stack(WebPage(root: path, title: title, session: session, signedOut: signedOut), title: title, symbol: symbol)
        }
        stacks.append(stack(More(open: { [weak self] row in self?.open(row) }), title: "More", symbol: "ellipsis"))
        setViewControllers(stacks, animated: false)
        tabBar.tintColor = UIColor(red: 0xE8 / 255, green: 0xA0 / 255, blue: 0x3A / 255, alpha: 1)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not from a storyboard") }

    private func stack(_ root: UIViewController, title: String, symbol: String) -> UINavigationController {
        let stack = UINavigationController(rootViewController: root)
        stack.navigationBar.prefersLargeTitles = true
        stack.tabBarItem = UITabBarItem(title: title, image: UIImage(systemName: symbol), selectedImage: nil)
        stack.delegate = self
        return stack
    }

    /// A More row: its web page pushed onto More's stack, with the system's swipe back.
    private func open(_ row: More.Row) {
        let page = WebPage(root: row.path, title: row.title, session: session, signedOut: signedOut)
        (viewControllers?.last as? UINavigationController)?.pushViewController(page, animated: true)
    }

    /// A page came on screen: it's the most recent, and anything past the limit gives its process back.
    fileprivate func seen(_ page: WebPage) {
        recent.removeAll { $0 === page }
        recent.insert(page, at: 0)
        for older in recent.dropFirst(Self.liveLimit) where older.isLive {
            older.reclaim()
        }
        recent.removeAll { $0.parent == nil && $0.navigationController == nil }
    }

    func tabBarController(_ tabBarController: UITabBarController, shouldSelect viewController: UIViewController) -> Bool {
        // A re-tap of the active tab goes to its root, at the top, as the system's own apps do.
        if viewController === selectedViewController,
           let page = (viewController as? UINavigationController)?.topViewController as? WebPage {
            page.backToRoot()
        }
        return true
    }
}

extension Frame: UINavigationControllerDelegate {
    func navigationController(_ navigationController: UINavigationController, didShow viewController: UIViewController, animated: Bool) {
        if let page = viewController as? WebPage { seen(page) }
    }
}

/// More: the pages that aren't tabs, as the system's own list.
@MainActor
final class More: UITableViewController {

    struct Row {
        let title: String
        let symbol: String
        let path: String
    }

    private let rows = [
        Row(title: "Playlists", symbol: "music.note.list", path: "/playlists"),
        Row(title: "Collections", symbol: "rectangle.stack", path: "/collections"),
        Row(title: "Requests", symbol: "tray.and.arrow.down", path: "/requests"),
        Row(title: "Activity", symbol: "clock.arrow.circlepath", path: "/activity"),
        Row(title: "Settings", symbol: "gearshape", path: "/settings"),
    ]
    private let open: (Row) -> Void

    init(open: @escaping (Row) -> Void) {
        self.open = open
        super.init(style: .insetGrouped)
        title = "More"
        navigationItem.largeTitleDisplayMode = .always
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not from a storyboard") }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { rows.count }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
        var content = cell.defaultContentConfiguration()
        content.text = rows[indexPath.row].title
        content.image = UIImage(systemName: rows[indexPath.row].symbol)
        cell.contentConfiguration = content
        cell.accessoryType = .disclosureIndicator
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        open(rows[indexPath.row])
    }
}

/// The frame, for SwiftUI's scene.
struct FrameView: UIViewControllerRepresentable {
    let session: NectarSession
    let signedOut: () -> Void

    func makeUIViewController(context: Context) -> Frame { Frame(session: session, signedOut: signedOut) }
    func updateUIViewController(_ frame: Frame, context: Context) {}
}
