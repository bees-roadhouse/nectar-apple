import AVFoundation
import Foundation

/// The parts of `GET /api/v1/media/{id}` the player's surroundings show: what the title is about.
public struct MediaDetail: Decodable, Equatable, Sendable {
    public let overview: String?
    public let genres: [String]
    public let contentRating: String?

    public init(overview: String?, genres: [String] = [], contentRating: String? = nil) {
        self.overview = overview
        self.genres = genres
        self.contentRating = contentRating
    }

    private enum Outer: String, CodingKey { case item }
    private enum Keys: String, CodingKey {
        case overview, genres
        case contentRating = "content_rating"
    }

    public init(from decoder: Decoder) throws {
        let item = try decoder.container(keyedBy: Outer.self).nestedContainer(keyedBy: Keys.self, forKey: .item)
        overview = try item.decodeIfPresent(String.self, forKey: .overview)
        genres = (try? item.decodeIfPresent([String].self, forKey: .genres)) ?? []
        contentRating = try item.decodeIfPresent(String.self, forKey: .contentRating)
    }
}

extension NectarSession {
    /// One library item, as much as ``MediaDetail`` reads.
    public func mediaDetail(_ id: String) async throws -> MediaDetail {
        try JSONDecoder().decode(MediaDetail.self, from: try await get("api/v1/media/\(id)"))
    }
}

/// What the system shows about the playing title (#42): the info panel when the viewer swipes down,
/// Control Center's Now Playing, and what a paired iPhone sees. `AVPlayerViewController` publishes the
/// player item's `externalMetadata` there; this builds it.
public enum NowPlaying {

    public static func metadata(for card: MediaCard, detail: MediaDetail?, artwork: Data?) -> [AVMetadataItem] {
        var items: [AVMetadataItem] = []
        func add(_ identifier: AVMetadataIdentifier, _ text: String?) {
            guard let text, !text.trimmingCharacters(in: .whitespaces).isEmpty else { return }
            items.append(item(identifier, value: text as NSString))
        }
        add(.commonIdentifierTitle, card.title)
        add(.iTunesMetadataTrackSubTitle, subtitle(for: card))
        add(.commonIdentifierDescription, detail?.overview)
        add(.quickTimeMetadataGenre, detail.map { $0.genres.joined(separator: ", ") })
        add(.iTunesMetadataContentRating, detail?.contentRating)
        if let artwork, let type = imageType(of: artwork) {
            let image = item(.commonIdentifierArtwork, value: artwork as NSData)
            image.dataType = type
            items.append(image)
        }
        return items
    }

    /// "Severance · S1 E1" for an episode, the year for anything else.
    static func subtitle(for card: MediaCard) -> String? {
        if card.itemType == "episode" {
            var parts: [String] = []
            if let series = card.seriesTitle { parts.append(series) }
            if let season = card.seasonNumber, let episode = card.episodeNumber { parts.append("S\(season) E\(episode)") }
            return parts.isEmpty ? nil : parts.joined(separator: " · ")
        }
        return card.year.map(String.init)
    }

    private static func item(_ identifier: AVMetadataIdentifier, value: NSCopying & NSObjectProtocol) -> AVMutableMetadataItem {
        let item = AVMutableMetadataItem()
        item.identifier = identifier
        item.value = value
        item.extendedLanguageTag = "und"
        return item
    }

    /// The panel draws artwork only when told its type; JPEG and PNG are what nectar and TMDB serve.
    private static func imageType(of data: Data) -> String? {
        if data.starts(with: [0xFF, 0xD8, 0xFF]) { return kCMMetadataBaseDataType_JPEG as String }
        if data.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return kCMMetadataBaseDataType_PNG as String }
        return nil
    }
}
