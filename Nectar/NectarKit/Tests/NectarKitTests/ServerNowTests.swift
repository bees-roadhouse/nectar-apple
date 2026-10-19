import Foundation
@testable import NectarKit
import Testing

private actor NowServer: HTTPTransport {
    nonisolated func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let body: String
        switch request.url!.path {
        case "/api/v1/admin/sessions":
            body = #"{"sessions":[{"session_id":"k1","user_id":"u1","username":"nate","item_id":"a","item_name":"Arrival","item_type":"movie","client":"Nectar TV","device":"Apple TV","position_seconds":1740.5,"runtime_seconds":6960,"play_method":"Transcode","is_paused":false,"progress_percent":25,"started_at":1760900000000,"last_update":1760900100000},{"session_id":"k2","user_id":"u2","username":"maggie","item_id":null,"item_name":null,"item_type":null,"client":"Nectar Web","device":"Safari","position_seconds":0,"runtime_seconds":null,"play_method":"DirectPlay","is_paused":true,"progress_percent":null,"started_at":null,"last_update":null}]}"#
        case "/api/v1/stats/system":
            body = #"{"cpu":{"percent":37.5,"per_core":[30,45]},"memory":{"used":12884901888,"total":34359738368},"disk":[{"mount":"/media","used":8000000000000,"total":16000000000000}],"network":{"rx_bytes_per_sec":1250000,"tx_bytes_per_sec":5000000},"gpus":[{"worker_id":"w1","type":"nvidia","utilization_percent":62,"encode_sessions":2,"mem_used":2147483648,"mem_total":8589934592,"alive":true},{"worker_id":"w2","type":null,"utilization_percent":null,"encode_sessions":null,"mem_used":null,"mem_total":null,"alive":false}],"queues":{"tmdb-fetch":3,"embed":0,"image-cache":12},"transcodes":{"active":1,"sessions":[],"jobs":[]}}"#
        default:
            throw URLError(.fileDoesNotExist)
        }
        return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}

private func session() -> NectarSession {
    NectarSession(
        baseURL: URL(string: "https://nectar.test")!,
        tokenEndpoint: URL(string: "https://nectar.test/token")!,
        clientID: "nectar-tv",
        store: InMemoryTokenStore(TokenSet(accessToken: "jwt-1", tokenType: "Bearer", expiresIn: nil, refreshToken: "r1")),
        transport: NowServer()
    )
}

struct ServerNowTests {

    @Test func whoIsWatchingWhatAndHow() async throws {
        let sessions = try await session().liveSessions()
        #expect(sessions.count == 2)
        let nate = try #require(sessions.first)
        #expect(nate.username == "nate" && nate.itemName == "Arrival" && nate.playMethod == "Transcode")
        #expect(nate.progress == 0.25)
        #expect(!nate.isPaused)
        #expect(sessions[1].isPaused && sessions[1].itemName == nil && sessions[1].progress == nil)
    }

    @Test func theHostItsGPUsAndQueues() async throws {
        let system = try await session().systemStatus()
        #expect(system.cpuPercent == 37.5)
        #expect(system.memoryShare == 0.375)
        #expect(system.disks.first?.mount == "/media" && system.disks.first?.share == 0.5)
        #expect(system.receivedBytesPerSecond == 1_250_000)
        #expect(system.gpus.map(\.alive) == [true, false])
        #expect(system.gpus.first?.encodeSessions == 2)
        #expect(system.queues == ["image-cache": 12, "tmdb-fetch": 3])
        #expect(system.activeTranscodes == 1)
    }

    @Test(arguments: [(0.0, "0 B"), (999.0, "999 B"), (1_250_000, "1.3 MB"), (8_000_000_000_000, "8.0 TB"), (12_884_901_888, "12.9 GB")])
    func sizesReadInDecimalUnits(_ bytes: Double, _ text: String) {
        #expect(byteText(bytes) == text)
    }
}
