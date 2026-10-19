import Foundation

/// One slide of Home's billboard: a title, and whether it's one to resume.
public struct HeroSlide: Equatable, Identifiable, Sendable {
    public let card: MediaCard
    /// From Continue Watching: its button says Resume.
    public let resumable: Bool

    public var id: String { card.id }

    /// As the web's home picks them: what's being watched first, then the newest films and series,
    /// each title once, five at most.
    public static func pick(watching: [MediaCard], recent: [MediaCard], limit: Int = 5) -> [HeroSlide] {
        var slides: [HeroSlide] = []
        var seen = Set<String>()
        for card in watching where slides.count < limit && seen.insert(card.id).inserted {
            slides.append(HeroSlide(card: card, resumable: true))
        }
        for card in recent where slides.count < limit && (card.itemType == "movie" || card.itemType == "series") && seen.insert(card.id).inserted {
            slides.append(HeroSlide(card: card, resumable: false))
        }
        return slides
    }
}
