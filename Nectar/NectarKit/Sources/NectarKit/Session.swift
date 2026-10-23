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
    /// nectar said no, in words the person reads (a 4xx answer's `error`), from a write that asked for them.
    case refused(Int, String)
    /// A path nectar handed out that doesn't form a URL on this server.
    case invalidPath(String)
}

/// Who is calling, sent on every request so nectar's sessions and activity name the TV (nectar-apple#59).
/// Native headers, not a Jellyfin `MediaBrowser` one: this is nectar's own client.
public struct ClientInfo: Equatable, Sendable {
    public let client: String
    public let device: String
    public let deviceID: String
    public let version: String
    /// A run driven by the developer's tools rather than a person: nectar can leave its plays out of
    /// activity and history.
    public let isTestRun: Bool

    public init(client: String, device: String, deviceID: String, version: String, isTestRun: Bool = false) {
        self.client = client
        self.device = device
        self.deviceID = deviceID
        self.version = version
        self.isTestRun = isTestRun
    }

    func stamp(_ request: inout URLRequest) {
        request.setValue(client, forHTTPHeaderField: "X-Nectar-Client")
        request.setValue(device, forHTTPHeaderField: "X-Nectar-Device")
        request.setValue(deviceID, forHTTPHeaderField: "X-Nectar-Device-Id")
        request.setValue(version, forHTTPHeaderField: "X-Nectar-Version")
        if isTestRun { request.setValue("1", forHTTPHeaderField: "X-Nectar-Test") }
    }
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
    private let client: ClientInfo?

    private var refreshing: Task<TokenSet, Error>?

