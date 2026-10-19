import Foundation
import Testing
@testable import NectarKit

private actor Server: HTTPTransport {
    private let status: Int
    private let body: String

    init(_ status: Int, _ body: String) {
        self.status = status
        self.body = body
    }

    nonisolated func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        try await answer(request)
    }

    private func answer(_ request: URLRequest) -> (Data, HTTPURLResponse) {
        (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }
}

private func session(_ transport: Server) -> NectarSession {
    NectarSession(
        baseURL: URL(string: "https://nectar.test")!,
        tokenEndpoint: URL(string: "https://nectar.test/token")!,
        clientID: "nectar-tv",
        store: InMemoryTokenStore(TokenSet(accessToken: "jwt-1", tokenType: "Bearer", expiresIn: nil, refreshToken: "r1")),
        transport: transport
    )
}

@Suite("Activity")
struct ActivityTests {

    @Test func theStreamIsCutIntoEventsAtBlankLines() {
        var parser = ServerSentEvents()
        let lines = [
            ":", "",                                                   // keepalive
            "event: download_progress", #"data: {"type":"download_progress","download_id":"d1","percent":41.5,"bytes_per_sec":5242880,"eta_seconds":95}"#, "",
            "event: scan_started", #"data: {"type":"scan_started","library_id":"l1"}"#, "",
            "event: import_completed", "data: {\"type\":\"import_completed\",", "data: \"media_item_id\":\"m1\",\"download_id\":\"d1\"}", "",
        ]
        let events = lines.compactMap { parser.feed($0) }
        #expect(events.map(\.type) == ["download_progress", "scan_started", "import_completed"])
        #expect(events[2].data == #"{"type":"import_completed","# + "\n" + #""media_item_id":"m1","download_id":"d1"}"#, "multi-line data joins with newlines")
    }

    @Test func blankLinesSurviveTheSplitBecauseTheyEndEvents() {
        var splitter = LineSplitter()
        let wire = "event: import_completed\r\ndata: {}\r\n\r\n:\n\n"
        let lines = Array(wire.utf8).compactMap { splitter.feed($0) }
        #expect(lines == ["event: import_completed", "data: {}", "", ":", ""])
        var parser = ServerSentEvents()
        #expect(lines.compactMap { parser.feed($0) }.map(\.type) == ["import_completed"])
    }

    @Test func theDownloadEventsDecodeAndTheRestAreIgnored() {
        #expect(ServerEvent(type: "download_progress", data: #"{"download_id":"d1","percent":41.5,"bytes_per_sec":5242880,"eta_seconds":95}"#)
                == .downloadProgress(downloadID: "d1", percent: 41.5, bytesPerSecond: 5242880, etaSeconds: 95))
        #expect(ServerEvent(type: "release_grabbed", data: #"{"media_item_id":"m1","download_id":"d2","title":"Charade.1963.1080p","size_bytes":8000000000}"#)
                == .releaseGrabbed(downloadID: "d2", title: "Charade.1963.1080p"))
        #expect(ServerEvent(type: "import_completed", data: #"{"media_item_id":"m1","download_id":"d1"}"#) == .finished(downloadID: "d1"))
        #expect(ServerEvent(type: "import_failed", data: #"{"download_id":"d3","error":"no video file in the release"}"#)
                == .failed(downloadID: "d3", reason: "no video file in the release"))
        #expect(ServerEvent(type: "scan_started", data: "{}") == nil)
        #expect(ServerEvent(type: "download_progress", data: "not json") == nil)
    }

    @Test func theQueueIsAdminsOnlyAndAForbiddenIsNoQueue() async throws {
        let admin = Server(200, #"""
        {"queue":[{"id":"q1","download_id":"d1","state":"downloading","release_title":"Charade.1963.1080p.BluRay","title":"Charade","media_type":"movie",
                   "bytes_done":4000,"bytes_total":10000,"percent":40,"download_state":"downloading","eta_seconds":120,"phase":null,"error":null}],
         "failed":[{"id":"q2","download_id":"d9","state":"failed","release_title":"Bad.Release","title":"Some Film","media_type":"movie",
                   "bytes_done":0,"bytes_total":0,"percent":0,"download_state":null,"eta_seconds":null,"phase":"import","error":"no video file"}]}
        """#)
        let queue = try #require(try await session(admin).downloadQueue())
        #expect(queue.active.map(\.title) == ["Charade"] && queue.active[0].percent == 40 && queue.active[0].etaSeconds == 120)
        #expect(queue.failed.map(\.reason) == ["no video file"])
        #expect(try await session(Server(403, #"{"error":"forbidden"}"#)).downloadQueue() == nil)
    }

    @Test func theBoardFollowsTheStream() {
        var board = DownloadBoard()
        board.seed(DownloadQueue(active: [Download(id: "d1", title: "Charade", percent: 40, etaSeconds: 120, bytesPerSecond: nil, reason: nil)], failed: []))
        board.apply(.downloadProgress(downloadID: "d1", percent: 55, bytesPerSecond: 1_000_000, etaSeconds: 60))
        #expect(board.active.first?.percent == 55 && board.active.first?.etaSeconds == 60)

        board.apply(.releaseGrabbed(downloadID: "d2", title: "Piper.2016.1080p"))
        #expect(board.active.map(\.id) == ["d1", "d2"], "a new grab joins at 0%")
        board.apply(.downloadProgress(downloadID: "d3", percent: 10, bytesPerSecond: nil, etaSeconds: nil))
        #expect(board.active.contains { $0.id == "d3" }, "progress for one we didn't see grabbed still shows")

        board.apply(.finished(downloadID: "d1"))
        board.apply(.failed(downloadID: "d2", reason: "no video file"))
        #expect(board.active.map(\.id) == ["d3"])
        #expect(board.failed.map(\.title) == ["Piper.2016.1080p"] && board.failed[0].reason == "no video file")
    }
}
