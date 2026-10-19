import NectarKit
import SwiftUI

/// Titles to play one after another: a playlist, or a series from an episode on.
struct PlayQueue: Identifiable {
    let id = UUID()
    let cards: [MediaCard]
}

/// Plays a queue: one player per title, the next when one ends, back to where it was opened after the last
/// (or whenever the viewer leaves).
struct QueuePlayer: View {

    let queue: PlayQueue
    let session: NectarSession
    let done: () -> Void

    @State
    private var index = 0
    @State
    private var current: PlayerModel?

    var body: some View {
        Group {
            if let current {
                PlayerView(model: current, dismiss: done)
                    .id(current.id + String(index))
            } else {
                Color.black.ignoresSafeArea()
            }
        }
        .task(id: index) {
            guard queue.cards.indices.contains(index) else { return done() }
            let model = PlayerModel(card: queue.cards[index], session: session)
            model.finished = {
                if index + 1 < queue.cards.count { index += 1 } else { done() }
            }
            current = model
        }
    }
}
