import Foundation
import Security

/// What Nectar's Top Shelf shows (#74): the app builds it from Home and hands it to the extension, which only
/// reads it. The extension never calls nectar, because refresh tokens rotate and a second process refreshing
/// could get the TV signed out. nectar's images need no token, so the system fetches the URLs itself.
public struct TopShelfFeed: Codable, Equatable, Sendable {

    public struct Item: Codable, Equatable, Sendable {
        public let id: String
        public let title: String
        public let image: URL?
        /// How far through, 0...1, for the bar under a wide tile.
        public let progress: Double?
        /// Selecting the tile.
        public let open: URL
        /// The remote's play button on it.
        public let play: URL
    }

    /// Continue Watching, drawn wide, most recent first.
    public let watching: [Item]
    /// The newest films and series, drawn as posters.
    public let new: [Item]

    public var isEmpty: Bool {
        watching.isEmpty && new.isEmpty
    }

    /// Ten in each section: the shelf scrolls, but past ten it's a library, not a shelf.
    static let perSection = 10
    /// The widths Home's rows ask for on a 4K TV (a 480pt card, a 240pt poster), so nectar serves copies it already made.
    static let wideWidth: Double = 960
    static let posterWidth: Double = 480

    /// Continue Watching resumes on either button, as its row on Home does. A film new to the shelf opens its
    /// detail and plays on the play button; a series opens on both, since which episode is the detail's call.
    public static func make(watching: [MediaCard], recent: [MediaCard], resolve: (String?, Double) -> URL?) -> TopShelfFeed {
        let resuming = watching.prefix(perSection).map { card in
            Item(id: card.id, title: title(of: card), image: resolve(card.artworkPath, wideWidth), progress: card.progress,
                 open: NectarLink.play(card.id).url, play: NectarLink.play(card.id).url)
        }
        let seen = Set(watching.map(\.id))
        let fresh = recent
            .filter { ($0.itemType == "movie" || $0.itemType == "series") && !seen.contains($0.id) }
            .prefix(perSection)
            .map { card in
                Item(id: card.id, title: title(of: card), image: resolve(card.posterPath, posterWidth), progress: nil,
                     open: NectarLink.item(card.id).url,
                     play: card.itemType == "series" ? NectarLink.item(card.id).url : NectarLink.play(card.id).url)
            }
        return TopShelfFeed(watching: Array(resuming), new: Array(fresh))
    }

    private static func title(of card: MediaCard) -> String {
        if let series = card.seriesTitle, let season = card.seasonNumber, let episode = card.episodeNumber {
            return "\(series) · S\(season) E\(episode)"
        }
        return card.title ?? ""
    }
}

/// The feed in one keychain item the app and its Top Shelf extension can both read. A keychain group is the
/// one container the free personal team's profile lets the two share (`keychain-access-groups = TEAM.*`);
/// an App Group would need a capability registered first. Written only after first unlock, never synced.
public final class TopShelfStore: Sendable {

    private let service = "com.beesroadhouse.nectar.topshelf"
    private let accessGroup: String

    public init(accessGroup: String) {
        self.accessGroup = accessGroup
    }

    /// The group the bundle's Info.plist names (`NectarSharedKeychainGroup`, team prefix filled in at build time).
    public convenience init?(bundle: Bundle = .main) {
        guard let group = bundle.object(forInfoDictionaryKey: "NectarSharedKeychainGroup") as? String, !group.isEmpty else { return nil }
        self.init(accessGroup: group)
    }

    private var query: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: "feed",
            kSecAttrAccessGroup as String: accessGroup,
        ]
    }

    public var feed: TopShelfFeed? {
        read().feed
    }

    /// The feed with the keychain's status, for the extension to say why it has none: `errSecItemNotFound`
    /// before the app has written one, `errSecMissingEntitlement` when the group isn't in its entitlements.
    public func read() -> (feed: TopShelfFeed?, status: OSStatus) {
        var lookup = query
        lookup[kSecReturnData as String] = true
        lookup[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(lookup as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else { return (nil, status) }
        return (try? JSONDecoder().decode(TopShelfFeed.self, from: data), status)
    }

    /// Replaces the feed in place, so the extension never reads between a delete and an add; nil removes it
    /// (signing out, so the next person doesn't see the last one's titles).
    @discardableResult
    public func save(_ feed: TopShelfFeed?) -> OSStatus {
        guard let feed, let data = try? JSONEncoder().encode(feed) else {
            let status = SecItemDelete(query as CFDictionary)
            return status == errSecItemNotFound ? errSecSuccess : status
        }
        let updated = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        guard updated == errSecItemNotFound else { return updated }
        var item = query
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(item as CFDictionary, nil)
    }
}
