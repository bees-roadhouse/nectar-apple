import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import os

private let log = Logger(subsystem: "com.beesroadhouse.nectar", category: "images")

/// Where artwork bytes come from when the cache doesn't have them: the network, or a test double.
public protocol ImageFetcher: Sendable {
    func fetch(_ url: URL) async throws -> (Data, HTTPURLResponse)
}

/// A decoded bitmap, ready to draw.
public final class ArtworkBitmap: @unchecked Sendable {
    public let cgImage: CGImage
    public var width: Int { cgImage.width }
    public var height: Int { cgImage.height }

    init(_ cgImage: CGImage) {
        self.cgImage = cgImage
    }
}

public enum ImageCacheError: Error {
    case badStatus(Int)
    case undecodable
}

/// Artwork kept on the device, so unchanged images aren't fetched again (Nate, 2026-10-19, #37).
///
/// Two layers: the bytes on disk under `Caches/`, kept until their `max-age` runs out and dropped
/// least-recently-used past `diskLimit`; and decoded bitmaps in memory, one per drawn size, decoded
/// straight to that size rather than at the file's full resolution. nectar already serves each
/// width as its own URL (`…/w{N}`), so the URL is the key; an `access_token` query never is.
public actor ImageCache {

    /// The app's cache: 300 MB on disk, fetched without the shared URLCache in the way.
    public static let shared = ImageCache(
        directory: FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appending(path: "nectar-images"),
        fetcher: URLSessionImageFetcher()
    )

    private let directory: URL
    private let fetcher: any ImageFetcher
    private let diskLimit: Int
    private let now: @Sendable () -> Date
    private let memory = NSCache<NSString, ArtworkBitmap>()
    private var inFlight: [String: Task<Data, Error>] = [:]

    /// Kept a day when the server doesn't say.
    private static let defaultLifetime: TimeInterval = 86_400

    public init(directory: URL, fetcher: any ImageFetcher, diskLimit: Int = 300 * 1024 * 1024, now: @escaping @Sendable () -> Date = Date.init) {
        self.directory = directory
        self.fetcher = fetcher
        self.diskLimit = diskLimit
        self.now = now
        memory.totalCostLimit = 128 * 1024 * 1024
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    /// The image at `url`, decoded so its longer side is at most `maxPixelSize`.
    public func image(for url: URL, maxPixelSize: Int) async throws -> ArtworkBitmap {
        let key = Self.key(for: url)
        let memoryKey = "\(key)@\(maxPixelSize)" as NSString
        if let hit = memory.object(forKey: memoryKey) { return hit }
        let data = try await bytes(for: url, key: key)
        guard let bitmap = Self.decode(data, maxPixelSize: maxPixelSize) else { throw ImageCacheError.undecodable }
        memory.setObject(bitmap, forKey: memoryKey, cost: bitmap.width * bitmap.height * 4)
        return bitmap
    }

    /// The file's bytes as served, from disk when it's there: for handing artwork on (Now Playing) rather than drawing it.
    public func data(for url: URL) async throws -> Data {
        try await bytes(for: url, key: Self.key(for: url))
    }

    /// Fetch what isn't on disk yet, for rows about to come into view. Nothing is decoded.
    public func prefetch(_ urls: [URL]) async {
        await withTaskGroup(of: Void.self) { group in
            for url in Set(urls) {
                group.addTask { _ = try? await self.bytes(for: url, key: Self.key(for: url)) }
            }
        }
    }

    /// Marks an entry as just used, for least-recently-used eviction.
    func touch(_ url: URL) throws {
        try FileManager.default.setAttributes([.modificationDate: now()], ofItemAtPath: file(for: Self.key(for: url)).path)
    }

    /// The URL without its `access_token`: a refreshed token is the same picture.
    public static func key(for url: URL) -> String {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: true) else { return url.absoluteString }
        components.queryItems = components.queryItems?.filter { $0.name != "access_token" }
        if components.queryItems?.isEmpty == true { components.queryItems = nil }
        return components.url?.absoluteString ?? url.absoluteString
    }

    // MARK: - Bytes: disk, then one shared fetch

    private func bytes(for url: URL, key: String) async throws -> Data {
        if let data = readDisk(key) { return data }
        if let running = inFlight[key] { return try await running.value }
        let fetcher = fetcher
        // The fetch and the store are one task, so a second asker waits for the bytes and the disk write both.
        let task = Task { () throws -> Data in
            let (data, response) = try await fetcher.fetch(url)
            guard response.statusCode == 200 else { throw ImageCacheError.badStatus(response.statusCode) }
            if let lifetime = Self.lifetime(cacheControl: response.value(forHTTPHeaderField: "Cache-Control")) {
                await self.writeDisk(data, key: key, lifetime: lifetime)
            }
            return data
        }
        inFlight[key] = task
        defer { inFlight[key] = nil }
        return try await task.value
    }

    // MARK: - Disk

    private func file(for key: String) -> URL {
        let digest = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
        return directory.appending(path: digest)
    }

    /// The bytes if they're on disk and still fresh. An entry is an 8-byte expiry, then the image.
    private func readDisk(_ key: String) -> Data? {
        let file = file(for: key)
        guard let stored = try? Data(contentsOf: file), stored.count > 8 else { return nil }
        let expiry = Date(timeIntervalSince1970: stored.prefix(8).withUnsafeBytes { $0.loadUnaligned(as: Double.self) })
        guard expiry > now() else {
            try? FileManager.default.removeItem(at: file)
            return nil
        }
        try? FileManager.default.setAttributes([.modificationDate: now()], ofItemAtPath: file.path)
        return stored.dropFirst(8)
    }

    private func writeDisk(_ data: Data, key: String, lifetime: TimeInterval) {
        var expiry = now().addingTimeInterval(lifetime).timeIntervalSince1970
        var stored = Data(bytes: &expiry, count: 8)
        stored.append(data)
        let file = file(for: key)
        do {
            try stored.write(to: file, options: .atomic)
            try FileManager.default.setAttributes([.modificationDate: now()], ofItemAtPath: file.path)
        } catch {
            log.error("image cache write failed: \(String(describing: error), privacy: .public)")
        }
        evict()
    }

    /// Oldest-used first, until the store fits.
    private func evict() {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileAllocatedSizeKey, .fileSizeKey]
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys) else { return }
        var entries = files.compactMap { url -> (URL, Date, Int)? in
            guard let values = try? url.resourceValues(forKeys: Set(keys)) else { return nil }
            return (url, values.contentModificationDate ?? .distantPast, values.fileSize ?? 0)
        }
        var total = entries.reduce(0) { $0 + $1.2 }
        guard total > diskLimit else { return }
        entries.sort { $0.1 < $1.1 }
        for (url, _, size) in entries where total > diskLimit {
            try? FileManager.default.removeItem(at: url)
            total -= size
        }
    }

    // MARK: - Decoding

    /// ImageIO's thumbnailer decodes straight to the drawn size; it never scales up.
    static func decode(_ data: Data, maxPixelSize: Int) -> ArtworkBitmap? {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: max(1, maxPixelSize),
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary).map(ArtworkBitmap.init)
    }

    /// `max-age` from `Cache-Control`; nil for `no-store`.
    static func lifetime(cacheControl: String?) -> TimeInterval? {
        guard let cacheControl else { return defaultLifetime }
        let directives = cacheControl.lowercased().split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        if directives.contains("no-store") { return nil }
        for directive in directives where directive.hasPrefix("max-age=") {
            if let seconds = TimeInterval(directive.dropFirst("max-age=".count)) { return seconds }
        }
        return defaultLifetime
    }
}

/// Artwork from the network, past the shared URLCache (this cache is the cache), counted in the log.
public struct URLSessionImageFetcher: ImageFetcher {
    private let session: URLSession

    public init() {
        let configuration = URLSessionConfiguration.default
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: configuration)
    }

    public func fetch(_ url: URL) async throws -> (Data, HTTPURLResponse) {
        // The path only: an image URL never carries the token, but a query is no business of the log.
        log.info("image fetch \(url.host() ?? "-", privacy: .public)\(url.path(), privacy: .public)")
        let (data, response) = try await session.data(from: url)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        return (data, http)
    }
}
