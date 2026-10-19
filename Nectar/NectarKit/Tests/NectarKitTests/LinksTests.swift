import Foundation
@testable import NectarKit
import Testing

struct NectarLinkTests {

    @Test func itemAndPlayLinksRoundTrip() throws {
        #expect(NectarLink.item("7aa2c5bb").url.absoluteString == "nectar://item/7aa2c5bb")
        #expect(NectarLink.play("7aa2c5bb").url.absoluteString == "nectar://play/7aa2c5bb")
        #expect(NectarLink(url: NectarLink.item("abc").url) == .item("abc"))
        #expect(NectarLink(url: NectarLink.play("abc").url) == .play("abc"))
    }

    @Test(arguments: ["nectar://item", "nectar://item/", "nectar://elsewhere/abc", "https://item/abc", "nectar://item/a/b", "nectar:item/abc"])
    func anythingElseIsNotALink(_ link: String) throws {
        #expect(NectarLink(url: try #require(URL(string: link))) == nil)
    }
}
