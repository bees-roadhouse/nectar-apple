import Foundation

/// A `nectar://` link into the app (#78): what the Top Shelf's tiles (#74), Siri (#77) and Play on TV open.
public enum NectarLink: Equatable, Sendable {
    /// A title's detail.
    case item(String)
    /// A title playing from where this user stopped.
    case play(String)

    public static let scheme = "nectar"

    /// `nectar://item/{id}` or `nectar://play/{id}`; anything else isn't a link this app follows.
    public init?(url: URL) {
        guard url.scheme == Self.scheme, let host = url.host() else { return nil }
        let parts = url.path().split(separator: "/", omittingEmptySubsequences: true)
        guard parts.count == 1, let id = parts.first.map(String.init) else { return nil }
        switch host {
        case "item": self = .item(id)
        case "play": self = .play(id)
        default: return nil
        }
    }

    public var url: URL {
        var parts = URLComponents()
        parts.scheme = Self.scheme
        switch self {
        case let .item(id):
            parts.host = "item"
            parts.path = "/\(id)"
        case let .play(id):
            parts.host = "play"
            parts.path = "/\(id)"
        }
        return parts.url!
    }
}
