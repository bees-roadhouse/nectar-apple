import Foundation

/// Sends one HTTP request. The seam that lets the device flow run against a script in tests.
public protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

public struct URLSessionTransport: HTTPTransport {
    public init(session: URLSession = .shared) { self.session = session }

    public var session: URLSession

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        return (data, http)
    }
}

/// The reply to `POST /device_authorization` (RFC 8628 §3.2).
public struct DeviceAuthorization: Decodable, Equatable, Sendable {
    public let deviceCode: String
    public let userCode: String
    public let verificationURI: URL
    public let verificationURIComplete: URL?
    public let expiresIn: Int
    public let interval: Int?

    public init(deviceCode: String, userCode: String, verificationURI: URL, verificationURIComplete: URL?, expiresIn: Int, interval: Int?) {
        self.deviceCode = deviceCode
        self.userCode = userCode
        self.verificationURI = verificationURI
        self.verificationURIComplete = verificationURIComplete
        self.expiresIn = expiresIn
        self.interval = interval
    }

    enum CodingKeys: String, CodingKey {
        case deviceCode = "device_code"
        case userCode = "user_code"
        case verificationURI = "verification_uri"
        case verificationURIComplete = "verification_uri_complete"
        case expiresIn = "expires_in"
        case interval
    }
}

/// Tokens from a successful token request (RFC 6749 §5.1).
public struct TokenSet: Codable, Equatable, Sendable {
    public let accessToken: String
    public let tokenType: String
    public let expiresIn: Int?
    public let refreshToken: String?

    public init(accessToken: String, tokenType: String, expiresIn: Int?, refreshToken: String?) {
        self.accessToken = accessToken
        self.tokenType = tokenType
        self.expiresIn = expiresIn
        self.refreshToken = refreshToken
    }

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case tokenType = "token_type"
        case expiresIn = "expires_in"
        case refreshToken = "refresh_token"
    }
}

/// How a round of polling ended.
public enum DeviceFlowOutcome: Equatable, Sendable {
    case approved(TokenSet)
    /// The user declined on `/activate`.
    case denied
    /// The code expired or the server no longer knows it: start over with a new code.
    case expired
}

/// RFC 8628 device authorization grant against nectar: discover, request a code, poll for tokens.
public struct DeviceFlowClient: Sendable {

    public struct Endpoints: Equatable, Sendable {
        public let deviceAuthorization: URL
        public let token: URL

        public init(deviceAuthorization: URL, token: URL) {
            self.deviceAuthorization = deviceAuthorization
            self.token = token
        }
    }

    public static let defaultInterval = 5
    public static let slowDownIncrement = 5
    public static let scope = "openid profile offline_access"
    public static let grantType = "urn:ietf:params:oauth:grant-type:device_code"

    public let issuer: URL
    public let clientID: String
    public let deviceName: String
    public let transport: any HTTPTransport
    public let sleep: @Sendable (Duration) async throws -> Void

    public init(
        issuer: URL,
        clientID: String,
        deviceName: String,
        transport: any HTTPTransport = URLSessionTransport(),
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        self.issuer = issuer
        self.clientID = clientID
        self.deviceName = String(deviceName.prefix(64))
        self.transport = transport
        self.sleep = sleep
    }

    public func discover() async throws -> Endpoints {
        struct Configuration: Decodable {
            let tokenEndpoint: URL
            let deviceAuthorizationEndpoint: URL?

            enum CodingKeys: String, CodingKey {
                case tokenEndpoint = "token_endpoint"
                case deviceAuthorizationEndpoint = "device_authorization_endpoint"
            }
        }

        let url = issuer.appending(path: ".well-known/openid-configuration")
        let (data, response) = try await transport.send(URLRequest(url: url))
        guard response.statusCode == 200 else { throw DeviceFlowError.unexpectedStatus(response.statusCode) }

        let configuration = try JSONDecoder().decode(Configuration.self, from: data)
        guard let deviceAuthorization = configuration.deviceAuthorizationEndpoint else {
            throw DeviceFlowError.deviceFlowNotSupported
        }
        return Endpoints(deviceAuthorization: deviceAuthorization, token: configuration.tokenEndpoint)
    }

    public func start(at endpoints: Endpoints) async throws -> DeviceAuthorization {
        let request = Self.formRequest(endpoints.deviceAuthorization, [
            "client_id": clientID,
            "scope": Self.scope,
            "device_name": deviceName,
        ])
        let (data, response) = try await transport.send(request)
        guard response.statusCode == 200 else {
            throw DeviceFlowError.server(Self.errorCode(in: data) ?? "http_\(response.statusCode)")
        }
        return try JSONDecoder().decode(DeviceAuthorization.self, from: data)
    }

    /// Polls the token endpoint until the user approves, declines, or the code runs out.
    /// Network failures and unexpected replies keep polling; only the code's lifetime ends the loop.
    public func poll(_ authorization: DeviceAuthorization, at endpoints: Endpoints) async throws -> DeviceFlowOutcome {
        var interval = authorization.interval ?? Self.defaultInterval
        var elapsed = 0

        let request = Self.formRequest(endpoints.token, [
            "grant_type": Self.grantType,
            "device_code": authorization.deviceCode,
            "client_id": clientID,
        ])

        while elapsed + interval <= authorization.expiresIn {
            try await sleep(.seconds(interval))
            elapsed += interval

            let data: Data
            let response: HTTPURLResponse
            do {
                (data, response) = try await transport.send(request)
            } catch is URLError {
                continue
            }

            if response.statusCode == 200 {
                return .approved(try JSONDecoder().decode(TokenSet.self, from: data))
            }

            switch Self.errorCode(in: data) {
            case "authorization_pending":
                continue
            case "slow_down":
                interval += Self.slowDownIncrement
            case "access_denied":
                return .denied
            case "expired_token", "invalid_grant":
                return .expired
            default:
                continue
            }
        }
        return .expired
    }

    // MARK: - Helpers

    private static func formRequest(_ url: URL, _ fields: KeyValuePairs<String, String>) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = Data(FormBody.encode(fields).utf8)
        return request
    }

    private static func errorCode(in data: Data) -> String? {
        struct OAuthError: Decodable { let error: String }
        return try? JSONDecoder().decode(OAuthError.self, from: data).error
    }
}

public enum DeviceFlowError: Error, Equatable {
    case deviceFlowNotSupported
    case unexpectedStatus(Int)
    case server(String)
}