    public init(baseURL: URL, tokenEndpoint: URL, clientID: String, store: any TokenStore, transport: any HTTPTransport = URLSessionTransport(), client: ClientInfo? = nil) {
        self.baseURL = baseURL
        self.tokenEndpoint = tokenEndpoint
        self.clientID = clientID
        self.store = store
        self.transport = transport
        self.client = client
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
    public func get(_ path: String, query: [URLQueryItem] = []) async throws -> Data {
        try await request("GET", path, query: query, body: nil)
    }

    /// POST a JSON body to a path under the base URL, as the signed-in user.
    public func post(_ path: String, json body: some Encodable & Sendable) async throws -> Data {
        try await request("POST", path, query: [], body: try JSONEncoder().encode(body))
    }

    /// POST with no body (an action, not a document).
    public func post(_ path: String) async throws -> Data {
        try await request("POST", path, query: [], body: nil)
    }

    /// PUT a JSON document, already encoded, to a path under the base URL.
    public func put(_ path: String, data body: Data) async throws -> Data {
        try await request("PUT", path, query: [], body: body)
    }

    /// DELETE a path under the base URL, as the signed-in user.
    public func delete(_ path: String) async throws {
        _ = try await request("DELETE", path, query: [], body: nil)
    }

    /// A write whose refusal the person reads: a 4xx answer comes back as ``NectarSessionError/refused(_:_:)`` with
    /// nectar's own `error` text, and a token refused once is refreshed and tried again, as every request is.
    public func write(_ method: String, _ path: String, data body: Data? = nil) async throws -> Data {
        do {
            return try await request(method, path, query: [], body: body, reasons: true)
        } catch let NectarSessionError.unexpectedStatus(status) {
            throw NectarSessionError.refused(status, "nectar said no (\(status)).")
        }
    }

    /// Takes tokens nectar handed back on a write (a password change keeps this device signed in with a new pair).
    func adopt(_ tokens: TokenSet) {
        store.save(tokens)
    }

    /// One try with the current token, never refreshed or retried: for a write where 401 is the answer, not an
    /// expired token. Changing the password answers 401 to a wrong current password, and the usual refresh-and-retry
    /// would end in signing this app out.
    public func once(_ method: String, _ path: String, json body: some Encodable & Sendable) async throws -> Data {
        guard let tokens = store.tokens else { throw NectarSessionError.signedOut }
        let (data, response) = try await send(method, path, query: [], body: try JSONEncoder().encode(body), with: tokens.accessToken)
        return try Self.checked(data, response, reasons: true)
    }

    /// A media URL AVPlayer can open on its own: it can't add headers, so the access token
    /// rides in the query (nectar#379 takes `?access_token=` on streaming and image paths only).
    /// The URL is a credential; don't log it.
    public func mediaURL(_ path: String) throws -> URL {
        guard let tokens = store.tokens else { throw NectarSessionError.signedOut }
        guard let url = resolve(path) else { throw NectarSessionError.invalidPath(path) }
        var components = URLComponents(url: url, resolvingAgainstBaseURL: true)!
        components.queryItems = (components.queryItems ?? []) + [URLQueryItem(name: "access_token", value: tokens.accessToken)]
        return components.url!
    }

    private func request(_ method: String, _ path: String, query: [URLQueryItem], body: Data?, reasons: Bool = false) async throws -> Data {
        guard let tokens = store.tokens else { throw NectarSessionError.signedOut }

        let (data, response) = try await send(method, path, query: query, body: body, with: tokens.accessToken)
        guard response.statusCode == 401 else { return try Self.checked(data, response, reasons: reasons) }

        let fresh = try await refreshed(after: tokens)
        let (retryData, retryResponse) = try await send(method, path, query: query, body: body, with: fresh.accessToken)
        if retryResponse.statusCode == 401 {
            signOut()
            throw NectarSessionError.signedOut
        }
        return try Self.checked(retryData, retryResponse, reasons: reasons)
    }

    /// A request for a long-lived stream under the base URL: the bearer and client headers, with a token
    /// refreshed first if the current one is refused (the stream itself can't be retried mid-flight).
    func streamRequest(_ path: String) async throws -> URLRequest {
        guard var tokens = store.tokens else { throw NectarSessionError.signedOut }
        let probe = try await send("GET", "api/v1/users/me", query: [], body: nil, with: tokens.accessToken).1
        if probe.statusCode == 401 { tokens = try await refreshed(after: tokens) }
        var request = URLRequest(url: baseURL.appending(path: path))
        request.setValue("Bearer \(tokens.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 24 * 3600
        client?.stamp(&request)
        return request
    }

    /// The access token for a web view inside the app (the iPhone app's frame, #156): the current one, or a fresh one
    /// when `stale` is the token the page was refused with. Shares the session's single refresh, so several web
    /// views refused at once refresh once.
    public func webToken(replacing stale: String? = nil) async throws -> String {
        guard let tokens = store.tokens else { throw NectarSessionError.signedOut }
        guard let stale, stale == tokens.accessToken else { return tokens.accessToken }
        return try await refreshed(after: tokens).accessToken
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

        let task = Task { [transport, tokenEndpoint, clientID, store, client] in
            var request = URLRequest(url: tokenEndpoint)
            client?.stamp(&request)
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

    private func send(_ method: String, _ path: String, query: [URLQueryItem], body: Data?, with accessToken: String) async throws -> (Data, HTTPURLResponse) {
        var url = baseURL.appending(path: path)
        if !query.isEmpty { url.append(queryItems: query) }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        client?.stamp(&request)
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return try await transport.send(request)
    }

    private static func checked(_ data: Data, _ response: HTTPURLResponse, reasons: Bool = false) throws -> Data {
        guard (200 ..< 300).contains(response.statusCode) else {
            struct Reason: Decodable { let error: String?; let message: String? }
            if reasons, (400 ..< 500).contains(response.statusCode),
               let reason = try? JSONDecoder().decode(Reason.self, from: data), let words = reason.message ?? reason.error {
                throw NectarSessionError.refused(response.statusCode, words)
            }
            throw NectarSessionError.unexpectedStatus(response.statusCode)
        }
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
