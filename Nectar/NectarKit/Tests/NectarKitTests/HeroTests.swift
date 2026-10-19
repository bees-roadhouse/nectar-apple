import Foundation
import Testing
@testable import NectarKit

@Suite("Hero billboard")
struct HeroTests {

    @Test func aCardCarriesWhatTheBillboardShows() throws {
        let json = #"""
        {"id":"m1","item_type":"movie","title":"Arrival","year":2016,"overview":"A linguist works with the military.",
         "logo_url":"/api/v1/images/l1","backdrop_url":"/api/v1/images/b1","genres":["Drama","Science Fiction"]}
        """#
        let card = try JSONDecoder().decode(MediaCard.self, from: Data(json.utf8))
        #expect(card.overview == "A linguist works with the military.")
        #expect(card.logoPath == "/api/v1/images/l1")
        #expect(card.genres == ["Drama", "Science Fiction"])
    }

    @Test func slidesAreWhatYoureWatchingThenWhatsNew() {
        let watching = [MediaCard(id: "e1", itemType: "episode", title: "Ep"), MediaCard(id: "m1", itemType: "movie", title: "Arrival")]
        let recent = [
            MediaCard(id: "m1", itemType: "movie", title: "Arrival"),     // already in continue watching
            MediaCard(id: "a1", itemType: "album", title: "OK Computer"), // not billboard material
            MediaCard(id: "s1", itemType: "series", title: "Dark"),
            MediaCard(id: "m2", itemType: "movie", title: "Dune"),
            MediaCard(id: "m3", itemType: "movie", title: "Heat"),
            MediaCard(id: "m4", itemType: "movie", title: "Ran"),
        ]
        let slides = HeroSlide.pick(watching: watching, recent: recent)
        #expect(slides.map(\.card.id) == ["e1", "m1", "s1", "m2", "m3"], "five at most, continue watching first, no repeats, no albums")
        #expect(slides.map(\.resumable) == [true, true, false, false, false])
    }

    @Test func nothingToShowIsNoBillboard() {
        #expect(HeroSlide.pick(watching: [], recent: [MediaCard(id: "a1", itemType: "album", title: "x")]).isEmpty)
    }
}
