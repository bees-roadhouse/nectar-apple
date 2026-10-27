import Testing
@testable import NectarKit

/// nectar-apple #187: the Living Room TV opened GoT S05E01 on "English (forced PGS)", which shows foreign-language
/// lines only, while full English tracks were on offer. A forced-only default gives way to the full track in the
/// same language.
@Suite("A forced-only default gives way to the full track")
struct FullSubtitleTests {

    /// The six options AVKit offered on the TV, in its order.
    private let offered: [SubtitleOption] = [
        SubtitleOption(name: "English (forced SRT)", language: "eng", forced: false),
        SubtitleOption(name: "English (SRT)", language: "eng", forced: false),
        SubtitleOption(name: "English (SDH SRT)", language: "eng", forced: false),
        SubtitleOption(name: "English (forced PGS)", language: "eng", forced: true),
        SubtitleOption(name: "English (SDH PGS (tonemapped and scaled))", language: "eng", forced: false),
        SubtitleOption(name: "English (SDH PGS (original))", language: "eng", forced: false),
    ]

    @Test func theFullTextTrackReplacesTheForcedDefault() {
        #expect(SubtitleOption.fullTrack(replacing: 3, among: offered, prefersSDH: false) == 1)
    }

    @Test func aViewerWhoAskedForSDHGetsTheSDHTextTrack() {
        #expect(SubtitleOption.fullTrack(replacing: 3, among: offered, prefersSDH: true) == 2)
    }

    @Test func aDefaultThatIsNotForcedOnlyStays() {
        #expect(SubtitleOption.fullTrack(replacing: 1, among: offered, prefersSDH: false) == nil)
    }

    @Test func aTrackNamedForcedButNotFlaggedIsStillForced() {
        // nectar names a rendition "(forced SRT)" without the forced characteristic; it is not a full track.
        let options = [
            SubtitleOption(name: "English (forced PGS)", language: "eng", forced: true),
            SubtitleOption(name: "English (forced SRT)", language: "eng", forced: false),
            SubtitleOption(name: "English (SRT)", language: "eng", forced: false),
        ]
        #expect(SubtitleOption.fullTrack(replacing: 0, among: options, prefersSDH: false) == 2)
    }

    @Test func withNoFullTrackInTheLanguageTheForcedOneStays() {
        let options = [
            SubtitleOption(name: "English (forced PGS)", language: "eng", forced: true),
            SubtitleOption(name: "French (SRT)", language: "fra", forced: false),
        ]
        #expect(SubtitleOption.fullTrack(replacing: 0, among: options, prefersSDH: false) == nil)
    }

    @Test func imageTracksAreTheLastResort() {
        let options = [
            SubtitleOption(name: "English (forced PGS)", language: "eng", forced: true),
            SubtitleOption(name: "English (SDH PGS (original))", language: "eng", forced: false),
        ]
        #expect(SubtitleOption.fullTrack(replacing: 0, among: options, prefersSDH: false) == 1)
    }

    @Test func languageTagsAreOneLanguage() {
        let options = [
            SubtitleOption(name: "English (forced PGS)", language: "en-US", forced: true),
            SubtitleOption(name: "English (SRT)", language: "eng", forced: false),
        ]
        #expect(SubtitleOption.fullTrack(replacing: 0, among: options, prefersSDH: false) == 1)
    }
}
