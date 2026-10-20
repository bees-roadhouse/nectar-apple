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

private func session(_ transport: PathTransport) -> NectarSession {
    NectarSession(
        baseURL: URL(string: "https://nectar.test")!,
        tokenEndpoint: URL(string: "https://nectar.test/token")!,
        clientID: "nectar-tv",
        store: InMemoryTokenStore(TokenSet(accessToken: "jwt-1", tokenType: "Bearer", expiresIn: nil, refreshToken: "r1")),
        transport: transport
    )
}

/// Telling nectar a viewer has left (#94, nectar#547), as the web's `goodbye()` does: the stream parks at once
/// and its transcoder slot frees, instead of waiting for the 45 s no-fetch backstop.
@Suite("Goodbye")
struct GoodbyeTests {

    @Test func anHLSStreamSaysGoodbyeBesideItsPlaylist() {
        let media = PlaybackDecision(strategy: .hls, streamPath: "/api/v1/streaming/f2d8/hls/copy-a2-acopy/7c1e/stream.m3u8")
        let master = PlaybackDecision(strategy: .hls, streamPath: "/api/v1/streaming/f2d8/hls/tx-h264/7c1e/master.m3u8?api_key=x")
        #expect(media.goodbyePath == "/api/v1/streaming/f2d8/hls/copy-a2-acopy/7c1e/goodbye")
        #expect(master.goodbyePath == "/api/v1/streaming/f2d8/hls/tx-h264/7c1e/goodbye", "the playlist's query goes with it")
    }

    @Test func aDirectFileOrALocalCopyHasNoStreamToRelease() {
        #expect(PlaybackDecision(strategy: .direct, streamPath: "/api/v1/streaming/6f1c/direct").goodbyePath == nil)
        #expect(PlaybackDecision(strategy: .hls, streamPath: "/api/v1/streaming/6f1c/something-else").goodbyePath == nil)
    }

    @Test func goodbyePostsWithNoBody() async throws {
        let transport = PathTransport(["/api/v1/streaming/f2d8/hls/copy-a2-acopy/7c1e/goodbye": (202, "")])
        let decision = PlaybackDecision(strategy: .hls, streamPath: "/api/v1/streaming/f2d8/hls/copy-a2-acopy/7c1e/stream.m3u8")
        try await session(transport).goodbye(decision)

        let request = try #require(await transport.requests.first)
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer jwt-1")
        #expect(request.httpBody == nil || request.httpBody?.isEmpty == true)
    }

    @Test func aDecisionWithNoStreamSendsNothing() async throws {
        let transport = PathTransport([:])
        try await session(transport).goodbye(PlaybackDecision(strategy: .direct, streamPath: "/api/v1/streaming/6f1c/direct"))
        #expect(await transport.requests.isEmpty)
    }
}
