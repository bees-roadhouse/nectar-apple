import AVFoundation
import Foundation
import Testing
@testable import NectarKit

/// nectar-apple #119 against nectar #715: every trailer a title has, in nectar's order, autoplaying one into the next,
/// with the remote's left and right moving between them.
@Suite("Trailers")
struct TrailerTests {

    private func detail(_ item: String) throws -> ItemDetail {
        try JSONDecoder().decode(ItemDetail.self, from: Data(#"{"item":{"id":"m1","item_type":"movie","title":"Arrival",\#(item)}}"#.utf8))
    }

    private func trailer(_ id: String, ready: Bool = true) -> Trailer {
        Trailer(id: id, path: "/api/v1/media/m1/trailers/\(id)", title: id, kind: .trailer, isReady: ready)
    }

    @Test func aTitleListsItsTrailersInNectarsOrder() throws {
        let item = try detail(#"""
        "trailer_url":"/api/v1/media/m1/trailers/t1",
        "trailers":[
          {"id":"t1","url":"/api/v1/media/m1/trailers/t1","title":"Official Trailer","kind":"trailer","official":true,"runtime_seconds":142,"language":"en","ready":true},
          {"id":"t2","url":"/api/v1/media/m1/trailers/t2","title":null,"kind":"teaser","official":false,"runtime_seconds":null,"language":null,"ready":false},
          {"id":"t3","url":"/api/v1/media/m1/trailers/t3","title":"Behind the scenes","kind":"making_of","official":true,"ready":true}
        ]
        """#)
        #expect(item.trailers.map(\.id) == ["t1", "t2", "t3"])
        #expect(item.trailers[0] == Trailer(
            id: "t1", path: "/api/v1/media/m1/trailers/t1", title: "Official Trailer", kind: .trailer, official: true,
            runtimeSeconds: 142, language: "en", isReady: true
        ))
        #expect(item.trailers[1].title == nil && item.trailers[1].kind == .teaser && !item.trailers[1].isReady)
        #expect(item.trailers[2].kind == .other, "a kind the TV doesn't know yet still plays")
    }

    @Test func anOlderServersSingleTrailerBecomesAListOfOne() throws {
        let item = try detail(#""trailer_url":"/api/v1/media/m1/trailer""#)
        #expect(item.trailers.map(\.path) == ["/api/v1/media/m1/trailer"])
        #expect(item.trailers.first?.isReady == true)
    }

    @Test func anEmptyListMeansNoTrailers() throws {
        #expect(try detail(#""trailers":[],"trailer_url":null"#).trailers.isEmpty)
        #expect(try detail(#""trailer_url":null"#).trailers.isEmpty)
    }

    @Test func theQueueStartsOnTheFirstReadyTrailerAndSkipsUnreadyOnes() throws {
        var queue = try #require(TrailerQueue([trailer("a", ready: false), trailer("b"), trailer("c", ready: false), trailer("d")]))
        #expect(queue.current?.id == "b")
        #expect(queue.position == TrailerQueue.Position(number: 1, of: 2), "counted among the ready ones")
        #expect(queue.previous == nil && queue.next?.id == "d")
        #expect(queue.advance()?.id == "d")
        #expect(queue.position == TrailerQueue.Position(number: 2, of: 2))
        #expect(queue.next == nil)
        #expect(queue.advance() == nil, "after the last one, the trailers close")
        #expect(queue.current?.id == "d", "and the queue doesn't move past it")
        #expect(queue.goBack()?.id == "b")
        #expect(queue.unready.map(\.id) == ["a", "c"])
    }

    @Test func aSingleTrailerHasNowhereToSkip() throws {
        let queue = try #require(TrailerQueue([trailer("a")]))
        #expect(queue.next == nil && queue.previous == nil)
        #expect(queue.position == TrailerQueue.Position(number: 1, of: 1))
    }

    @Test func noReadyTrailerMeansNoQueueYet() {
        #expect(TrailerQueue([]) == nil)
        #expect(TrailerQueue([trailer("a", ready: false)]) == nil)
    }

    @Test func aTrailerThatLandsJoinsTheQueueWithoutMovingThePlayingOne() throws {
        var queue = try #require(TrailerQueue([trailer("a"), trailer("b", ready: false), trailer("c", ready: false)]))
        #expect(queue.next == nil)
        queue.refresh(with: [trailer("a"), trailer("b"), trailer("c", ready: false)])
        #expect(queue.current?.id == "a")
        #expect(queue.next?.id == "b")
        #expect(queue.unready.map(\.id) == ["c"])
    }

    @Test func aTrailerWhoseFetchFailedLeavesTheList() throws {
        var queue = try #require(TrailerQueue([trailer("a"), trailer("b", ready: false), trailer("c")]))
        queue.refresh(with: [trailer("a"), trailer("c")])
        #expect(queue.current?.id == "a" && queue.next?.id == "c" && queue.unready.isEmpty)
    }

    @Test func ifThePlayingTrailerDisappearsTheQueueCarriesOnFromItsPlace() throws {
        var queue = try #require(TrailerQueue([trailer("a"), trailer("b"), trailer("c")]))
        _ = queue.advance()
        queue.refresh(with: [trailer("a"), trailer("c")])
        #expect(queue.current?.id == "c", "the next one at or after b's old place")
    }
}

private actor Recorder: HTTPTransport {
    private let status: Int
    private(set) var requests: [URLRequest] = []

    init(status: Int) {
        self.status = status
    }

    nonisolated func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        try await answer(request)
    }

    private func answer(_ request: URLRequest) -> (Data, HTTPURLResponse) {
        requests.append(request)
        return (Data(), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Retry-After": "20"])!)
    }
}

@Suite("Starting a trailer's fetch")
struct TrailerFetchTests {

    private func session(_ transport: Recorder) -> NectarSession {
        NectarSession(
            baseURL: URL(string: "https://nectar.test")!,
            tokenEndpoint: URL(string: "https://nectar.test/token")!,
            clientID: "nectar-tv",
            store: InMemoryTokenStore(TokenSet(accessToken: "jwt-1", tokenType: "Bearer", expiresIn: nil, refreshToken: "r1")),
            transport: transport
        )
    }

    /// nectar #715: a HEAD on an unready trailer answers 202 and starts its fetch, without pulling the file.
    @Test func aHeadStartsTheFetchWithoutTheFile() async throws {
        let server = Recorder(status: 202)
        try await session(server).head("/api/v1/media/m1/trailers/t2")
        let request = try #require(await server.requests.first)
        #expect(request.httpMethod == "HEAD")
        #expect(request.url?.path == "/api/v1/media/m1/trailers/t2")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer jwt-1")
    }

    @Test func aFailedFetchIsAnError() async {
        await #expect(throws: NectarSessionError.self) { try await session(Recorder(status: 404)).head("/api/v1/media/m1/trailers/t9") }
    }
}

@Suite("A trailer's info panel")
struct TrailerNowPlayingTests {

    private func text(_ items: [AVMetadataItem], _ identifier: AVMetadataIdentifier) -> String? {
        items.first { $0.identifier == identifier }?.value as? String
    }

    @Test func itNamesTheTrailerAndItsPlaceAmongTheFilmsTrailers() {
        let trailer = Trailer(id: "t2", path: "/t2", title: "Official Trailer 2")
        let items = NowPlaying.metadata(for: trailer, of: "Arrival", position: TrailerQueue.Position(number: 2, of: 3))
        #expect(text(items, .commonIdentifierTitle) == "Official Trailer 2")
        #expect(text(items, .iTunesMetadataTrackSubTitle) == "Arrival · 2 of 3")
    }

    @Test func anUnnamedSingleTrailerIsJustTheFilmsTrailer() {
        let items = NowPlaying.metadata(for: Trailer(id: "t1", path: "/t1"), of: "Arrival", position: TrailerQueue.Position(number: 1, of: 1))
        #expect(text(items, .commonIdentifierTitle) == "Trailer")
        #expect(text(items, .iTunesMetadataTrackSubTitle) == "Arrival", "no \"1 of 1\"")
    }
}
