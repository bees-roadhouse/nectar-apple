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

@Suite("Card blur previews")
struct CardBlurPreviewTests {

    @Test func aCardCarriesEachImagesHashWithItsShape() throws {
        let json = #"{"id":"m1","poster_url":"/api/v1/images/p","poster_blurhash":"LEHV6nWB2yk8pyo0adR*.7kCMdnj","backdrop_url":"/api/v1/images/b","backdrop_blurhash":"00FF00"}"#
        let card = try JSONDecoder().decode(MediaCard.self, from: Data(json.utf8))
        #expect(card.posterPreview == BlurPreview(hash: "LEHV6nWB2yk8pyo0adR*.7kCMdnj", aspect: 2.0 / 3))
        #expect(card.backdropPreview == BlurPreview(hash: "00FF00", aspect: 16.0 / 9))
        #expect(card.artworkPreview == card.backdropPreview, "the same image artworkPath picks")
    }

    @Test func theArtworkPreviewFollowsThePosterWhenThereIsNoBackdrop() throws {
        let json = #"{"id":"m1","poster_url":"/api/v1/images/p","poster_blurhash":"00FF00","backdrop_blurhash":"00FFFF"}"#
        let card = try JSONDecoder().decode(MediaCard.self, from: Data(json.utf8))
        #expect(card.artworkPath == "/api/v1/images/p")
        #expect(card.artworkPreview == card.posterPreview, "not the hash of a backdrop it won't draw")
    }

    @Test func aPreviewDecodesAtItsImagesShape() throws {
        let poster = try #require(BlurPreview(hash: "00FF00", aspect: BlurPreview.poster).image())
        let backdrop = try #require(BlurPreview(hash: "00FF00", aspect: BlurPreview.backdrop).image())
        #expect((poster.width, poster.height) == (21, 32))
        #expect((backdrop.width, backdrop.height) == (32, 18))
        #expect(BlurPreview(hash: "not a hash", aspect: 1).image() == nil)
    }

    @Test func aCardWithoutHashesHasNoPreview() throws {
        for json in [#"{"id":"m1","poster_url":"/p","backdrop_url":"/b"}"#, #"{"id":"m1","poster_url":"/p","poster_blurhash":null}"#] {
            let card = try JSONDecoder().decode(MediaCard.self, from: Data(json.utf8))
            #expect(card.posterPreview == nil && card.backdropPreview == nil && card.artworkPreview == nil)
        }
    }
}
