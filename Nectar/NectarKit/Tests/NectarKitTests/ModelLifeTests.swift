import Foundation
import Testing
@testable import NectarKit

@Suite("Model life")
struct ModelLifeTests {

    /// Palp's blocker on #122: a request already waiting when the player is dismissed resumed and started it again.
    /// The same shape is Palp's second finding on #75: a Home load already waiting when someone signs out resumes
    /// and writes the last person's titles back to the Top Shelf.
    @Test @MainActor func aRequestThatResumesAfterStopNeverAppliesItsAnswer() async {
        let life = ModelLife()
        var resume: CheckedContinuation<URL, Never>?
        var applied: [URL] = []
        let waiting = Task { @MainActor in
            await life.after({ await withCheckedContinuation { resume = $0 } }, apply: { applied.append($0) })
        }
        while resume == nil { await Task.yield() }
        life.stop()
        resume?.resume(returning: URL(string: "https://nectar.example/trailer")!)
        let ran = await waiting.value
        #expect(!ran)
        #expect(applied.isEmpty, "stop() came in while the answer was awaited")
    }

    @Test @MainActor func aRequestThatResumesBeforeStopApplies() async {
        let life = ModelLife()
        var applied: [URL] = []
        let ran = await life.after({ URL(string: "https://nectar.example/trailer")! }, apply: { applied.append($0) })
        #expect(ran)
        #expect(applied.count == 1)
        life.stop()
        let late = await life.after({ URL(string: "https://nectar.example/other")! }, apply: { applied.append($0) })
        #expect(!late)
        #expect(applied.count == 1, "nothing applies after stop(), even a request that never waited")
    }
}
