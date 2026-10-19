import Foundation
import NectarKit
import OSLog
import UIKit

private let log = Logger(subsystem: "com.beesroadhouse.nectar.tv", category: "preload")

/// Pre-loading titles to the TV (#85): a background download of a file the TV plays as it is, into the
/// pre-load folder under Caches, within the household's budget. tvOS has no offline HLS (`AVAssetDownloadTask`
/// is unavailable), so this is a cache the system may clear; a cleared title just streams again.
@MainActor
@Observable
final class PreloadManager {

    enum State: Equatable {
        case none
        /// 0...1, or nil before the size is known.
        case downloading(Double?)
        case loaded
        /// Why it isn't pre-loaded, in words.
        case unavailable(String)
    }

    static let shared = PreloadManager()
    static let sessionID = "com.beesroadhouse.nectar.tv.preload"
    static let budgets = [10, 25, 50]

    let store = PreloadStore()
    private(set) var states: [String: State] = [:]
    /// The sizes of downloads under way, counted against the budget before they land.
    @ObservationIgnored
    private var pending: [String: Int64] = [:]
    /// Bumped when the store changes, so views reading it redraw.
    private(set) var revision = 0
    /// The system's handler for a background session's events, called once they're delivered.
    var backgroundCompletion: (() -> Void)?

    /// The pre-load budget in GB: a per-TV setting, kept in this TV's defaults.
    var budgetGB: Int {
        get {
            _ = revision
            let saved = UserDefaults.standard.integer(forKey: "preloadBudgetGB")
            return saved > 0 ? saved : 25
        }
        set {
            UserDefaults.standard.set(newValue, forKey: "preloadBudgetGB")
            revision += 1
        }
    }

    @ObservationIgnored
    private lazy var downloads: URLSession = {
        let configuration = URLSessionConfiguration.background(withIdentifier: Self.sessionID)
        configuration.sessionSendsLaunchEvents = true
        configuration.isDiscretionary = false
        return URLSession(configuration: configuration, delegate: Downloads(manager: self, store: store), delegateQueue: nil)
    }()

    private init() {}

    /// Re-attach to downloads that ran while the app was away (the system relaunches it for their events).
    func reconnect() {
        downloads.getAllTasks { tasks in
            let running = tasks.compactMap { task in Job(task.taskDescription).map { ($0.itemID, task) } }
            Task { @MainActor in
                for (id, _) in running where self.states[id] == nil {
                    self.states[id] = .downloading(nil)
                }
            }
        }
    }

    /// Whether this TV has the title pre-loaded: what a poster's badge asks, so no disk check per poster.
    func isPreloaded(_ itemID: String) -> Bool {
        _ = revision
        return store.index.entries[itemID] != nil
    }

    func state(for itemID: String) -> State {
        _ = revision
        if store.file(for: itemID) != nil { return .loaded }
        return states[itemID] ?? .none
    }

    /// Starts a pre-load: only a file the TV plays as it is, made room for within the budget.
    /// `posters` are the artwork paths Now Playing may ask for (an episode's still and its item poster).
    func preload(itemID: String, title: String, source: PlaybackSource, posters: [String?], session: NectarSession) async {
        guard PreloadIndex.canPlayLocally(source, capabilities: PlayerModel.capabilities) else {
            states[itemID] = .unavailable("Can't pre-load this one yet")
            return
        }
        let size = Int64(source.sizeBytes ?? 0)
        let budget = Int64(budgetGB) * 1_000_000_000
        let underWay = pending.values.reduce(0, +)
        guard let evicted = store.index.evictions(for: size, budget: budget, freeSpace: Self.freeSpace(), pending: underWay) else {
            states[itemID] = .unavailable("Too big for the pre-load space")
            return
        }
        evicted.forEach(store.remove)
        do {
            // The URL carries the access token: it goes to the download and nowhere else, never a log.
            let url = try await session.mediaURL("/api/v1/streaming/\(itemID)/direct")
            let task = downloads.downloadTask(with: url)
            task.taskDescription = Job(itemID: itemID, title: title, fileExtension: source.container?.lowercased() ?? "mp4").encoded
            states[itemID] = .downloading(nil)
            pending[itemID] = size
            revision += 1
            task.resume()
            // Now Playing's artwork, cached at the width it asks for, so a pre-loaded title has its poster
            // even when nectar can't be reached.
            let artwork = posters.compactMap { session.resolve($0, pixelWidth: PlayerModel.nowPlayingArtworkWidth) }
            if !artwork.isEmpty {
                Task.detached { await ImageCache.shared.prefetch(artwork) }
            }
            log.info("preload \(itemID, privacy: .public): \(size, privacy: .public) bytes, evicted \(evicted.count, privacy: .public)")
        } catch {
            states[itemID] = .unavailable("Couldn't start the download")
        }
    }

