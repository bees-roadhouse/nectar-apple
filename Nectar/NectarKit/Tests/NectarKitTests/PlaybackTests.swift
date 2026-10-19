import Foundation
import Testing
@testable import NectarKit

/// Answers by path and keeps every request.
private actor PathTransport: HTTPTransport {

    private let answers: [String: (Int, String)]
    private(set) var requests: [URLRequest] = []

    init(_ answers: [String: (Int, String)]) {
        self.answers = answers
    }

    nonisolated func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        try await answer(request)
    }

    private func answer(_ request: URLRequest) throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        guard let (status, body) = answers[request.url!.path] else { throw URLError(.fileDoesNotExist) }
        return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }
}

private func session(_ transport: PathTransport, token: String = "jwt-1") -> NectarSession {
    NectarSession(
        baseURL: URL(string: "https://nectar.test")!,
        tokenEndpoint: URL(string: "https://nectar.test/token")!,
        clientID: "nectar-tv",
        store: InMemoryTokenStore(TokenSet(accessToken: token, tokenType: "Bearer", expiresIn: nil, refreshToken: "r1")),
        transport: transport
    )
}

private func json(_ data: Data?) throws -> [String: Any] {
    let data = try #require(data)
    return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
}

/// Shaped as `decideResponse` in nectar's routes/streaming.ts builds it.
private let hlsAnswer = #"""
{"strategy":"hls","stream_url":"/api/v1/streaming/68185a0d/hls/copy-adef-aeac3/stream.m3u8","content_type":"application/vnd.apple.mpegurl",
 "job_id":"j1","play_method":"DirectStream","reason":"container","selected":{"quality":"original"},
 "available_qualities":["original","1080p"],"hls":{"playlist_type":"media","variants":[]},
 "duration_seconds":7440,"start_offset_seconds":1736}
"""#
private let directAnswer = #"""
{"strategy":"direct","stream_url":"/api/v1/streaming/6f1c/direct","content_type":"video/mp4","job_id":null,
 "play_method":"DirectPlay","direct_url":"/api/v1/streaming/6f1c/direct","start_offset_seconds":0}
