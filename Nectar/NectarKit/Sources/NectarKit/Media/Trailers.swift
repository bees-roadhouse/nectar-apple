import Foundation

/// One of a title's trailers (nectar #715): nectar lists up to five, in the order they should be watched.
public struct Trailer: Decodable, Equatable, Identifiable, Sendable {

    public enum Kind: String, Sendable {
        case trailer
        case teaser
        case clip
        case featurette
        /// A kind nectar added after this build; it still plays.
        case other
    }

    public let id: String
    /// Root-relative and served with Range; the file needs the token.
    public let path: String
    public let title: String?
    public let kind: Kind
    public let official: Bool
    public let runtimeSeconds: Double?
    public let language: String?
    /// False while nectar knows the trailer but hasn't fetched it: asking for `path` starts the fetch.
    public let isReady: Bool

    public init(
        id: String,
        path: String,
        title: String? = nil,
        kind: Kind = .trailer,
        official: Bool = false,
        runtimeSeconds: Double? = nil,
        language: String? = nil,
        isReady: Bool = true
    ) {
        self.id = id
        self.path = path
        self.title = title
        self.kind = kind
        self.official = official
        self.runtimeSeconds = runtimeSeconds
        self.language = language
        self.isReady = isReady
    }

    enum CodingKeys: String, CodingKey {
        case id, title, kind, official, language
        case path = "url"
        case runtimeSeconds = "runtime_seconds"
        case isReady = "ready"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        path = try c.decode(String.self, forKey: .path)
        title = try c.decodeIfPresent(String.self, forKey: .title)
        kind = (try c.decodeIfPresent(String.self, forKey: .kind)).flatMap(Kind.init(rawValue:)) ?? .other
        official = (try c.decodeIfPresent(Bool.self, forKey: .official)) ?? false
        runtimeSeconds = c.lenientDouble(.runtimeSeconds)
        language = try c.decodeIfPresent(String.self, forKey: .language)
        isReady = (try c.decodeIfPresent(Bool.self, forKey: .isReady)) ?? true
    }
}

/// The trailers playing one after another (nectar-apple #119): only ready ones play, in nectar's order. When one ends
/// the next starts, the remote's left and right move between them, and after the last the trailers close.
public struct TrailerQueue: Equatable, Sendable {

    /// "2 of 3", counted among the ready trailers.
    public struct Position: Equatable, Sendable {
        public let number: Int
        public let of: Int
    }

    public private(set) var trailers: [Trailer]
    private var index: Int

    /// Nil when no trailer is ready yet.
    public init?(_ trailers: [Trailer]) {
        guard let first = trailers.firstIndex(where: \.isReady) else { return nil }
        self.trailers = trailers
        index = first
    }

    public var current: Trailer? {
        trailers.indices.contains(index) && trailers[index].isReady ? trailers[index] : nil
    }

    public var next: Trailer? {
        nextIndex.map { trailers[$0] }
    }

    public var previous: Trailer? {
        previousIndex.map { trailers[$0] }
    }

    public var position: Position? {
        let ready = trailers.indices.filter { trailers[$0].isReady }
        return ready.firstIndex(of: index).map { Position(number: $0 + 1, of: ready.count) }
    }

    /// The ones to ask nectar for once, so their fetch starts while another plays.
    public var unready: [Trailer] {
        trailers.filter { !$0.isReady }
    }

    /// The next ready trailer, now current; nil after the last, and the queue stays where it was.
    public mutating func advance() -> Trailer? {
        guard let next = nextIndex else { return nil }
        index = next
        return trailers[next]
    }

    public mutating func goBack() -> Trailer? {
        guard let previous = previousIndex else { return nil }
        index = previous
        return trailers[previous]
    }

    /// nectar's list read again: trailers that landed join, failed ones leave, and the playing one stays current.
    /// If the playing one is gone, the queue carries on from the next ready trailer at or after its place.
    public mutating func refresh(with trailers: [Trailer]) {
        let playing = current?.id
        let place = index
        self.trailers = trailers
        if let playing, let found = trailers.firstIndex(where: { $0.id == playing }) {
            index = found
        } else {
            index = trailers.indices.dropFirst(place).first { trailers[$0].isReady }
                ?? trailers.indices.last { trailers[$0].isReady }
                ?? 0
        }
    }

    private var nextIndex: Int? {
        trailers.indices.dropFirst(index + 1).first { trailers[$0].isReady }
    }

    private var previousIndex: Int? {
        trailers.indices.prefix(index).last { trailers[$0].isReady }
    }
}
