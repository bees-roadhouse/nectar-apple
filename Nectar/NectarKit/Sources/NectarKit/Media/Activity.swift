import Foundation

/// Cuts a `text/event-stream` into events, one line at a time: `event:` names it, `data:` lines
/// (joined with newlines) carry it, a blank line sends it, and `:` lines are keepalives.
public struct ServerSentEvents: Sendable {
    public struct Event: Equatable, Sendable {
        public let type: String
        public let data: String
    }

    private var type: String?
    private var data: [String] = []

    public init() {}

    /// The event this line completes, if it's the blank line after one.
    public mutating func feed(_ line: String) -> Event? {
        if line.isEmpty {
            defer { type = nil; data = [] }
            guard !data.isEmpty else { return nil }
            return Event(type: type ?? "message", data: data.joined(separator: "\n"))
        }
        if line.hasPrefix(":") { return nil }
        let (field, value) = line.firstIndex(of: ":").map { (String(line[..<$0]), String(line[line.index(after: $0)...])) } ?? (line, "")
        let trimmed = value.hasPrefix(" ") ? String(value.dropFirst()) : value
        switch field {
        case "event": type = trimmed
        case "data": data.append(trimmed)
        default: break
        }
        return nil
    }
}

/// Bytes into lines, keeping the empty ones: an event stream ends each event with a blank line, which
/// `AsyncBytes.lines` doesn't reliably deliver. `\n` and `\r\n` both end a line.
public struct LineSplitter: Sendable {
    private var buffer: [UInt8] = []

    public init() {}

    public mutating func feed(_ byte: UInt8) -> String? {
        guard byte == 0x0A else {
            buffer.append(byte)
            return nil
        }
        if buffer.last == 0x0D { buffer.removeLast() }
        defer { buffer.removeAll(keepingCapacity: true) }
        return String(decoding: buffer, as: UTF8.self)
    }
}

/// What the TV does with nectar's event stream: the download pipeline's moments.
public enum ServerEvent: Equatable, Sendable {
    case releaseGrabbed(downloadID: String, title: String?)
    case downloadProgress(downloadID: String, percent: Double, bytesPerSecond: Double?, etaSeconds: Double?)
    case finished(downloadID: String)
    case failed(downloadID: String, reason: String?)

    private struct Payload: Decodable {
        let downloadID: String
        let title: String?
        let percent: Double?
        let bytesPerSec: Double?
        let etaSeconds: Double?
        let error: String?

        enum CodingKeys: String, CodingKey {
            case title, percent, error
            case downloadID = "download_id"
            case bytesPerSec = "bytes_per_sec"
            case etaSeconds = "eta_seconds"
        }
    }

    /// nil for the events the TV doesn't follow (scans, jobs, rooms) and for anything that doesn't parse.
    public init?(type: String, data: String) {
        guard ["release_grabbed", "download_progress", "import_completed", "import_failed"].contains(type),
              let payload = try? JSONDecoder().decode(Payload.self, from: Data(data.utf8)) else { return nil }
        switch type {
        case "release_grabbed": self = .releaseGrabbed(downloadID: payload.downloadID, title: payload.title)
        case "download_progress": self = .downloadProgress(downloadID: payload.downloadID, percent: payload.percent ?? 0, bytesPerSecond: payload.bytesPerSec, etaSeconds: payload.etaSeconds)
        case "import_completed": self = .finished(downloadID: payload.downloadID)
        default: self = .failed(downloadID: payload.downloadID, reason: payload.error)
        }
    }
}

/// One transfer, in flight or failed.
public struct Download: Equatable, Identifiable, Sendable {
    public let id: String
    public var title: String
    public var percent: Double
    public var etaSeconds: Double?
    public var bytesPerSecond: Double?
    /// Why it failed, for a failed one.
    public var reason: String?

