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
            ("Library", "rectangle.stack", "/movies"),
            ("Search", "magnifyingglass", "/search"),
            ("Discover", "sparkles", "/discover"),
        ]
        var stacks: [UINavigationController] = tabs.map { title, symbol, path in
            stack(WebPage(root: path, title: title, session: session, signedOut: signedOut), title: title, symbol: symbol)
        }
        stacks.append(stack(More(session: session, open: { [weak self] row in self?.open(row) }, signOut: signedOut), title: "More", symbol: "ellipsis"))
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
    func seen(_ page: WebPage) {
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

/// More: what isn't a tab, and what the web's header carried before frame mode took it away (Capping, #159), as the
/// system's inset groups: the account, the collections of things, requests and activity, the Console and Settings, and
/// Sign out.
@MainActor
final class More: UITableViewController {

    struct Row {
        let title: String
        let symbol: String
        let path: String
    }

    private let session: NectarSession
    private let open: (Row) -> Void
    private let signOut: () -> Void
    private var user: NectarUser?

    private var groups: [[Row]] {
        [
            [Row(title: user?.username ?? "Account", symbol: "person.crop.circle", path: "/settings/account")],
            [
                Row(title: "Playlists", symbol: "music.note.list", path: "/playlists"),
                Row(title: "Collections", symbol: "square.stack", path: "/collections"),
                Row(title: "People", symbol: "person.2", path: "/people"),
                Row(title: "Genres", symbol: "tag", path: "/genres"),
            ],
            [
                Row(title: "Requests", symbol: "tray.and.arrow.down", path: "/requests"),
                Row(title: "Activity", symbol: "clock.arrow.circlepath", path: "/activity"),
            ],
            (user?.isAdmin == true ? [Row(title: "Console", symbol: "slider.horizontal.3", path: "/console")] : [])
                + [Row(title: "Settings", symbol: "gearshape", path: "/settings")],
        ]
    }

    init(session: NectarSession, open: @escaping (Row) -> Void, signOut: @escaping () -> Void) {
        self.session = session
        self.open = open
        self.signOut = signOut
        super.init(style: .insetGrouped)
        title = "More"
        navigationItem.largeTitleDisplayMode = .always
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not from a storyboard") }

    override func viewDidLoad() {
        super.viewDidLoad()
        Task {
            user = try? await session.currentUser()
            tableView.reloadData()
        }
    }

    override func numberOfSections(in tableView: UITableView) -> Int { groups.count + 1 }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        section < groups.count ? groups[section].count : 1
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
        var content = cell.defaultContentConfiguration()
        guard indexPath.section < groups.count else {
            content.text = "Sign out"
            content.textProperties.color = .systemRed
            content.image = UIImage(systemName: "rectangle.portrait.and.arrow.right")
            content.imageProperties.tintColor = .systemRed
            cell.contentConfiguration = content
            return cell
        }
        let row = groups[indexPath.section][indexPath.row]
        content.text = row.title
        if indexPath.section == 0, let initial = user?.username.first {
            // The account: the gold initial, as the web's header showed it.
            content.image = Self.initial(String(initial).uppercased())
        } else {
            content.image = UIImage(systemName: row.symbol)
        }
        cell.contentConfiguration = content
        cell.accessoryType = .disclosureIndicator
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard indexPath.section < groups.count else { return signOut() }
        open(groups[indexPath.section][indexPath.row])
    }

    /// A gold disc with the account's initial, at the row's image size.
    private static func initial(_ letter: String) -> UIImage {
        let size = CGSize(width: 29, height: 29)
        return UIGraphicsImageRenderer(size: size).image { _ in
            UIColor(red: 0xE8 / 255, green: 0xA0 / 255, blue: 0x3A / 255, alpha: 1).setFill()
            UIBezierPath(ovalIn: CGRect(origin: .zero, size: size)).fill()
            let text = letter as NSString
            let attributes: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 15, weight: .semibold),
                .foregroundColor: UIColor(red: 0x1A / 255, green: 0x14 / 255, blue: 0x07 / 255, alpha: 1),
            ]
            let box = text.size(withAttributes: attributes)
            text.draw(at: CGPoint(x: (size.width - box.width) / 2, y: (size.height - box.height) / 2), withAttributes: attributes)
        }
    }
}

/// The frame, for SwiftUI's scene.
struct FrameView: UIViewControllerRepresentable {
    let session: NectarSession
    let signedOut: () -> Void

    func makeUIViewController(context: Context) -> Frame { Frame(session: session, signedOut: signedOut) }
    func updateUIViewController(_ frame: Frame, context: Context) {}
}
