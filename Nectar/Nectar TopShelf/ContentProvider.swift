import NectarKit
import OSLog
import TVServices

private let log = Logger(subsystem: "com.beesroadhouse.nectar.tv", category: "topshelf")

/// Nectar's Top Shelf (#74): Continue Watching and what's new, as the app last saw them on Home. It reads the feed
/// the app left in the keychain group they share and never calls nectar; with no feed, the static banner shows.
final class ContentProvider: TVTopShelfContentProvider {

    override func loadTopShelfContent(completionHandler: @escaping (TVTopShelfContent?) -> Void) {
        guard let store = TopShelfStore() else {
            log.error("top shelf: no NectarSharedKeychainGroup in the extension's Info.plist")
            return completionHandler(nil)
        }
        let (feed, status) = store.read()
        guard let feed, !feed.isEmpty else {
            log.info("top shelf: no feed, keychain status \(status, privacy: .public)")
            return completionHandler(nil)
        }
        log.info("top shelf: \(feed.watching.count, privacy: .public) watching, \(feed.new.count, privacy: .public) new")
        var sections: [TVTopShelfItemCollection<TVTopShelfSectionedItem>] = []
        if !feed.watching.isEmpty {
            sections.append(section("Continue watching", feed.watching, shape: .hdtv))
        }
        if !feed.new.isEmpty {
            sections.append(section("New", feed.new, shape: .poster))
        }
        completionHandler(TVTopShelfSectionedContent(sections: sections))
    }

    private func section(_ title: String, _ items: [TopShelfFeed.Item], shape: TVTopShelfSectionedItem.ImageShape)
        -> TVTopShelfItemCollection<TVTopShelfSectionedItem> {
        let section = TVTopShelfItemCollection<TVTopShelfSectionedItem>(items: items.map { item in
            let tile = TVTopShelfSectionedItem(identifier: item.id)
            tile.title = item.title
            tile.imageShape = shape
            // One width for both scales: the feed asks for the 4K size, and an HD TV scales it down.
            tile.setImageURL(item.image, for: [.screenScale1x, .screenScale2x])
            if let progress = item.progress {
                tile.playbackProgress = progress
            }
            tile.displayAction = TVTopShelfAction(url: item.open)
            tile.playAction = TVTopShelfAction(url: item.play)
            return tile
        })
        section.title = title
        return section
    }
}
