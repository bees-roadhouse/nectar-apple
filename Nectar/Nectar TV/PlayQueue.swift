import Foundation
import NectarKit

/// Titles to play one after another: a playlist, or a series from an episode on.
struct PlayQueue: Identifiable {
    let id = UUID()
    let cards: [MediaCard]
}
