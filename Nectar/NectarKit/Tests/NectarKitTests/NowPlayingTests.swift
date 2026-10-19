import AVFoundation
import Foundation
import Testing
@testable import NectarKit

private func value(_ items: [AVMetadataItem], _ identifier: AVMetadataIdentifier) async throws -> Any? {
    guard let item = items.first(where: { $0.identifier == identifier }) else { return nil }
    return try await item.load(.value)
}

/// The item route's shape, as much as Now Playing reads.
private let detailJSON = #"""
{"item":{"id":"e1","item_type":"episode","title":"Good News About Hell","overview":"Mark leads a team of office workers.",
 "content_rating":"TV-MA","tagline":null,"genres":["Drama","Mystery"],"runtime_seconds":3420},
 "progress":null}
"""#

@Suite("Now Playing")
struct NowPlayingTests {

    private let episode = MediaCard(id: "e1", itemType: "episode", title: "Good News About Hell", seriesTitle: "Severance",
                                    year: 2022, seasonNumber: 1, episodeNumber: 1)
    private let movie = MediaCard(id: "m1", itemType: "movie", title: "Arrival", year: 2016)

    @Test func theItemRouteDecodesWhatNowPlayingReads() throws {
        let detail = try JSONDecoder().decode(MediaDetail.self, from: Data(detailJSON.utf8))
        #expect(detail.overview == "Mark leads a team of office workers.")
        #expect(detail.genres == ["Drama", "Mystery"])
        #expect(detail.contentRating == "TV-MA")
    }

    @Test func anEpisodeIsTitledByItselfAndSubtitledBySeriesAndNumber() async throws {
        let items = NowPlaying.metadata(for: episode, detail: nil, artwork: nil)
        #expect(try await value(items, .commonIdentifierTitle) as? String == "Good News About Hell")
        #expect(try await value(items, .iTunesMetadataTrackSubTitle) as? String == "Severance · S1 E1")
    }

    @Test func aMovieIsSubtitledByItsYear() async throws {
        let items = NowPlaying.metadata(for: movie, detail: nil, artwork: nil)
        #expect(try await value(items, .commonIdentifierTitle) as? String == "Arrival")
        #expect(try await value(items, .iTunesMetadataTrackSubTitle) as? String == "2016")
    }

    @Test func theDetailAndArtworkFillTheRest() async throws {
        let detail = try JSONDecoder().decode(MediaDetail.self, from: Data(detailJSON.utf8))
        let jpeg = Data([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10])
        let items = NowPlaying.metadata(for: episode, detail: detail, artwork: jpeg)
        #expect(try await value(items, .commonIdentifierDescription) as? String == "Mark leads a team of office workers.")
        #expect(try await value(items, .quickTimeMetadataGenre) as? String == "Drama, Mystery")
        #expect(try await value(items, .iTunesMetadataContentRating) as? String == "TV-MA")
        #expect(try await value(items, .commonIdentifierArtwork) as? Data == jpeg)
        let artwork = try #require(items.first { $0.identifier == .commonIdentifierArtwork })
        #expect(artwork.dataType == kCMMetadataBaseDataType_JPEG as String, "the panel needs the image type to draw it")
    }

    @Test func nothingKnownIsLeftOutRatherThanBlank() {
        let bare = MediaCard(id: "x")
        let items = NowPlaying.metadata(for: bare, detail: nil, artwork: nil)
        #expect(items.isEmpty, "an empty title or subtitle would show as a blank line")
    }

    @Test func pngArtworkIsLabelledPNG() {
        let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        let artwork = NowPlaying.metadata(for: movie, detail: nil, artwork: png).first { $0.identifier == .commonIdentifierArtwork }
        #expect(artwork?.dataType == kCMMetadataBaseDataType_PNG as String)
    }
}
