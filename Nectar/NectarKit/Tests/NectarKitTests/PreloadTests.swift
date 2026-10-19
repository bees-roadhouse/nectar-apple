import Foundation
@testable import NectarKit
import Testing

private let gb: Int64 = 1_000_000_000

private func entry(_ id: String, gigabytes: Int64, completed: TimeInterval, played: TimeInterval? = nil) -> PreloadEntry {
    PreloadEntry(itemID: id, title: id, fileName: "\(id).mp4", bytes: gigabytes * gb,
                 completedAt: Date(timeIntervalSince1970: completed), lastPlayedAt: played.map { Date(timeIntervalSince1970: $0) })
}

private func source(container: String?, video: String?, audio: [String]) -> PlaybackSource {
    PlaybackSource(container: container, videoCodec: video, resolution: nil, hdr: nil, bitrate: nil, sizeBytes: nil,
                   audioTracks: audio.enumerated().map { .init(streamIndex: $0.offset, codec: $0.element, language: nil, title: nil, channels: nil, channelLayout: nil, isDefault: $0.offset == 0) })
}

struct PreloadTests {

    private let tv = PlaybackCapabilities.avPlayer(hevcHardwareDecode: true)

    @Test func onlyAFileTheTVPlaysAsItIsCanBePreloaded() {
        #expect(PreloadIndex.canPlayLocally(source(container: "mp4", video: "hevc", audio: ["eac3"]), capabilities: tv))
        #expect(PreloadIndex.canPlayLocally(source(container: "MOV", video: "h264", audio: ["dts", "aac"]), capabilities: tv))
        #expect(!PreloadIndex.canPlayLocally(source(container: "mkv", video: "hevc", audio: ["eac3"]), capabilities: tv))
        #expect(!PreloadIndex.canPlayLocally(source(container: "mp4", video: "av1", audio: ["aac"]), capabilities: tv))
        #expect(!PreloadIndex.canPlayLocally(source(container: "mp4", video: "h264", audio: ["truehd"]), capabilities: tv))
        #expect(!PreloadIndex.canPlayLocally(source(container: nil, video: "h264", audio: ["aac"]), capabilities: tv))
    }

    @Test func aPreloadedTitleSaysSoAndNeedsNoReason() {
        let lines = PlaybackInfo.lines(decision: .local(URL(fileURLWithPath: "/tmp/a.mp4")), source: nil, observedBitrate: nil, presentation: nil)
        #expect(lines.first?.value == "Pre-loaded")
        #expect(lines.last?.value == "File")
    }

    @Test func roomIsMadeLeastRecentlyPlayedFirst() {
        let index = PreloadIndex(entries: [
            entry("watched-last-week", gigabytes: 4, completed: 100, played: 500),
            entry("never-played", gigabytes: 6, completed: 300),
            entry("watched-yesterday", gigabytes: 5, completed: 200, played: 900),
        ])
        #expect(index.usedBytes == 15 * gb)
        // A 10 GB title into a 20 GB budget with plenty of disk: 5 GB must go, and the oldest touch (6 GB) is enough.
        #expect(index.evictions(for: 10 * gb, budget: 20 * gb, freeSpace: 500 * gb) == ["never-played"])
        // 14 GB needs 9 GB gone: the oldest two, the most recently played kept.
        #expect(index.evictions(for: 14 * gb, budget: 20 * gb, freeSpace: 500 * gb) == ["never-played", "watched-last-week"])
        // Room already: nothing goes.
        #expect(index.evictions(for: 2 * gb, budget: 20 * gb, freeSpace: 500 * gb) == [])
    }

    @Test func theDiskKeepsAMarginWhateverTheBudget() {
        let index = PreloadIndex(entries: [entry("a", gigabytes: 3, completed: 1), entry("b", gigabytes: 3, completed: 2)])
        // 6 GB free, 4 GB incoming, 2 GB margin: 0 GB short of the budget but 0 GB of margin left → evict until 2 GB spare.
        #expect(index.evictions(for: 4 * gb, budget: 100 * gb, freeSpace: 4 * gb) == ["a"])
    }

