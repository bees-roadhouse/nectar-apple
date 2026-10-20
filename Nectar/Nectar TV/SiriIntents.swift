import AppIntents
import NectarKit
import OSLog

private let log = Logger(subsystem: "com.beesroadhouse.nectar.tv", category: "siri")

/// A film or series in the library, as Siri names it (#77). Resolved from the title catalog kept on the TV, never
/// over the network: only the app's own session talks to nectar, because refresh tokens rotate.
struct TitleEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Title"
    static let defaultQuery = TitleQuery()

    let id: String
    let title: String
    let year: Int?

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(title)", subtitle: year.map { LocalizedStringResource(stringLiteral: String($0)) })
    }

    init(_ title: TitleCatalog.Title) {
        id = title.id
        self.title = title.title
        year = title.year
    }
}

struct TitleQuery: EntityStringQuery {

    func entities(for identifiers: [TitleEntity.ID]) async throws -> [TitleEntity] {
        let wanted = Set(identifiers)
        return (TitleCatalogStore().catalog?.titles ?? []).filter { wanted.contains($0.id) }.map(TitleEntity.init)
    }

    func entities(matching string: String) async throws -> [TitleEntity] {
        (TitleCatalogStore().catalog?.matching(string) ?? []).map(TitleEntity.init)
    }

    /// Every title, so a phrase can name any of them.
    func suggestedEntities() async throws -> [TitleEntity] {
        (TitleCatalogStore().catalog?.titles ?? []).map(TitleEntity.init)
    }
}

/// "Play Arrival in Nectar": a film from where this user stopped; a series opens its detail.
struct PlayTitleIntent: AppIntent {
    static let title: LocalizedStringResource = "Play"
    static let description = IntentDescription("Plays a film from where you stopped, or opens a series.")
    static let supportedModes: IntentModes = .foreground

    @Parameter(title: "Title")
    var item: TitleEntity

    @AppDependency
    private var app: AppModel

    @MainActor
    func perform() async throws -> some IntentResult {
        app.follow(.play(item.id))
        return .result()
    }
}

/// "Open The Handmaid's Tale in Nectar": the title's detail.
struct OpenTitleIntent: AppIntent {
    static let title: LocalizedStringResource = "Open"
    static let description = IntentDescription("Shows a title's detail in Nectar.")
    static let supportedModes: IntentModes = .foreground

    @Parameter(title: "Title")
    var item: TitleEntity

    @AppDependency
    private var app: AppModel

    @MainActor
    func perform() async throws -> some IntentResult {
        app.follow(.item(item.id))
        return .result()
    }
}

struct NectarShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: PlayTitleIntent(),
            phrases: ["Play \(\.$item) in \(.applicationName)", "Watch \(\.$item) in \(.applicationName)", "Play \(\.$item) on \(.applicationName)"],
            shortTitle: "Play",
            systemImageName: "play.fill"
        )
        AppShortcut(
            intent: OpenTitleIntent(),
            phrases: ["Open \(\.$item) in \(.applicationName)", "Show \(\.$item) in \(.applicationName)"],
            shortTitle: "Open",
            systemImageName: "film"
        )
    }
}

extension HomeModel {

    /// Whether Siri has been told the titles since this launch.
    private static var toldSiri = false

    /// Siri's titles: fetched again after Home loads when the catalog is missing or over a day old. Siri is told
    /// after a refresh, and once per launch besides, so an install or update with a fresh catalog is heard too.
    func refreshTitleCatalog() async {
        let store = TitleCatalogStore()
        var refreshed = false
        if store.catalog?.isStale() ?? true {
            do {
                let catalog = try await session.titleCatalog()
                try store.save(catalog)
                refreshed = true
                log.info("title catalog: \(catalog.titles.count, privacy: .public) titles")
            } catch {
                log.error("title catalog: \(error.localizedDescription, privacy: .public)")
            }
        }
        guard refreshed || (!Self.toldSiri && store.catalog != nil) else { return }
        Self.toldSiri = true
        NectarShortcuts.updateAppShortcutParameters()
    }
}
