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
    /// The app's one player, and its mini player on the dock above the tab bar (#157).
    let playback: Playback
    private lazy var dock = UIHostingController(rootView: MiniPlayer(playback: playback))
    private static let dockHeight: CGFloat = 64
    /// The full player for what's playing, kept so picture in picture comes back to the same controller.
    private var full: FullPlayer?
    /// The web pages most recently seen first, for choosing which to reclaim.
    private var recent: [WebPage] = []

    init(session: NectarSession, signedOut: @escaping () -> Void) {
        self.session = session
        self.signedOut = signedOut
        playback = Playback(session: session)
        super.init(nibName: nil, bundle: nil)
        delegate = self
        // Home, Library and Search are native (#158); Discover is web until its native screen lands.
        var stacks: [UINavigationController] = [
            stack(home(), title: "Home", symbol: "house"),
            stack(library(), title: "Library", symbol: "rectangle.stack"),
            stack(search(), title: "Search", symbol: "magnifyingglass"),
        ]
        stacks.append(stack(WebPage(root: "/discover", title: "Discover", session: session, signedOut: signedOut), title: "Discover", symbol: "sparkles"))
        stacks.append(stack(More(session: session, open: { [weak self] row in self?.open(row) }, signOut: signedOut), title: "More", symbol: "ellipsis"))
        setViewControllers(stacks, animated: false)
        tabBar.tintColor = UIColor(red: 0xE8 / 255, green: 0xA0 / 255, blue: 0x3A / 255, alpha: 1)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not from a storyboard") }

    override func viewDidLoad() {
        super.viewDidLoad()
        addChild(dock)
        dock.view.backgroundColor = .clear
        view.addSubview(dock.view)
        dock.didMove(toParent: self)
        followPlayback()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        dock.view.frame = CGRect(x: 8, y: tabBar.frame.minY - Self.dockHeight - 8, width: view.bounds.width - 16, height: Self.dockHeight)
        view.bringSubviewToFront(dock.view)
    }

    /// The dock shows while something plays and isn't full screen; the full player comes and goes with `expanded`.
    private func followPlayback() {
        withObservationTracking {
            arrange(playing: playback.current != nil, expanded: playback.expanded, floating: playback.pictureInPicture)
        } onChange: { [weak self] in
            Task { @MainActor in self?.followPlayback() }
        }
    }

    private func arrange(playing: Bool, expanded: Bool, floating: Bool) {
        let docked = playing && !expanded && !floating
        dock.view.isHidden = !docked
        // Every tab's content clears the dock while it's there.
        for stack in viewControllers ?? [] {
            stack.additionalSafeAreaInsets.bottom = docked ? Self.dockHeight + 8 : 0
        }
        if !playing { full = nil }
        // The player goes over whatever is up (a sheet, a menu, an active search), or it would be expanded with
        // nowhere to show, and the dock hidden for it.
        var top: UIViewController = self
        while let next = top.presentedViewController, !(next is FullPlayer) { top = next }
        let shown = top.presentedViewController as? FullPlayer
        if expanded, playing, shown == nil {
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            top.present(fullPlayer(), animated: true)
        } else if !expanded || !playing, let shown, !shown.isBeingDismissed {
            shown.dismiss(animated: true)
        }
    }

    /// One full player per title, so a title back from picture in picture returns to the controller that has it.
    private func fullPlayer() -> FullPlayer {
        if let full { return full }
        let made = FullPlayer(playback: playback)
        made.restore = { [weak self] player, done in
            guard let self else { return done() }
            // Whatever is up (a sheet, a menu) makes way for the player.
            let present = { self.present(player, animated: true) { self.playback.expanded = true; done() } }
            if let presented = presentedViewController, presented !== player {
                presented.dismiss(animated: false, completion: present)
            } else {
                present()
            }
        }
        full = made
        return made
    }

    private func stack(_ root: UIViewController, title: String, symbol: String) -> UINavigationController {
        let stack = UINavigationController(rootViewController: root)
        stack.navigationBar.prefersLargeTitles = true
        stack.tabBarItem = UITabBarItem(title: title, image: UIImage(systemName: symbol), selectedImage: nil)
        stack.delegate = self
        return stack
    }

    private func home() -> UIViewController {
        let model = HomeModel(session: session, signedOut: signedOut)
        let screen = UIHostingController(rootView: HomeScreen(
            model: model,
            playback: playback,
            open: { [weak self] card in self?.title(card, onTab: 0) },
            openDiscover: { [weak self] _ in self?.push(path: "/discover", title: "Discover", onTab: 0) },
            seeAll: { [weak self] shelf in
                // "recent-<library>" opens the library, "genre-<name>" the genre, as web pages until theirs are native.
                if shelf.id.hasPrefix("recent-") {
                    self?.push(path: "/library/\(shelf.id.dropFirst("recent-".count))", title: shelf.title, onTab: 0)
                } else if shelf.id.hasPrefix("genre-") {
                    let name = String(shelf.id.dropFirst("genre-".count))
                    self?.push(path: "/genre/\(name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? name)", title: name, onTab: 0)
                }
            }
        ))
        screen.title = "Home"
        screen.navigationItem.largeTitleDisplayMode = .always
        return screen
    }

    private func library() -> UIViewController {
        let screen = UIHostingController(rootView: LibraryScreen(session: session, open: { [weak self] card in self?.show(card, onTab: 1) }))
        screen.title = "Library"
        screen.navigationItem.largeTitleDisplayMode = .always
        return screen
    }

    private func search() -> UIViewController {
        let model = SearchModel(session: session)
        let screen = SearchController(model: model, screen: SearchScreen(
            model: model,
            playback: playback,
            open: { [weak self] card in self?.show(card, onTab: 2) },
            openGenre: { [weak self] name in
                self?.push(path: "/genre/\(name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? name)", title: name, onTab: 2)
            },
            openCollection: { [weak self] collection in
                self?.push(path: "/collection/\(collection.id)", title: collection.name, onTab: 2)
            }
        ))
        screen.title = "Search"
        screen.navigationItem.largeTitleDisplayMode = .always
        return screen
    }

    /// A card opened from a tab: films and series have their native page; an album, a song or a book is the web's
    /// until its own lands.
    private func show(_ card: MediaCard, onTab tab: Int) {
        if card.itemType == "movie" || card.itemType == "series" {
            title(card, onTab: tab)
        } else {
            push(path: "/item/\(card.id)", title: card.title ?? "", onTab: tab)
        }
    }

    /// A title's native page (#158), pushed onto a tab's stack: the bar transparent over its hero, the system's bar with
    /// the name once the hero scrolls away.
    private func title(_ card: MediaCard, onTab tab: Int) {
        guard let stack = viewControllers?[tab] as? UINavigationController else { return }
        let model = ItemDetailModel(id: card.id, session: session, playlistAdding: PlaylistAdding(session: session))
        let screen = UIHostingController(rootView: TitleScreen(
            model: model,
            playback: playback,
            open: { [weak self] card in self?.title(card, onTab: tab) },
            openPerson: { [weak self] person in self?.push(path: "/person/\(person.id)", title: person.name, onTab: tab) },
            back: { [weak stack] in _ = stack?.popViewController(animated: true) }
        ))
        screen.title = card.title
        screen.navigationItem.largeTitleDisplayMode = .never
        let clear = UINavigationBarAppearance()
        clear.configureWithTransparentBackground()
        clear.titleTextAttributes = [.foregroundColor: UIColor.clear]
        screen.navigationItem.scrollEdgeAppearance = clear
        stack.pushViewController(screen, animated: true)
    }

    /// A web page pushed onto a tab's stack, until its native screen lands.
    private func push(path: String, title: String, onTab tab: Int) {
        let page = WebPage(root: path, title: title, session: session, signedOut: signedOut)
        page.navigationItem.largeTitleDisplayMode = .never
        (viewControllers?[tab] as? UINavigationController)?.pushViewController(page, animated: true)
    }

    /// A More row: its web page pushed onto More's stack, with the system's swipe back.
    private func open(_ row: More.Row) {
        guard row.path != More.scan else { return scan() }
        let page = WebPage(root: row.path, title: row.title, session: session, signedOut: signedOut)
        (viewControllers?.last as? UINavigationController)?.pushViewController(page, animated: true)
    }

    /// The camera over everything; an accepted code opens nectar's approve page on More, where the person confirms.
    private func scan() {
        Task {
            let base = await session.baseURL
            let origin = "\(base.scheme ?? "https")://\(base.host() ?? "")" + (base.port.map { ":\($0)" } ?? "")
            NectarScanner.scan(from: self, origin: origin) { [weak self] link in
                guard let self, let link, let url = URLComponents(string: link) else { return }
                let path = url.path + (url.query.map { "?\($0)" } ?? "")
                let page = WebPage(root: path, title: "Approve", session: session, signedOut: signedOut)
                (viewControllers?.last as? UINavigationController)?.pushViewController(page, animated: true)
            }
        }
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

    /// The row that opens the camera rather than a page.
    static let scan = "scan:"

    private let session: NectarSession
    private let open: (Row) -> Void
    private let signOut: () -> Void
    private var user: NectarUser?

    private var groups: [[Row]] {
        [
            [
                Row(title: user?.username ?? "Account", symbol: "person.crop.circle", path: "/settings/account"),
                // The camera, for another device's sign-in code (#167): the TV's or a desktop's QR.
                Row(title: "Scan a code", symbol: "qrcode.viewfinder", path: More.scan),
            ],
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
        if indexPath.section == 0, indexPath.row == 0, let initial = user?.username.first {
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