"""#

@Suite("Playback")
struct PlaybackTests {

    @Test func hevcIsClaimedOnlyWithHardwareDecode() {
        let tv = PlaybackCapabilities.avPlayer(hevcHardwareDecode: true)
        let simulator = PlaybackCapabilities.avPlayer(hevcHardwareDecode: false)
        #expect(tv.videoCodecs.contains("hevc") && tv.hlsVideoCodecs.contains("hevc"))
        #expect(!simulator.videoCodecs.contains("hevc") && !simulator.hlsVideoCodecs.contains("hevc"))
        #expect(simulator.videoCodecs == ["h264"])
    }

    @Test func decidePostsTheCapabilitiesAsNectarReadsThem() async throws {
        let transport = PathTransport(["/api/v1/streaming/68185a0d/decide": (200, hlsAnswer)])
        _ = try await session(transport).decide("68185a0d", capabilities: .avPlayer(hevcHardwareDecode: true), startOffset: 1740.9)

        let request = try #require(await transport.requests.first)
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer jwt-1")
        let body = try json(request.httpBody)
        #expect(body["containers"] as? [String] == ["mp4", "m4v", "mov"])
        #expect((body["codecs"] as? [String: [String]])?["video"] == ["h264", "hevc"])
        #expect((body["hls_codecs"] as? [String: [String]])?["audio"] == ["aac", "ac3", "eac3"])
        #expect(body["start_offset"] as? Int == 1740)
        #expect(body["max_bitrate"] == nil, "an absent cap is left out, not sent as null")
    }

    @Test func decodesAnHLSDecision() async throws {
        let transport = PathTransport(["/api/v1/streaming/68185a0d/decide": (200, hlsAnswer)])
        let decision = try await session(transport).decide("68185a0d", capabilities: .avPlayer(hevcHardwareDecode: false), startOffset: nil)
        #expect(decision == PlaybackDecision(
            strategy: .hls, streamPath: "/api/v1/streaming/68185a0d/hls/copy-adef-aeac3/stream.m3u8",
            playMethod: "DirectStream", reason: "container", durationSeconds: 7440, startOffsetSeconds: 1736
        ))
        let body = try json(await transport.requests.first?.httpBody)
        #expect(body["start_offset"] == nil)
    }

    @Test func decodesADirectDecision() async throws {
        let transport = PathTransport(["/api/v1/streaming/6f1c/decide": (200, directAnswer)])
        let decision = try await session(transport).decide("6f1c", capabilities: .avPlayer(hevcHardwareDecode: false), startOffset: 30)
        #expect(decision.strategy == .direct)
        #expect(decision.playMethod == "DirectPlay")
        #expect(decision.startOffsetSeconds == 0)
    }

    @Test func aDirectFileSeeksToTheResumePointAndHLSByWhatIsLeft() {
        let direct = PlaybackDecision(strategy: .direct, streamPath: "/d", startOffsetSeconds: 0)
        let hls = PlaybackDecision(strategy: .hls, streamPath: "/h", startOffsetSeconds: 1736)
        #expect(direct.seek(toResumeAt: 1740.5) == 1740.5)
        #expect(hls.seek(toResumeAt: 1740.5) == 4.5)
        #expect(hls.seek(toResumeAt: 1000) == 0, "never a negative seek")
    }

    @Test func theMediaURLCarriesTheTokenAndKeepsItsOwnQuery() async throws {
        let nectar = session(PathTransport([:]), token: "jwt-9")
        let url = try await nectar.mediaURL("/api/v1/streaming/6f1c/hls/k/stream.m3u8?x=1")
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        #expect(components.host == "nectar.test")
        #expect(components.path == "/api/v1/streaming/6f1c/hls/k/stream.m3u8")
        #expect(components.queryItems == [URLQueryItem(name: "x", value: "1"), URLQueryItem(name: "access_token", value: "jwt-9")])
    }

    @Test func noTokensMeansNoMediaURL() async {
        let nectar = NectarSession(
            baseURL: URL(string: "https://nectar.test")!, tokenEndpoint: URL(string: "https://nectar.test/token")!,
            clientID: "nectar-tv", store: InMemoryTokenStore(nil), transport: PathTransport([:])
        )
        await #expect(throws: NectarSessionError.signedOut) { try await nectar.mediaURL("/api/v1/streaming/x/direct") }
    }

    @Test func progressPostsPositionPausedAndCompleted() async throws {
        let transport = PathTransport(["/api/v1/media/6f1c/progress": (200, "{}")])
        try await session(transport).reportProgress("6f1c", positionSeconds: 812.25, paused: true)
        try await session(transport).reportProgress("6f1c", positionSeconds: -3, completed: true)

        let requests = await transport.requests
        let first = try json(requests[0].httpBody)
        #expect(requests[0].httpMethod == "POST")
        // nectar's ProgressBody is z.number().int(): a fraction is a 422 (seen on the Apple TV, 2026-10-18).
        #expect(first["position_seconds"] as? Int == 812)
        #expect(String(decoding: try #require(requests[0].httpBody), as: UTF8.self).contains("\"position_seconds\":812"))
        #expect(first["paused"] as? Bool == true)
        #expect(first["completed"] == nil)
        let second = try json(requests[1].httpBody)
        #expect(second["position_seconds"] as? Int == 0, "nectar rejects a negative position")
        #expect(second["completed"] as? Bool == true)
    }

    @Test func aPostThatGets401RefreshesAndResendsTheBody() async throws {
        let store = InMemoryTokenStore(TokenSet(accessToken: "jwt-1", tokenType: "Bearer", expiresIn: nil, refreshToken: "r1"))
        let transport = SequenceTransport([
            (401, "{}"),
            (200, #"{"access_token":"jwt-2","token_type":"Bearer","expires_in":86400,"refresh_token":"r2"}"#),
            (200, "{}"),
        ])
        let nectar = NectarSession(baseURL: URL(string: "https://nectar.test")!, tokenEndpoint: URL(string: "https://nectar.test/token")!, clientID: "nectar-tv", store: store, transport: transport)
        try await nectar.reportProgress("6f1c", positionSeconds: 10)
        let requests = await transport.requests
        #expect(requests.count == 3)
        #expect(requests[2].value(forHTTPHeaderField: "Authorization") == "Bearer jwt-2")
        #expect(requests[2].httpBody == requests[0].httpBody)
    }
}

/// Answers in order, whatever the path.
private actor SequenceTransport: HTTPTransport {
    private var answers: [(Int, String)]
    private(set) var requests: [URLRequest] = []

    init(_ answers: [(Int, String)]) {
        self.answers = answers
    }

    nonisolated func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        try await answer(request)
    }

    private func answer(_ request: URLRequest) -> (Data, HTTPURLResponse) {
        requests.append(request)
        let (status, body) = answers.removeFirst()
        return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }
}