    /// Cancels a download in flight, or removes the TV's copy.
    func remove(_ itemID: String) {
        downloads.getAllTasks { tasks in
            tasks.filter { Job($0.taskDescription)?.itemID == itemID }.forEach { $0.cancel() }
        }
        store.remove(itemID)
        states[itemID] = nil
        pending[itemID] = nil
        revision += 1
    }

    func removeAll() {
        downloads.getAllTasks { tasks in tasks.forEach { $0.cancel() } }
        store.removeAll()
        states = [:]
        pending = [:]
        revision += 1
    }

    fileprivate func progressed(_ itemID: String, _ fraction: Double?) {
        states[itemID] = .downloading(fraction)
    }

    /// "Pre-load the next 3" on a series: each episode's file facts come from its item route, and those the
    /// TV can't play as they are are skipped. Returns how many were skipped.
    func preloadNext(_ episodes: [Episode], series: String, session: NectarSession) async -> Int {
        var skipped = 0
        for episode in episodes where !isPreloaded(episode.id) {
            if case .downloading = states[episode.id] { continue }
            guard let detail = try? await session.detail(episode.id),
                  PreloadIndex.canPlayLocally(detail.source, capabilities: PlayerModel.capabilities) else {
                skipped += 1
                continue
            }
            await preload(itemID: episode.id, title: "\(series) · \(episode.code ?? episode.title)", source: detail.source,
                          posters: [episode.thumbPath, detail.posterPath], session: session)
        }
        return skipped
    }

    fileprivate func finished(_ itemID: String, error: String?) {
        pending[itemID] = nil
        states[itemID] = error.map(State.unavailable)
        revision += 1
        if let error {
            log.error("preload \(itemID, privacy: .public) failed: \(error, privacy: .public)")
        } else {
            log.info("preload \(itemID, privacy: .public) done")
        }
    }

    fileprivate func eventsDelivered() {
        backgroundCompletion?()
        backgroundCompletion = nil
    }

    static func freeSpace() -> Int64 {
        let home = URL(fileURLWithPath: NSHomeDirectory())
        return (try? home.resourceValues(forKeys: [.volumeAvailableCapacityKey]).volumeAvailableCapacity).map(Int64.init) ?? 0
    }
}

/// What a download is for, carried on the task so it survives the app being relaunched.
private struct Job: Codable {
    let itemID: String
    let title: String
    let fileExtension: String

    init(itemID: String, title: String, fileExtension: String) {
        self.itemID = itemID
        self.title = title
        self.fileExtension = fileExtension
    }

    init?(_ description: String?) {
        guard let data = description?.data(using: .utf8), let job = try? JSONDecoder().decode(Job.self, from: data) else { return nil }
        self = job
    }

    var encoded: String {
        (try? JSONEncoder().encode(self)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
    }
}

/// The background session's delegate. A finished file is moved into the store before this returns, as the
/// system deletes it afterwards; the manager hears about it on the main actor.
private final class Downloads: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {

    private weak var manager: PreloadManager?
    private let store: PreloadStore

    init(manager: PreloadManager, store: PreloadStore) {
        self.manager = manager
        self.store = store
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData _: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard let job = Job(downloadTask.taskDescription) else { return }
        let fraction = totalBytesExpectedToWrite > 0 ? Double(totalBytesWritten) / Double(totalBytesExpectedToWrite) : nil
        Task { @MainActor [weak manager] in manager?.progressed(job.itemID, fraction) }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let job = Job(downloadTask.taskDescription) else { return }
        let status = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            Task { @MainActor [weak manager] in manager?.finished(job.itemID, error: "nectar answered \(status)") }
            return
        }
        do {
            try store.add(itemID: job.itemID, title: job.title, fileExtension: job.fileExtension, from: location)
            Task { @MainActor [weak manager] in manager?.finished(job.itemID, error: nil) }
        } catch {
            Task { @MainActor [weak manager] in manager?.finished(job.itemID, error: "Couldn't keep the file") }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error, let job = Job(task.taskDescription) else { return }
        let cancelled = (error as? URLError)?.code == .cancelled
        Task { @MainActor [weak manager] in manager?.finished(job.itemID, error: cancelled ? nil : "The download stopped") }
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        Task { @MainActor [weak manager] in manager?.eventsDelivered() }
    }
}

/// Lets the system hand back a background download's events when it relaunched the app for them.
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, handleEventsForBackgroundURLSession identifier: String,
                     completionHandler: @escaping () -> Void) {
        guard identifier == PreloadManager.sessionID else { return completionHandler() }
        Task { @MainActor in
            PreloadManager.shared.backgroundCompletion = completionHandler
            PreloadManager.shared.reconnect()
        }
    }
}
