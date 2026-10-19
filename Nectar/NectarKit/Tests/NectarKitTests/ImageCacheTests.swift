import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import NectarKit

/// Answers every URL with the same PNG and counts what reached "the network".
private actor CountingFetcher: ImageFetcher {
    private let png: Data
    private let cacheControl: String?
    private(set) var fetched: [URL] = []

    init(png: Data, cacheControl: String? = "public, max-age=31536000, immutable") {
        self.png = png
        self.cacheControl = cacheControl
    }

    func fetch(_ url: URL) async throws -> (Data, HTTPURLResponse) {
        fetched.append(url)
        try await Task.sleep(for: .milliseconds(20)) // long enough for concurrent asks to overlap
        let headers = cacheControl.map { ["Cache-Control": $0] } ?? [:]
        return (png, HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: headers)!)
    }
}

private func png(width: Int, height: Int) -> Data {
    let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    context.setFillColor(CGColor(red: 0.9, green: 0.6, blue: 0.2, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    let out = NSMutableData()
    let destination = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, context.makeImage()!, nil)
    CGImageDestinationFinalize(destination)
    return out as Data
}

private final class FakeNow: @unchecked Sendable {
    var date: Date
    init(_ date: Date) { self.date = date }
}

private func scratchDirectory() -> URL {
    FileManager.default.temporaryDirectory.appending(path: "nectar-image-cache-tests-\(UUID().uuidString)")
}

private let poster = URL(string: "https://nectar.test/api/v1/images/i1/w480")!

@Suite("Image cache")
struct ImageCacheTests {

    @Test func aSecondAskComesFromMemory() async throws {
        let fetcher = CountingFetcher(png: png(width: 480, height: 720))
        let cache = ImageCache(directory: scratchDirectory(), fetcher: fetcher)
        _ = try await cache.image(for: poster, maxPixelSize: 360)
        _ = try await cache.image(for: poster, maxPixelSize: 360)
        #expect(await fetcher.fetched.count == 1)
    }

    @Test func aColdStartIsServedFromDisk() async throws {
        let directory = scratchDirectory()
        let bytes = png(width: 480, height: 720)
        let first = CountingFetcher(png: bytes)
        _ = try await ImageCache(directory: directory, fetcher: first).image(for: poster, maxPixelSize: 360)

        // A new cache on the same directory is the app's next launch: empty memory, warm disk.
        let second = CountingFetcher(png: bytes)
        let image = try await ImageCache(directory: directory, fetcher: second).image(for: poster, maxPixelSize: 360)
        #expect(await second.fetched.isEmpty, "the next launch must not refetch unchanged artwork")
        #expect(image.height == 360)
    }

    @Test func theTokenIsNotPartOfTheKey() {
        let a = URL(string: "https://nectar.test/api/v1/images/i1/w480?access_token=one")!
        let b = URL(string: "https://nectar.test/api/v1/images/i1/w480?access_token=two")!
        #expect(ImageCache.key(for: a) == ImageCache.key(for: b))
        #expect(ImageCache.key(for: a) == ImageCache.key(for: poster))
        #expect(ImageCache.key(for: poster) != ImageCache.key(for: URL(string: "https://nectar.test/api/v1/images/i1/w780")!), "the width is part of the key")
    }

    @Test func bitmapsAreDecodedAtTheSizeTheyAreDrawn() async throws {
        let cache = ImageCache(directory: scratchDirectory(), fetcher: CountingFetcher(png: png(width: 1280, height: 720)))
        let image = try await cache.image(for: poster, maxPixelSize: 400)
        #expect(max(image.width, image.height) == 400)
    }

    @Test func concurrentAsksShareOneRequest() async throws {
        let fetcher = CountingFetcher(png: png(width: 480, height: 720))
        let cache = ImageCache(directory: scratchDirectory(), fetcher: fetcher)
        async let a = cache.image(for: poster, maxPixelSize: 360)
        async let b = cache.image(for: poster, maxPixelSize: 200)
        _ = try await (a, b)
        #expect(await fetcher.fetched.count == 1)
    }

    @Test func anExpiredEntryIsFetchedAgain() async throws {
        let directory = scratchDirectory()
        let bytes = png(width: 100, height: 100)
        let clock = FakeNow(Date(timeIntervalSince1970: 1_000_000))
        let fetcher = CountingFetcher(png: bytes, cacheControl: "max-age=60")
        _ = try await ImageCache(directory: directory, fetcher: fetcher, now: { clock.date }).image(for: poster, maxPixelSize: 100)
        clock.date += 61
        let later = ImageCache(directory: directory, fetcher: fetcher, now: { clock.date })
        _ = try await later.image(for: poster, maxPixelSize: 100)
        #expect(await fetcher.fetched.count == 2)
    }

    @Test func theDiskStaysUnderItsCapByDroppingTheLeastRecentlyUsed() async throws {
        let directory = scratchDirectory()
        let bytes = png(width: 64, height: 64)
        let fetcher = CountingFetcher(png: bytes)
        // Room for two entries, not three.
        let cache = ImageCache(directory: directory, fetcher: fetcher, diskLimit: bytes.count * 2 + bytes.count / 2)
        let urls = (1...3).map { URL(string: "https://nectar.test/api/v1/images/i\($0)/w342")! }
        _ = try await cache.image(for: urls[0], maxPixelSize: 64)
        try await Task.sleep(for: .milliseconds(10))
        _ = try await cache.image(for: urls[1], maxPixelSize: 64)
        try await Task.sleep(for: .milliseconds(10))
        try await cache.touch(urls[0]) // used again: now urls[1] is the oldest
        try await Task.sleep(for: .milliseconds(10))
        _ = try await cache.image(for: urls[2], maxPixelSize: 64)

        let next = ImageCache(directory: directory, fetcher: fetcher)
        _ = try await next.image(for: urls[0], maxPixelSize: 64)
        _ = try await next.image(for: urls[1], maxPixelSize: 64)
        #expect(await fetcher.fetched == [urls[0], urls[1], urls[2], urls[1]], "only the least recently used entry was dropped")
    }

    @Test func prefetchWarmsTheDiskWithoutDecoding() async throws {
        let fetcher = CountingFetcher(png: png(width: 480, height: 720))
        let directory = scratchDirectory()
        await ImageCache(directory: directory, fetcher: fetcher).prefetch([poster, poster])
        _ = try await ImageCache(directory: directory, fetcher: fetcher).image(for: poster, maxPixelSize: 360)
        #expect(await fetcher.fetched.count == 1)
    }
}
