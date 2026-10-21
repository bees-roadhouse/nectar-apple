import Testing
@testable import SwiftfinFork

typealias M = SubtitleRenditionMatcher

@Suite("Subtitle rendition matching (nectar-apple #108)")
struct SubtitleRenditionMatcherTests {

    @Test func theNameWinsEvenWhenPositionsLineUp() {
        let renditions = [M.Rendition(name: "English (SDH)", language: "eng", isForced: false), M.Rendition(name: "English", language: "eng", isForced: false)]
        let stream = M.Stream(index: 3, displayTitle: "English", language: "eng", isForced: false)
        #expect(M.rendition(for: stream, in: renditions, embeddedIndexes: [3, 5]) == 1, "position and language would both say 0")
    }

    @Test func anOCRTwinOutsideTheFileMapsByName() {
        let renditions = [M.Rendition(name: "English (SDH)", language: "eng", isForced: false), M.Rendition(name: "English (OCR 94%)", language: "eng", isForced: false)]
        let twin = M.Stream(index: 2003, displayTitle: "English (OCR 94%)", language: "eng", isForced: false)
        #expect(M.rendition(for: twin, in: renditions, embeddedIndexes: [3, 4, 2003]) == 1, "not the first English one")
    }

    @Test func aForcedDefaultFindsTheForcedRenditionOfItsLanguage() {
        let renditions = [M.Rendition(name: nil, language: "eng", isForced: false), M.Rendition(name: nil, language: "eng", isForced: true)]
        let forced = M.Stream(index: 2, displayTitle: nil, language: "eng", isForced: true)
        #expect(M.rendition(for: forced, in: renditions, embeddedIndexes: [2, 3]) == 1)
    }

    @Test func languageTagsOfDifferentFormsAreOneLanguage() {
        let renditions = [M.Rendition(name: nil, language: "fr", isForced: false), M.Rendition(name: nil, language: "en-US", isForced: false)]
        #expect(M.rendition(for: .init(index: 9, displayTitle: nil, language: "eng", isForced: false), in: renditions, embeddedIndexes: []) == 1)
    }

    @Test func withoutNamesOrLanguagesTheOldFallbacksStand() {
        let two = [M.Rendition(name: nil, language: nil, isForced: false), M.Rendition(name: nil, language: nil, isForced: false)]
        #expect(M.rendition(for: .init(index: 5, displayTitle: nil, language: nil, isForced: false), in: two, embeddedIndexes: [4, 5]) == 1, "position")
        let one = [M.Rendition(name: nil, language: nil, isForced: false)]
        #expect(M.rendition(for: .init(index: 7, displayTitle: nil, language: nil, isForced: false), in: one, embeddedIndexes: [1, 2, 7]) == 0, "the only rendition")
        #expect(M.rendition(for: .init(index: 7, displayTitle: nil, language: nil, isForced: false), in: two, embeddedIndexes: [1, 2, 7]) == nil, "nothing to go on")
    }

    @Test func aForcedStreamWithNoForcedRenditionStillGetsItsLanguage() {
        let renditions = [M.Rendition(name: nil, language: "spa", isForced: false), M.Rendition(name: nil, language: "eng", isForced: false), M.Rendition(name: nil, language: "fre", isForced: false)]
        #expect(M.rendition(for: .init(index: 2, displayTitle: nil, language: "eng", isForced: true), in: renditions, embeddedIndexes: [2]) == 1)
    }

    @Test func anImageStreamWithoutATwinMapsToNothingWhenOthersDoNotFit() {
        let renditions = [M.Rendition(name: "French", language: "fre", isForced: false), M.Rendition(name: "Spanish", language: "spa", isForced: false)]
        let pgs = M.Stream(index: 3, displayTitle: "English", language: "eng", isForced: false)
        #expect(M.rendition(for: pgs, in: renditions, embeddedIndexes: [3, 4, 5]) == nil)
    }
}
