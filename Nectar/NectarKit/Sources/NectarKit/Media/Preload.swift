import Foundation

extension PlaybackDecision {
    /// The play method a pre-loaded title plays with (#85); only the TV shows it, progress reports don't carry it.
    public static let preloaded = "Preloaded"

    /// Playing the TV's own copy of a title.
    public static func local(_ file: URL) -> PlaybackDecision {
        PlaybackDecision(strategy: .direct, streamPath: file.path, playMethod: preloaded)
    }
}

/// One title pre-loaded to the TV (#85): its file in the pre-load folder, and when it was last touched.
public struct PreloadEntry: Codable, Equatable, Sendable {
    public let itemID: String
    public let title: String
    public let fileName: String
    public let bytes: Int64
    public let completedAt: Date
    public var lastPlayedAt: Date?

    public init(itemID: String, title: String, fileName: String, bytes: Int64, completedAt: Date, lastPlayedAt: Date? = nil) {
        self.itemID = itemID
        self.title = title
        self.fileName = fileName
        self.bytes = bytes
        self.completedAt = completedAt
        self.lastPlayedAt = lastPlayedAt
    }

    /// When it was last of use: played, or else finished downloading.
    var lastTouched: Date {
        lastPlayedAt ?? completedAt
    }
}

/// What's pre-loaded, and the rules for what fits: a budget the household sets, a margin of free disk the TV
/// keeps whatever the budget, and the least recently played going first when room is needed.
public struct PreloadIndex: Codable, Equatable, Sendable {
    public var entries: [String: PreloadEntry]

    /// Disk the TV keeps free for itself, budget or not.
    static let margin: Int64 = 2_000_000_000

    public init(entries: [PreloadEntry] = []) {
        self.entries = Dictionary(entries.map { ($0.itemID, $0) }, uniquingKeysWith: { _, last in last })
    }

    public var usedBytes: Int64 {
        entries.values.reduce(0) { $0 + $1.bytes }
    }

    /// The titles to remove so `incoming` bytes fit: under the budget, and leaving the margin free on disk.
    /// Nil when it can't fit even with everything removed.
    public func evictions(for incoming: Int64, budget: Int64, freeSpace: Int64) -> [String]? {
        guard incoming <= budget, incoming + Self.margin <= freeSpace + usedBytes else { return nil }
        var used = usedBytes
        var free = freeSpace
        var out: [String] = []
        for entry in entries.values.sorted(by: { $0.lastTouched < $1.lastTouched }) {
            if used + incoming <= budget, free - incoming >= Self.margin { break }
            out.append(entry.itemID)
            used -= entry.bytes
            free += entry.bytes
        }
        return out
    }

    /// Whether the TV's own player plays this file as it is: a container, video codec and default audio it
    /// decodes. Nectar's decide isn't asked, since for anything but direct play it starts a job on the server.
    public static func canPlayLocally(_ source: PlaybackSource, capabilities: PlaybackCapabilities) -> Bool {
        guard let container = source.container?.lowercased(), capabilities.containers.contains(container),
              let video = source.videoCodec?.lowercased(), capabilities.videoCodecs.contains(video) else { return false }
        let audio = source.audioTracks.compactMap { $0.codec?.lowercased() }
        return audio.isEmpty || audio.contains(where: capabilities.audioCodecs.contains)
    }
}

/// The pre-loaded files and their index, in a folder under Caches: tvOS may purge it under pressure, which
/// is normal here (the title streams again), so the index forgets any file the disk no longer has.
public final class PreloadStore: @unchecked Sendable {

    public let directory: URL
    private let lock = NSLock()
    private var current: PreloadIndex

    public init(directory: URL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("preloads")) {
        self.directory = directory
        let data = try? Data(contentsOf: directory.appendingPathComponent("index.json"))
        current = data.flatMap { try? JSONDecoder().decode(PreloadIndex.self, from: $0) } ?? PreloadIndex()
        prune()
    }

    public var index: PreloadIndex {
        lock.withLock { current }
    }

    /// The local file for a title, if it's pre-loaded and still on disk.
    public func file(for itemID: String) -> URL? {
        prune()
        return lock.withLock { current.entries[itemID] }.map { directory.appendingPathComponent($0.fileName) }
    }

    /// Moves a finished download into the folder and records it.
    @discardableResult
    public func add(itemID: String, title: String, fileExtension: String, from download: URL, now: Date = .now) throws -> PreloadEntry {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let name = "\(itemID).\(fileExtension)"
        let target = directory.appendingPathComponent(name)
        try? FileManager.default.removeItem(at: target)
        try FileManager.default.moveItem(at: download, to: target)
        let bytes = (try? target.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
        let entry = PreloadEntry(itemID: itemID, title: title, fileName: name, bytes: bytes, completedAt: now)
        update { $0.entries[itemID] = entry }
        return entry
    }

    public func markPlayed(_ itemID: String, now: Date = .now) {
        update { $0.entries[itemID]?.lastPlayedAt = now }
    }

    public func remove(_ itemID: String) {
        guard let entry = lock.withLock({ current.entries[itemID] }) else { return }
        try? FileManager.default.removeItem(at: directory.appendingPathComponent(entry.fileName))
        update { $0.entries[itemID] = nil }
    }

    public func removeAll() {
        for id in index.entries.keys {
            remove(id)
        }
    }

    /// Entries whose file tvOS has purged are dropped.
    private func prune() {
        let gone = lock.withLock { current.entries.values }
            .filter { !FileManager.default.fileExists(atPath: directory.appendingPathComponent($0.fileName).path) }
            .map(\.itemID)
        guard !gone.isEmpty else { return }
        update { index in gone.forEach { index.entries[$0] = nil } }
    }

    private func update(_ change: (inout PreloadIndex) -> Void) {
        let snapshot = lock.withLock { () -> PreloadIndex in
            change(&current)
            return current
        }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? JSONEncoder().encode(snapshot).write(to: directory.appendingPathComponent("index.json"), options: .atomic)
    }
}