    public init(id: String, title: String, percent: Double, etaSeconds: Double?, bytesPerSecond: Double?, reason: String?) {
        self.id = id
        self.title = title
        self.percent = percent
        self.etaSeconds = etaSeconds
        self.bytesPerSecond = bytesPerSecond
        self.reason = reason
    }
}

/// `GET /api/v1/arr/queue`: what's in flight, and the last day's failures.
public struct DownloadQueue: Equatable, Sendable {
    public let active: [Download]
    public let failed: [Download]

    public init(active: [Download], failed: [Download]) {
        self.active = active
        self.failed = failed
    }
}

/// The downloads as the screen shows them: seeded from the queue (when the user may read it), then kept
/// current by the event stream alone. Nothing is polled.
public struct DownloadBoard: Equatable, Sendable {
    public private(set) var active: [Download] = []
    public private(set) var failed: [Download] = []

    public init() {}

    public mutating func seed(_ queue: DownloadQueue) {
        active = queue.active
        failed = queue.failed
    }

    public mutating func apply(_ event: ServerEvent) {
        switch event {
        case let .releaseGrabbed(id, title):
            guard !active.contains(where: { $0.id == id }) else { return }
            active.append(Download(id: id, title: title ?? "Downloading…", percent: 0, etaSeconds: nil, bytesPerSecond: nil, reason: nil))
        case let .downloadProgress(id, percent, speed, eta):
            if let index = active.firstIndex(where: { $0.id == id }) {
                active[index].percent = percent
                active[index].bytesPerSecond = speed
                active[index].etaSeconds = eta
            } else {
                // Grabbed before this TV was listening: it still shows, named once the queue or a grab says.
                active.append(Download(id: id, title: "Downloading…", percent: percent, etaSeconds: eta, bytesPerSecond: speed, reason: nil))
            }
        case let .finished(id):
            active.removeAll { $0.id == id }
        case let .failed(id, reason):
            guard let index = active.firstIndex(where: { $0.id == id }) else { return }
            var download = active.remove(at: index)
            download.reason = reason
            failed.insert(download, at: 0)
        }
    }
}

private struct QueuePage: Decodable {
    struct Row: Decodable {
        let id: String
        let downloadID: String?
        let releaseTitle: String?
        let title: String?
        let percent: Double?
        let etaSeconds: Double?
        let error: String?

        enum CodingKeys: String, CodingKey {
            case id, title, percent, error
            case downloadID = "download_id"
            case releaseTitle = "release_title"
            case etaSeconds = "eta_seconds"
        }

        var download: Download {
            Download(id: downloadID ?? id, title: title ?? releaseTitle ?? "Downloading…", percent: percent ?? 0,
                     etaSeconds: etaSeconds, bytesPerSecond: nil, reason: error)
        }
    }

    let queue: [Row]
    let failed: [Row]?
}

extension NectarSession {

    /// The download queue, or nil when this user may not read it (it's an admin's view; others follow the stream).
    public func downloadQueue() async throws -> DownloadQueue? {
        do {
            let page = try JSONDecoder().decode(QueuePage.self, from: try await get("api/v1/arr/queue"))
            return DownloadQueue(active: page.queue.map(\.download), failed: (page.failed ?? []).map(\.download))
        } catch NectarSessionError.unexpectedStatus(403) {
            return nil
        }
    }

    /// nectar's live event stream, the events the TV follows. Ends when the connection does; the caller reconnects.
    public nonisolated func eventStream() -> AsyncThrowingStream<ServerEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let (bytes, response) = try await URLSession.shared.bytes(for: try await self.streamRequest("api/v1/events"))
                    guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                        throw NectarSessionError.unexpectedStatus((response as? HTTPURLResponse)?.statusCode ?? 0)
                    }
                    var lines = LineSplitter()
                    var parser = ServerSentEvents()
                    for try await byte in bytes {
                        guard let line = lines.feed(byte) else { continue }
                        if let raw = parser.feed(line), let event = ServerEvent(type: raw.type, data: raw.data) {
                            continuation.yield(event)
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
