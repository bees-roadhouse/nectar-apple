import Foundation
import Observation

/// A directory search owns its generation: a late old page cannot replace a newer query.
@MainActor
@Observable
public final class PeopleBrowser {
    public let session: NectarSession
    public var query = ""
    public private(set) var people: [Person] = []
    public private(set) var total = 0
    public private(set) var loading = false
    public private(set) var loaded = false
    public private(set) var failed = false
    public private(set) var more = true
    private var offset = 0
    private var generation = 0
    private var requestedQuery = ""

    public init(session: NectarSession) { self.session = session }

    /// Re-entering a retained directory keeps its pages; refresh and Retry explicitly use search().
    public func start() async {
        let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized != requestedQuery || generation == 0 || !loaded && !loading && !failed else { return }
        await search()
    }

    public func search(debounce: Bool = true) async {
        generation += 1
        let request = generation
        requestedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        people = []; total = 0; offset = 0; more = true; loaded = false; failed = false; loading = false
        if debounce && !requestedQuery.isEmpty {
            do { try await Task.sleep(for: .milliseconds(300)) }
            catch { return }
        }
        guard request == generation, !Task.isCancelled else { return }
        await page(generation: request)
    }

    public func loadMore() async {
        guard more, !loading else { return }
        await page(generation: generation)
    }

    private func page(generation request: Int) async {
        guard !loading else { return }
        loading = true; failed = false
        let search = requestedQuery
        defer { if request == generation { loading = false } }
        do {
            let page = try await session.people(search: search, offset: offset)
            guard request == generation, search == query.trimmingCharacters(in: .whitespacesAndNewlines), !Task.isCancelled else { return }
            people += page.people.filter { person in !people.contains { $0.id == person.id } }
            offset += page.people.count; total = page.total; loaded = true
            more = !page.people.isEmpty && offset < page.total
        } catch {
            guard request == generation, search == query.trimmingCharacters(in: .whitespacesAndNewlines), !Task.isCancelled else { return }
            failed = true
        }
    }
}