    @Test func aTitleBiggerThanTheBudgetIsRefusedOutright() {
        let index = PreloadIndex(entries: [entry("a", gigabytes: 3, completed: 1)])
        #expect(index.evictions(for: 30 * gb, budget: 25 * gb, freeSpace: 500 * gb) == nil)
    }

    @Test func downloadsUnderWayCountAgainstTheBudget() {
        let index = PreloadIndex(entries: [entry("old", gigabytes: 5, completed: 1)])
        // 5 GB stored and 8 GB already coming: a 6 GB title still fits 20 GB, a 9 GB one needs the old one gone.
        #expect(index.evictions(for: 6 * gb, budget: 20 * gb, freeSpace: 500 * gb, pending: 8 * gb) == [])
        #expect(index.evictions(for: 9 * gb, budget: 20 * gb, freeSpace: 500 * gb, pending: 8 * gb) == ["old"])
        // 8 GB coming and 14 GB more can't fit 20 GB at all.
        #expect(index.evictions(for: 14 * gb, budget: 20 * gb, freeSpace: 500 * gb, pending: 8 * gb) == nil)
    }

    @Test func theNextThreeStartWhereTheSeriesWouldPlay() throws {
        let json = #"{"seasons":[{"season_number":1,"episodes":[\#((1 ... 4).map { n in #"{"id":"e\#(n)","episode_number":\#(n),"season_number":1,"title":"E\#(n)","overview":null,"runtime_seconds":60,"air_date":null,"watched":\#(n == 1),"progress_seconds":0,"thumb_url":null}"# }.joined(separator: ","))]},{"season_number":2,"episodes":[{"id":"s2e1","episode_number":1,"season_number":2,"title":"S2E1","overview":null,"runtime_seconds":60,"air_date":null,"watched":false,"progress_seconds":0,"thumb_url":null}]}]}"#
        let seasons = try JSONDecoder().decode(SeasonList.self, from: Data(json.utf8)).seasons
        #expect(PreloadIndex.nextEpisodes(in: seasons).map(\.id) == ["e2", "e3", "e4"])
        #expect(PreloadIndex.nextEpisodes(in: seasons, count: 5).map(\.id) == ["e2", "e3", "e4", "s2e1"])
    }

    @Test func theStoreKeepsFilesAndTheirIndexTogether() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = PreloadStore(directory: folder)
        let download = folder.appendingPathComponent("tmp-download")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(repeating: 7, count: 1024).write(to: download)

        let saved = try store.add(itemID: "arrival", title: "Arrival", fileExtension: "mp4", from: download, now: Date(timeIntervalSince1970: 10))
        #expect(saved.bytes == 1024)
        #expect(store.file(for: "arrival").map { FileManager.default.fileExists(atPath: $0.path) } == true)
        #expect(!FileManager.default.fileExists(atPath: download.path))

        store.markPlayed("arrival", now: Date(timeIntervalSince1970: 20))
        #expect(PreloadStore(directory: folder).index.entries["arrival"]?.lastPlayedAt == Date(timeIntervalSince1970: 20))

        store.remove("arrival")
        #expect(store.file(for: "arrival") == nil)
        #expect(PreloadStore(directory: folder).index.entries.isEmpty)
    }

    @Test func aFileTheSystemPurgedIsNotOffered() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = PreloadStore(directory: folder)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let download = folder.appendingPathComponent("d")
        try Data([1, 2, 3]).write(to: download)
        let saved = try store.add(itemID: "x", title: "X", fileExtension: "mov", from: download)
        try FileManager.default.removeItem(at: store.directory.appendingPathComponent(saved.fileName))
        // tvOS may clear Caches under pressure: the index forgets what the disk no longer has.
        #expect(store.file(for: "x") == nil)
        #expect(store.index.entries["x"] == nil)
    }
}

/// The children route's shape, for decoding seasons in a test.
private struct SeasonList: Decodable {
    let seasons: [Season]
}
