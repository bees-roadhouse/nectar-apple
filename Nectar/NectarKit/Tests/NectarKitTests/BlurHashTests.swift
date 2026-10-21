import Foundation
import Testing
@testable import NectarKit

/// nectar-apple #114 (nectar#376 slice 2): a blurred preview while artwork loads. The hashes here are built by hand
/// from the format, so what each decodes to is known without trusting the decoder.
@Suite("BlurHash")
struct BlurHashTests {

    private static let digits = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz#$%*+,-.:;=?@[]^_{|}~")

    private func base83(_ value: Int, length: Int) -> String {
        (1 ... length).map { i in String(Self.digits[(value / Int(pow(83, Double(length - i)))) % 83]) }.joined()
    }

    private func rgb(_ pixels: [UInt8], width: Int, x: Int, y: Int) -> (Int, Int, Int) {
        let i = (y * width + x) * 4
        return (Int(pixels[i]), Int(pixels[i + 1]), Int(pixels[i + 2]))
    }

    @Test func aSolidColourDecodesToThatColourEverywhere() throws {
        // One component (size flag 0), no AC terms: only the average colour, 0xFF0000.
        let hash = "00" + base83(0xFF0000, length: 4)
        let pixels = try #require(BlurHash.pixels(hash, width: 8, height: 6))
        #expect(pixels.count == 8 * 6 * 4)
        for y in 0 ..< 6 {
            for x in 0 ..< 8 {
                let (r, g, b) = rgb(pixels, width: 8, x: x, y: y)
                #expect(r == 255 && g == 0 && b == 0)
            }
        }
        #expect(pixels[3] == 255, "opaque")
    }

    /// Two components across (size flag 1) with a full positive AC: bright on the left, dark on the right.
    @Test func aHorizontalTermRunsAcrossTheWidth() throws {
        let hash = "1" + base83(82, length: 1) + base83(0x808080, length: 4) + base83(18 * 19 * 19 + 18 * 19 + 18, length: 2)
        let pixels = try #require(BlurHash.pixels(hash, width: 32, height: 4))
        let left = rgb(pixels, width: 32, x: 0, y: 2)
        let right = rgb(pixels, width: 32, x: 31, y: 2)
        #expect(left.0 > 200 && right.0 < 10, "left \(left), right \(right)")
        #expect(rgb(pixels, width: 32, x: 0, y: 0) == rgb(pixels, width: 32, x: 0, y: 3), "no change down a column")
    }

    /// Two components down (size flag 9): bright at the top, dark at the bottom.
    @Test func aVerticalTermRunsDownTheHeight() throws {
        let hash = "9" + base83(82, length: 1) + base83(0x808080, length: 4) + base83(18 * 19 * 19 + 18 * 19 + 18, length: 2)
        let pixels = try #require(BlurHash.pixels(hash, width: 4, height: 32))
        let top = rgb(pixels, width: 4, x: 1, y: 0)
        let bottom = rgb(pixels, width: 4, x: 1, y: 31)
        #expect(top.0 > 200 && bottom.0 < 10, "top \(top), bottom \(bottom)")
    }

    @Test func aRealHashDecodes() throws {
        // blurha.sh's own example: 4 × 3 components, 28 characters.
        let pixels = try #require(BlurHash.pixels("LEHV6nWB2yk8pyo0adR*.7kCMdnj", width: 32, height: 32))
        #expect(pixels.count == 32 * 32 * 4)
        #expect(BlurHash.image("LEHV6nWB2yk8pyo0adR*.7kCMdnj", width: 32, height: 32)?.width == 32)
    }

    @Test func aMalformedHashGivesNothing() {
        #expect(BlurHash.pixels("", width: 4, height: 4) == nil)
        #expect(BlurHash.pixels("LEHV6nWB2yk8pyo0adR*.7kCMdn", width: 4, height: 4) == nil, "one character short")
        #expect(BlurHash.pixels("00\u{1F600}000", width: 4, height: 4) == nil, "not base 83")
        #expect(BlurHash.pixels("00FF00", width: 0, height: 4) == nil, "no size")
    }
}

/// A hash carries no shape, so a view stretches one decoded preview to whatever frame it draws (Forage, nectar#718):
/// a card only has to pair each image with its own hash.
@Suite("Card blur hashes")
struct CardBlurHashTests {

