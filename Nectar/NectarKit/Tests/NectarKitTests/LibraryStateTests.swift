import Foundation
import Testing
@testable import NectarKit

@Suite("Library state")
struct LibraryStateTests {

    private func detail(_ state: String) throws -> ItemDetail {
        let json = #"{"item":{"id":"m1","item_type":"movie","title":"Arrival","genres":[],"cast":[],"directors":[],"library_state":"# + state + "}}"
        return try JSONDecoder().decode(ItemDetail.self, from: Data(json.utf8))
    }

    @Test func theServersWordsAreReadAsTheyCome() throws {
        let upgrading = try detail(#"{"state":"upgrading","label":"Upgrading","sentence":"In your library. Nectar is looking for a better copy, up to 4K.","cutoff":"4K","missing_episodes":null}"#)
        #expect(upgrading.libraryState?.label == "Upgrading")
        #expect(upgrading.libraryState?.sentence == "In your library. Nectar is looking for a better copy, up to 4K.")
        #expect(upgrading.libraryState?.isActive == true)
        let missing = try detail(#"{"state":"missing_episodes","label":"2 episodes missing","sentence":"In your library. Nectar is looking for the 2 missing episodes.","cutoff":null,"missing_episodes":2}"#)
        #expect(missing.libraryState?.missingEpisodes == 2)
        #expect(missing.libraryState?.isActive == true)
        let following = try detail(#"{"state":"following","label":"Following","sentence":"In your library. Nectar is watching for new episodes.","cutoff":null,"missing_episodes":null}"#)
        #expect(following.libraryState?.isActive == false)
    }

    @Test func noStateOrAnOddOneLeavesTheTitleReadable() throws {
        #expect(try detail("null").libraryState == nil)
        #expect(try detail(#""not an object""#).libraryState == nil, "a malformed state never fails the page")
        let new = try detail(#"{"state":"something_new","label":"New","sentence":"In your library."}"#)
        #expect(new.libraryState?.label == "New", "a state the app doesn't know still shows the server's words")
    }
}
