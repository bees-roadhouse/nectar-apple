import Foundation

/// One playback happening now (`GET /api/v1/admin/sessions`, admins only, #83).
public struct LiveSession: Decodable, Equatable, Identifiable, Sendable {
    public let id: String
    public let username: String?
    public let itemID: String?
    public let itemName: String?
    public let client: String?
    public let device: String?
    public let positionSeconds: Double
    public let runtimeSeconds: Double?
    /// `DirectPlay`, `DirectStream` or `Transcode`.
    public let playMethod: String?
    public let isPaused: Bool
    /// How far through, 0...1, when nectar knows the runtime.
    public let progress: Double?

    private enum Keys: String, CodingKey {
        case username, client, device
        case id = "session_id"
        case itemID = "item_id"
        case itemName = "item_name"
        case positionSeconds = "position_seconds"
        case runtimeSeconds = "runtime_seconds"
        case playMethod = "play_method"
        case isPaused = "is_paused"
        case progressPercent = "progress_percent"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        id = try c.decode(String.self, forKey: .id)
        username = try c.decodeIfPresent(String.self, forKey: .username)
        itemID = try c.decodeIfPresent(String.self, forKey: .itemID)
        itemName = try c.decodeIfPresent(String.self, forKey: .itemName)
        client = try c.decodeIfPresent(String.self, forKey: .client)
        device = try c.decodeIfPresent(String.self, forKey: .device)
        positionSeconds = c.lenientDouble(.positionSeconds) ?? 0
        runtimeSeconds = c.lenientDouble(.runtimeSeconds)
        playMethod = try c.decodeIfPresent(String.self, forKey: .playMethod)
        isPaused = (try? c.decode(Bool.self, forKey: .isPaused)) ?? false
        progress = c.lenientDouble(.progressPercent).map { min(max($0 / 100, 0), 1) }
    }
}

/// The server's host and transcoders now (`GET /api/v1/stats/system`, admins only, #83).
public struct SystemStatus: Decodable, Equatable, Sendable {

    public struct Disk: Decodable, Equatable, Sendable {
        public let mount: String
        public let used: Double
        public let total: Double

        public var share: Double {
            total > 0 ? used / total : 0
        }
    }

    /// A transcoder worker's GPU; one that hasn't checked in for 90 s isn't alive.
    public struct GPU: Decodable, Equatable, Sendable {
        public let workerID: String
        public let type: String?
        public let utilizationPercent: Double?
        public let encodeSessions: Int?
        public let memoryUsed: Double?
        public let memoryTotal: Double?
        public let alive: Bool

        private enum Keys: String, CodingKey {
            case type, alive
            case workerID = "worker_id"
            case utilizationPercent = "utilization_percent"
            case encodeSessions = "encode_sessions"
            case memoryUsed = "mem_used"
            case memoryTotal = "mem_total"
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: Keys.self)
            workerID = try c.decode(String.self, forKey: .workerID)
            type = try c.decodeIfPresent(String.self, forKey: .type)
            utilizationPercent = c.lenientDouble(.utilizationPercent)
            encodeSessions = c.lenientInt(.encodeSessions)
            memoryUsed = c.lenientDouble(.memoryUsed)
            memoryTotal = c.lenientDouble(.memoryTotal)
            alive = (try? c.decode(Bool.self, forKey: .alive)) ?? false
        }
    }

    public let cpuPercent: Double
    public let memoryUsed: Double
    public let memoryTotal: Double
    public let disks: [Disk]
    public let receivedBytesPerSecond: Double
    public let sentBytesPerSecond: Double
    public let gpus: [GPU]
    /// The enrichment backlog per stage; empty stages left out.
    public let queues: [String: Int]
    public let activeTranscodes: Int

    public var memoryShare: Double {
        memoryTotal > 0 ? memoryUsed / memoryTotal : 0
    }

    private enum Keys: String, CodingKey { case cpu, memory, disk, network, gpus, queues, transcodes }
    private struct CPU: Decodable { let percent: Double? }
    private struct Memory: Decodable { let used: Double?; let total: Double? }
    private struct Network: Decodable {
        let rx: Double?
        let tx: Double?
        enum CodingKeys: String, CodingKey { case rx = "rx_bytes_per_sec", tx = "tx_bytes_per_sec" }
    }
    private struct Transcodes: Decodable { let active: Int? }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        cpuPercent = (try? c.decode(CPU.self, forKey: .cpu))?.percent ?? 0
        let memory = try? c.decode(Memory.self, forKey: .memory)
        memoryUsed = memory?.used ?? 0
        memoryTotal = memory?.total ?? 0
        disks = (try? c.decode([Disk].self, forKey: .disk)) ?? []
        let network = try? c.decode(Network.self, forKey: .network)
        receivedBytesPerSecond = network?.rx ?? 0
        sentBytesPerSecond = network?.tx ?? 0
        gpus = (try? c.decode([GPU].self, forKey: .gpus)) ?? []
        queues = ((try? c.decode([String: Int].self, forKey: .queues)) ?? [:]).filter { $0.value > 0 }
        activeTranscodes = (try? c.decode(Transcodes.self, forKey: .transcodes))?.active ?? 0
    }
}

/// Bytes in decimal units, one decimal place from a kilobyte up ("1.3 MB", "8.0 TB").
public func byteText(_ bytes: Double) -> String {
    let units = ["KB", "MB", "GB", "TB", "PB"]
    guard bytes >= 1000 else { return "\(Int(bytes)) B" }
    var value = bytes / 1000
    var unit = 0
    while value >= 1000, unit < units.count - 1 {
        value /= 1000
        unit += 1
    }
    // Half away from zero, as people round: %.1f alone takes 1.25 to "1.2".
    return String(format: "%.1f %@", (value * 10).rounded() / 10, units[unit])
}

private struct SessionsResponse: Decodable {
    let sessions: [LiveSession]
}

extension NectarSession {

    public func liveSessions() async throws -> [LiveSession] {
        try JSONDecoder().decode(SessionsResponse.self, from: try await get("api/v1/admin/sessions")).sessions
    }

    public func systemStatus() async throws -> SystemStatus {
        try JSONDecoder().decode(SystemStatus.self, from: try await get("api/v1/stats/system"))
    }
}
