import Foundation

public struct NectarUser: Decodable, Equatable, Sendable {
    public let id: String
    public let username: String
    public let isAdmin: Bool

    public init(id: String, username: String, isAdmin: Bool) {
        self.id = id
        self.username = username
        self.isAdmin = isAdmin
    }

    enum CodingKeys: String, CodingKey {
        case id
        case username
        case isAdmin = "is_admin"
    }
}

public enum NectarSessionError: Error, Equatable {
    /// No tokens, or the refresh token was refused: the user has to sign in again.
    case signedOut
    case unexpectedStatus(Int)
}

/// The signed-in connection to nectar's own API.
///
/// Every request carries the access token. On a 401 it refreshes once and retries. Refresh tokens
/// rotate and nectar revokes the device if an old one is presented again, so concurrent 401s share
/// a single refresh, and the new pair is saved before anyone uses it.
public actor NectarSession {

    public let baseURL: URL
    private let tokenEndpoint: URL
    private let clientID: String
    private let store: any TokenStore
    private let transport: any HTTPTransport

    private var refreshing: Task<TokenSet, Error>?

    public init(baseURL: URL, tokenEndpoint: URL, clientID: String, store: any TokenStore, transport: any HTTPTransport = URLSessionTransport()) {
        self.baseURL = baseURL
        self.tokenEndpoint = tokenEndpoint
        self.clientID = clientID
        self.store = store
        self.transport = transport
    }

    public var isSignedIn: Bool {
        store.tokens != nil
    }

    public func currentUser() async throws -> NectarUser {
        let data = try await get("api/v1/users/me")
        return try JSONDecoder().decode(NectarUser.self, from: data)
    }

    public func signOut() {
        refreshing?.cancel()
        refreshing = nil
        store.save(nil)
    }

    /// GET a path under the base URL, as the signed-in user.
    public func get(_ path: String) async throws -> Data {
        guard let tokens = store.tokens else { throw NectarSessionError.signedOut }

        let (data, response) = try await send(path, with: tokens.accessToken)
        guard response.statusCode == 401 else { return try Self.checked(data, response) }

        let fresh = try await refreshed(after: tokens)
        let (retryData, retryResponse) = try await send(path, with: fresh.accessToken)
        if retryResponse.statusCode == 401 {
            signOut()
            throw NectarSessionError.signedOut
        }
        return try Self.checked(retryData, retryResponse)
    }

    // MARK: - Refresh

    private func refreshed(after stale: TokenSet) async throws -> TokenSet {
        if let current = store.tokens, current.accessToken != stale.accessToken {
            return current
        }
        if let refreshing {
            return try await refreshing.value
        }

        guard let refreshToken = stale.refreshToken else {
            signOut()
            throw NectarSessionError.signedOut
        }

        let task = Task { [transport, tokenEndpoint, clientID, store] in
            var request = URLRequest(url: tokenEndpoint)
            request.httpMethod = "POST"
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            request.httpBody = Data(FormBody.encode([
                "grant_type": "refresh_token",
                "refresh_token": refreshToken,
                "client_id": clientID,
            ]).utf8)

            let (data, response) = try await transport.send(request)
            guard response.statusCode == 200 else {
                store.save(nil)
                throw NectarSessionError.signedOut
            }
            let tokens = try JSONDecoder().decode(TokenSet.self, from: data)
            store.save(tokens)
            return tokens
        }
        refreshing = task
        defer { refreshing = nil }
        return try await task.value
    }

    // MARK: - Helpers

    private func send(_ path: String, with accessToken: String) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: baseURL.appending(path: path))
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return try await transport.send(request)
    }

    private static func checked(_ data: Data, _ response: HTTPURLResponse) throws -> Data {
        guard (200 ..< 300).contains(response.statusCode) else { throw NectarSessionError.unexpectedStatus(response.statusCode) }
        return data
    }
}

/// `application/x-www-form-urlencoded`, encoding everything but unreserved characters.
enum FormBody {

    private static let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    static func encode(_ fields: KeyValuePairs<String, String>) -> String {
        fields
            .map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: unreserved) ?? $0.value)" }
            .joined(separator: "&")
    }
}
