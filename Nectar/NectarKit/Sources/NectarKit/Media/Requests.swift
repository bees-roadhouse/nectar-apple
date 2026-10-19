import Foundation

/// Where a title stands after "Want it" (nectar #428): a household member's request is approved as
/// they ask and starts downloading; a guest's waits for an admin.
public enum WantState: Equatable, Sendable {
    /// Approved: nectar is monitoring and downloading it.
    case wanted
    /// Pending: an admin has to approve it.
    case awaitingApproval
    /// Someone already has an open request for it.
    case alreadyRequested
}

struct RequestBody: Encodable, Sendable {
    struct Ref: Encodable, Sendable {
        let kind: String
        let tmdbID: Int
        let title: String
        let year: Int?

        enum CodingKeys: String, CodingKey {
            case kind
            case tmdbID = "tmdb_id"
            case title
            case year
        }
    }

    let mediaRef: Ref

    enum CodingKeys: String, CodingKey {
        case mediaRef = "media_ref"
    }
}

private struct RequestAnswer: Decodable {
    let status: String
}

private struct RequestList: Decodable {
    struct Request: Decodable {
        struct Ref: Decodable {
            let kind: String?
            let tmdbID: Int?

            enum CodingKeys: String, CodingKey {
                case kind
                case tmdbID = "tmdb_id"
            }

            /// nectar stores the ref as the client sent it, so the id may be a number or a string.
            init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                kind = try c.decodeIfPresent(String.self, forKey: .kind)
                if let number = try? c.decodeIfPresent(Int.self, forKey: .tmdbID) {
                    tmdbID = number
                } else if let text = try? c.decodeIfPresent(String.self, forKey: .tmdbID) {
                    tmdbID = Int(text)
                } else {
                    tmdbID = nil
                }
            }
        }

        let mediaRef: Ref
        let status: String

        enum CodingKeys: String, CodingKey {
            case mediaRef = "media_ref"
            case status
        }
    }

    let requests: [Request]
}

extension WantState {
    /// Only open requests count: denied and fulfilled ones don't.
    init?(status: String) {
        switch status {
        case "approved": self = .wanted
        case "pending": self = .awaitingApproval
        default: return nil
        }
    }
}

extension NectarSession {

    /// Ask for a title (`POST /api/v1/requests`). A household member gets it at once; a guest waits.
    public func want(_ item: DiscoverItem) async throws -> WantState {
        let body = RequestBody(mediaRef: .init(kind: item.kind.rawValue, tmdbID: item.tmdbID, title: item.title, year: item.year))
        do {
            let data = try await post("api/v1/requests", json: body)
            let answer = try JSONDecoder().decode(RequestAnswer.self, from: data)
            return WantState(status: answer.status) ?? .awaitingApproval
        } catch NectarSessionError.unexpectedStatus(409) {
            return .alreadyRequested
        }
    }

    /// The caller's open requests, keyed by ``DiscoverItem/id``, so Discover can tell "Wanted" from "Requested".
    public func myRequestStates() async throws -> [String: WantState] {
        let data = try await get("api/v1/requests")
        var states: [String: WantState] = [:]
        for request in try JSONDecoder().decode(RequestList.self, from: data).requests {
            guard let tmdb = request.mediaRef.tmdbID,
                  let kind = request.mediaRef.kind.flatMap(DiscoverItem.Kind.init(rawValue:)),
                  let state = WantState(status: request.status) else { continue }
            states[DiscoverItem(tmdbID: tmdb, kind: kind, title: "").id] = state
        }
        return states
    }
}
