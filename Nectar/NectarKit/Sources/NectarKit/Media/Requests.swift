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
            let title: String?
            let year: Int?

            enum CodingKeys: String, CodingKey {
                case kind, title, year
                case tmdbID = "tmdb_id"
            }

            /// nectar stores the ref as the client sent it, so the id may be a number or a string.
            init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                kind = try c.decodeIfPresent(String.self, forKey: .kind)
                title = try c.decodeIfPresent(String.self, forKey: .title)
                year = c.lenientInt(.year)
                if let number = try? c.decodeIfPresent(Int.self, forKey: .tmdbID) {
                    tmdbID = number
                } else if let text = try? c.decodeIfPresent(String.self, forKey: .tmdbID) {
                    tmdbID = Int(text)
                } else {
                    tmdbID = nil
                }
            }
        }

        let id: String?
        let mediaRef: Ref
        let status: String
        let requestedBy: String?
        let createdAt: String?
        let autoApproved: Bool?

        enum CodingKeys: String, CodingKey {
            case id, status
            case mediaRef = "media_ref"
            case requestedBy = "requested_by"
            case createdAt = "created_at"
            case autoApproved = "auto_approved"
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
    /// An admin's list is everyone's, so `userID` keeps the caller's own; someone else's open request shows
    /// through Discover's own `already_requested` instead.
    public func myRequestStates(userID: String? = nil) async throws -> [String: WantState] {
        let data = try await get("api/v1/requests")
        var states: [String: WantState] = [:]
        for request in try JSONDecoder().decode(RequestList.self, from: data).requests where userID == nil || request.requestedBy == userID {
            guard let tmdb = request.mediaRef.tmdbID,
                  let kind = request.mediaRef.kind.flatMap(DiscoverItem.Kind.init(rawValue:)),
                  let state = WantState(status: request.status) else { continue }
            states[DiscoverItem(tmdbID: tmdb, kind: kind, title: "").id] = state
        }
        return states
    }
}

/// One of the caller's requests, as the list shows it.
public struct MyRequest: Equatable, Identifiable, Sendable {

    public enum Status: String, Sendable {
        case pending, approved, denied, fulfilled

        public var label: String {
            switch self {
            case .pending: "Awaiting approval"
            case .approved: "Wanted · downloading"
            case .fulfilled: "In your library"
            case .denied: "Declined"
            }
        }
    }

    public let id: String
    public let title: String
    public let year: Int?
    public let kind: DiscoverItem.Kind
    public let tmdbID: Int?
    public let status: Status
    public let autoApproved: Bool
    public let requestedAt: Date?
}

extension NectarSession {

    /// The caller's own requests, newest first. An admin's `GET /requests` is everyone's, so the list is
    /// filtered to `requested_by`: this is "my requests", not the approval queue.
    public func myRequests(userID: String) async throws -> [MyRequest] {
        let data = try await get("api/v1/requests")
        return try JSONDecoder().decode(RequestList.self, from: data).requests.compactMap { request in
            guard request.requestedBy == userID, let id = request.id, let status = MyRequest.Status(rawValue: request.status) else { return nil }
            return MyRequest(
                id: id,
                title: request.mediaRef.title ?? "Untitled",
                year: request.mediaRef.year,
                kind: request.mediaRef.kind.flatMap(DiscoverItem.Kind.init(rawValue:)) ?? .movie,
                tmdbID: request.mediaRef.tmdbID,
                status: status,
                autoApproved: request.autoApproved ?? false,
                requestedAt: request.createdAt.flatMap(Self.timestamp)
            )
        }
    }

    /// nectar's timestamps, with or without fractional seconds.
    nonisolated static func timestamp(_ text: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: text) ?? ISO8601DateFormatter().date(from: text)
    }
}