    @Test func aCardCarriesEachImagesHash() throws {
        let json = #"{"id":"m1","poster_url":"/api/v1/images/p","poster_blurhash":"LEHV6nWB2yk8pyo0adR*.7kCMdnj","backdrop_url":"/api/v1/images/b","backdrop_blurhash":"00FF00"}"#
        let card = try JSONDecoder().decode(MediaCard.self, from: Data(json.utf8))
        #expect(card.posterBlurHash == "LEHV6nWB2yk8pyo0adR*.7kCMdnj")
        #expect(card.backdropBlurHash == "00FF00")
        #expect(card.artworkBlurHash == "00FF00", "the same image artworkPath picks")
    }

    @Test func theArtworkHashFollowsThePosterWhenThereIsNoBackdrop() throws {
        let json = #"{"id":"m1","poster_url":"/api/v1/images/p","poster_blurhash":"00FF00","backdrop_blurhash":"00FFFF"}"#
        let card = try JSONDecoder().decode(MediaCard.self, from: Data(json.utf8))
        #expect(card.artworkPath == "/api/v1/images/p")
        #expect(card.artworkBlurHash == "00FF00", "not the hash of a backdrop it won't draw")
    }

    @Test func aCardWithoutHashesHasNone() throws {
        for json in [#"{"id":"m1","poster_url":"/p","backdrop_url":"/b"}"#, #"{"id":"m1","poster_url":"/p","poster_blurhash":null}"#] {
            let card = try JSONDecoder().decode(MediaCard.self, from: Data(json.utf8))
            #expect(card.posterBlurHash == nil && card.backdropBlurHash == nil && card.artworkBlurHash == nil)
        }
    }
}

/// nectar#376 slice 2's rule: every `X_url` naming a nectar image has an `X_blurhash` beside it (Forage, 2026-10-21).
@Suite("Blur hashes across nectar's payloads")
struct PayloadBlurHashTests {

    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try JSONDecoder().decode(type, from: Data(json.utf8))
    }

    @Test func anEpisodeCarriesItsStillsHash() throws {
        let episode = try decode(Episode.self, #"{"id":"e1","title":"Pilot","thumb_url":"/api/v1/images/t","thumb_blurhash":"00FF00"}"#)
        #expect(episode.thumbBlurHash == "00FF00")
        #expect(try decode(Episode.self, #"{"id":"e1","thumb_url":"/t","thumb_blurhash":null}"#).thumbBlurHash == nil)
    }

    @Test func aSearchTitleCarriesItsPostersHash() throws {
        let hit = try decode(TitleHit.self, #"{"id":"m1","item_type":"movie","title":"Arrival","poster_url":"/p","poster_blurhash":"00FF00"}"#)
        #expect(hit.posterBlurHash == "00FF00")
        #expect(try decode(TitleHit.self, #"{"id":"m1","item_type":"movie","poster_url":"/p"}"#).posterBlurHash == nil)
    }

    @Test func aRecommendationCarriesItsPostersHash() throws {
        let pick = try decode(Recommendation.self, #"{"id":"r1","title":"Arrival","poster_url":"/p","poster_blurhash":"00FF00"}"#)
        #expect(pick.posterBlurHash == "00FF00")
        #expect(try decode(Recommendation.self, #"{"id":"r1","poster_url":"https://image.tmdb.org/p.jpg"}"#).posterBlurHash == nil)
    }
}

/// Capping's pass on #118: the detail backdrop gets its blur too. nectar#718 puts a `blurhash` on each `images[]` entry.
@Suite("Detail blur hashes")
struct DetailBlurHashTests {

    private func detail(_ item: String) throws -> ItemDetail {
        try JSONDecoder().decode(ItemDetail.self, from: Data(#"{"item":{"id":"m1","item_type":"movie","title":"Arrival",\#(item)}}"#.utf8))
    }

    @Test func theBackdropsHashComesFromItsImageEntry() throws {
        let item = try detail(#"""
        "poster_url":"/api/v1/images/p","poster_blurhash":"00FF00",
        "images":[{"image_type":"logo","url":"/api/v1/images/l","blurhash":"00FFFF"},{"image_type":"backdrop","url":"/api/v1/images/b","blurhash":"0000FF"}]
        """#)
        #expect(item.backdropPath == "/api/v1/images/b")
        #expect(item.artworkBlurHash == "0000FF", "the backdrop's own hash, not the logo's")
    }

    @Test func withoutABackdropTheArtworkHashIsThePosters() throws {
        let item = try detail(#""poster_url":"/api/v1/images/p","poster_blurhash":"00FF00","images":[]"#)
        #expect(item.artworkBlurHash == "00FF00")
        #expect(try detail(#""poster_url":"/p","images":[{"image_type":"backdrop","url":"/b","blurhash":null}]"#).artworkBlurHash == nil)
    }
}
