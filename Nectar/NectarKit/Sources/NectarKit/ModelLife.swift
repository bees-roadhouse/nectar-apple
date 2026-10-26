import Foundation

/// A model's life: work that began before `stop()` and finishes after it must not touch what it was for. A dismissed
/// trailer player has no screen but still has audio, and a signed-out Home has no one to show titles to but still
/// has a Top Shelf to write them to. Every `await` in such a model that ends in a side effect goes through `after`
/// or checks `isStopped`, because nothing else notices a new one that doesn't.
@MainActor
public final class ModelLife {

    public private(set) var isStopped = false

    public init() {}

    public func stop() {
        isStopped = true
    }

    /// Waits for `fetch`, then hands its answer to `apply`, unless `stop()` came in while it waited.
    @discardableResult
    public func after<Answer>(_ fetch: () async -> Answer, apply: (Answer) -> Void) async -> Bool {
        let answer = await fetch()
        guard !isStopped else { return false }
        apply(answer)
        return true
    }
}
