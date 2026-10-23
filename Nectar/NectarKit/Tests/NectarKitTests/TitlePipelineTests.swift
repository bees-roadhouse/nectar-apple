import Foundation
import Testing
@testable import NectarKit

@Suite("Title pipeline")
struct TitlePipelineTests {

    private func card(_ pipeline: String) throws -> MediaCard {
        let json = #"{"id":"m1","item_type":"movie","title":"Arrival","pipeline":"# + pipeline + "}"
        return try JSONDecoder().decode(MediaCard.self, from: Data(json.utf8))
    }

    private func pipeline(_ stage: String, download: String = "null") -> TitlePipeline {
        let json = #"{"stage":""# + stage + #"","download":"# + download + "}"
        return try! JSONDecoder().decode(TitlePipeline.self, from: Data(json.utf8))
    }

    @Test func aCardCarriesItsPipeline() throws {
        #expect(try card(#"{"stage":"upgrading","download":null}"#).pipeline?.stage == "upgrading")
        #expect(try card("null").pipeline == nil)
        let old = try JSONDecoder().decode(MediaCard.self, from: Data(#"{"id":"m1"}"#.utf8))
        #expect(old.pipeline == nil, "a server from before #773 sends no pipeline")
    }

    @Test func theDownloadsBytesAndPhaseAreRead() {
        let p = pipeline("downloading", download: #"{"id":"d1","bytes_done":"1073741824","bytes_total":4294967296,"eta_seconds":600,"phase":null}"#)
        #expect(p.download?.bytesDone == 1_073_741_824, "postgres.js may send a bigint as a string")
        #expect(p.download?.bytesTotal == 4_294_967_296)
        #expect(p.download?.etaSeconds == 600)
    }

    @Test func upgradingIsTheOnlyPill() {
        #expect(CardStatus.of(pipeline("upgrading")) == .upgrading)
        #expect(CardStatus.of(pipeline("available")) == nil, "a plain owned title shows nothing")
        #expect(CardStatus.of(pipeline("denied")) == nil)
        #expect(CardStatus.of(pipeline("something_new")) == nil, "an unknown stage is nothing")
        #expect(CardStatus.of(nil) == nil)
    }

    @Test func theWaitingStagesHaveAClockAndNoValue() {
        #expect(CardStatus.of(pipeline("requested")) == .arriving(.init(words: "Waiting for approval", state: .waiting, value: nil, indeterminate: false)))
        #expect(CardStatus.of(pipeline("no_release")) == .arriving(.init(words: "No release yet", state: .waiting, value: nil, indeterminate: false)))
    }

    @Test func searchingAndImportingSweep() {
        #expect(CardStatus.of(pipeline("searching")) == .arriving(.init(words: "Looking for a release", state: .active, value: nil, indeterminate: true)))
        #expect(CardStatus.of(pipeline("importing")) == .arriving(.init(words: "Adding to the library", state: .active, value: nil, indeterminate: true)))
    }

    @Test func aDownloadSaysHowFarAndHowLong() {
        let p = pipeline("downloading", download: #"{"bytes_done":1073741824,"bytes_total":4294967296,"eta_seconds":600}"#)
        #expect(CardStatus.of(p) == .arriving(.init(words: "1.0 GB of 4.0 GB · 10 min left", state: .active, value: 0.25, indeterminate: false)))
    }

    @Test func aDownloadWithNoBytesYetSweeps() {
        #expect(CardStatus.of(pipeline("downloading")) == .arriving(.init(words: "Downloading", state: .active, value: nil, indeterminate: true)))
    }

    @Test func verifyingAndUnpackingSayWhatTheyAre() {
        let checking = pipeline("downloading", download: #"{"bytes_done":5,"bytes_total":5,"phase":"verifying"}"#)
        #expect(CardStatus.of(checking) == .arriving(.init(words: "Checking the download", state: .active, value: nil, indeterminate: true)))
        let unpacking = pipeline("downloading", download: #"{"phase":"extracting"}"#)
        #expect(CardStatus.of(unpacking)?.words == "Unpacking")
    }

    @Test func pausedAndAttentionKeepTheirBarAndSaySo() {
        let half = #"{"bytes_done":50,"bytes_total":100}"#
        #expect(CardStatus.of(pipeline("paused", download: half)) == .arriving(.init(words: "Paused", state: .paused, value: 0.5, indeterminate: false)))
        #expect(CardStatus.of(pipeline("attention", download: half)) == .arriving(.init(words: "Couldn't download · an admin has been told", state: .failed, value: 0.5, indeterminate: false)))
    }

    @Test func sizesAndTimesReadAsTheWebsDo() {
        #expect(CardStatus.size(512 * 1024) == "1 MB", "never 0 MB")
        #expect(CardStatus.size(300 * 1024 * 1024) == "300 MB")
        #expect(CardStatus.eta(30) == "under a minute left")
        #expect(CardStatus.eta(3 * 3600 + 5 * 60) == "3 h 5 min left")
        #expect(CardStatus.eta(0) == nil)
    }
}
