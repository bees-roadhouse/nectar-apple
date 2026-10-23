import Foundation

/// This user's language and playback preferences (`/api/v1/users/me/preferences`), as the TV edits them.
///
/// nectar's PUT replaces the whole document, so this keeps everything it read and changes only the
/// fields the TV shows: the theme, bitrate cap, home sections and the rest go back as they came.
public struct Preferences: Sendable, Equatable {

    /// The same settings, whatever order the keys came in.
    public static func == (lhs: Preferences, rhs: Preferences) -> Bool {
        NSDictionary(dictionary: lhs.fields).isEqual(to: rhs.fields)
    }

    /// nectar's three subtitle modes, and null for its default.
    public enum SubtitleMode: String, CaseIterable, Sendable {
        case serverDefault
        case off
        case auto
        case always

        var wire: String? { self == .serverDefault ? nil : rawValue }
    }

    /// The document as nectar sent it, JSON-encoded.
    private var document: Data

    public var audioLanguage: String? {
        get { string("preferred_audio_language") }
        set { set("preferred_audio_language", newValue) }
    }

    public var subtitleLanguage: String? {
        get { string("preferred_subtitle_language") }
        set { set("preferred_subtitle_language", newValue) }
    }

    public var subtitleMode: SubtitleMode {
        get { string("subtitle_mode").flatMap(SubtitleMode.init(rawValue:)) ?? .serverDefault }
        set { set("subtitle_mode", newValue.wire) }
    }

    public var preferOriginalAudio: Bool {
        get { (fields["prefer_original_audio"] as? Bool) ?? false }
        set { set("prefer_original_audio", newValue) }
    }

    init(document: Data) {
        self.document = document
    }

    var data: Data { document }

    private var fields: [String: Any] {
        (try? JSONSerialization.jsonObject(with: document) as? [String: Any]) ?? [:]
    }

    func string(_ key: String) -> String? {
        fields[key] as? String
    }

    func number(_ key: String) -> Int? {
        (fields[key] as? NSNumber)?.intValue
    }

    mutating func set(_ key: String, _ value: Any?) {
        var all = fields
        all[key] = value ?? NSNull()
        document = (try? JSONSerialization.data(withJSONObject: all)) ?? document
    }
}

/// A signed-in device or browser (`/api/v1/auth/devices`).
public struct Device: Equatable, Identifiable, Sendable {
    public let id: String
    /// What to call it: the name it was given, or what kind of thing it is.
    public let name: String
    public let kind: String
    public let signInMethod: String?
    public let lastUsed: Date?
    /// The one this request came from: this TV.
    public let isCurrent: Bool
}

/// An app-specific sign-in for a Jellyfin client.
public struct JellyfinCredential: Equatable, Identifiable, Sendable {
    public let id: String
    public let label: String
    public let createdAt: Date?
    public let lastUsed: Date?
}

private struct DeviceList: Decodable {
    struct Row: Decodable {
        let id: String
        let kind: String?
        let deviceName: String?
        let signInMethod: String?
        let lastUsedAt: String?
        let current: Bool?

        enum CodingKeys: String, CodingKey {
            case id, kind, current
            case deviceName = "device_name"
            case signInMethod = "sign_in_method"
            case lastUsedAt = "last_used_at"
        }
    }

    let devices: [Row]
}

private struct CredentialList: Decodable {
    struct Row: Decodable {
        let id: String
        let label: String?
        let createdAt: String?
        let lastUsedAt: String?

        enum CodingKeys: String, CodingKey {
            case id, label
            case createdAt = "created_at"
            case lastUsedAt = "last_used_at"
        }
    }

    let credentials: [Row]
    let enabled: Bool?
}

private struct SignedOut: Decodable {
    let signedOut: Int?

    enum CodingKeys: String, CodingKey {
        case signedOut = "signed_out"
    }
}

extension NectarSession {

    public func preferences() async throws -> Preferences {
        Preferences(document: try await get("api/v1/users/me/preferences"))
    }

    /// Saves the whole document, and returns what nectar kept.
    @discardableResult
    public func save(_ preferences: Preferences) async throws -> Preferences {
        Preferences(document: try await put("api/v1/users/me/preferences", data: preferences.data))
    }

    /// This user's signed-in devices and browsers, most recently used first.
    public func devices() async throws -> [Device] {
        try JSONDecoder().decode(DeviceList.self, from: try await get("api/v1/auth/devices")).devices.map { row in
            let fallback = row.kind == "web" ? "Web browser" : "A device"
            return Device(id: row.id, name: row.deviceName.flatMap { $0.isEmpty ? nil : $0 } ?? fallback, kind: row.kind ?? "device",
                          signInMethod: row.signInMethod, lastUsed: row.lastUsedAt.flatMap(Self.timestamp), isCurrent: row.current ?? false)
        }
    }

    public func signOut(device id: String) async throws {
        try await delete("api/v1/auth/devices/\(id)")
    }

    /// Signs out everything but this TV; how many were signed out.
    public func signOutOtherDevices() async throws -> Int {
        try JSONDecoder().decode(SignedOut.self, from: try await post("api/v1/auth/devices/sign-out-others")).signedOut ?? 0
    }

    /// This user's Jellyfin app credentials, and whether the server allows them at all.
    public func jellyfinCredentials() async throws -> (enabled: Bool, credentials: [JellyfinCredential]) {
        let list = try JSONDecoder().decode(CredentialList.self, from: try await get("api/v1/users/me/jellyfin-credentials"))
        return (list.enabled ?? false, list.credentials.map {
            JellyfinCredential(id: $0.id, label: $0.label ?? "Jellyfin app", createdAt: $0.createdAt.flatMap(Self.timestamp), lastUsed: $0.lastUsedAt.flatMap(Self.timestamp))
        })
    }

    public func revokeJellyfinCredential(_ id: String) async throws {
        try await delete("api/v1/users/me/jellyfin-credentials/\(id)")
    }
}

// MARK: - Managing the account (the phone's Account, nectar-apple #165)

extension Preferences {

    /// The interface language, a BCP 47 tag ("en-US"); nil for the server's default.
    public var locale: String? {
        get { string("locale") }
        set { set("locale", newValue) }
    }

    /// An IANA time zone ("America/New_York"); nil for the server's default.
    public var timeZone: String? {
        get { string("time_zone") }
        set { set("time_zone", newValue) }
    }

    /// The streaming cap in bits per second; nil for none.
    public var maxStreamingBitrate: Int? {
        get { number("max_streaming_bitrate") }
        set { set("max_streaming_bitrate", newValue) }
    }
}

/// A sign-in provider the server offers (Keycloak, Google…), and whether this account is linked to it.
public struct SignInProvider: Equatable, Identifiable, Sendable {
    public let id: String
    public let name: String
    public let linked: Bool
}

/// A Jellyfin app credential just made: the password is shown once and kept nowhere.
public struct NewJellyfinCredential: Equatable, Sendable {
    public let id: String
    public let username: String
    public let password: String
}

/// What another device asked to sign in with (`/activate?code=`): its name and where it stands.
public struct DeviceCode: Equatable, Sendable {
    public let code: String
    public let deviceName: String?
    public let status: String
}

extension NectarSession {

    /// Renames a signed-in device; the name nectar kept.
    @discardableResult
    public func rename(device id: String, to name: String) async throws -> String {
        let data = try await write("PATCH", "api/v1/auth/devices/\(id)", data: JSONSerialization.data(withJSONObject: ["name": name]))
        struct Renamed: Decodable { let device_name: String? }
        return (try? JSONDecoder().decode(Renamed.self, from: data))?.device_name ?? name
    }

    /// Every provider the server offers, marked with this account's links.
    public func signInProviders() async throws -> [SignInProvider] {
        struct Status: Decodable { struct Provider: Decodable { let id: String; let name: String? }; let providers: [Provider]? }
        struct Linked: Decodable { struct Identity: Decodable { let provider_id: String? }; let identities: [Identity] }
        async let status = get("api/v1/settings/setup-status")
        async let identities = get("api/v1/users/me/identities")
        let offered = try JSONDecoder().decode(Status.self, from: try await status).providers ?? []
        let linked = Set(try JSONDecoder().decode(Linked.self, from: try await identities).identities.compactMap(\.provider_id))
        return offered.map { SignInProvider(id: $0.id, name: $0.name ?? $0.id, linked: linked.contains($0.id)) }
    }

    /// Where to send the person to link a provider: nectar hands out the provider's URL for this signed-in account.
    public func linkURL(for provider: String) async throws -> URL {
        struct Start: Decodable { let url: URL }
        return try JSONDecoder().decode(Start.self, from: try await write("POST", "api/v1/auth/oidc/\(provider)/link")).url
    }

    /// Unlinks a provider; nectar refuses (in words) when it's the account's only way in.
    public func unlink(provider: String) async throws {
        _ = try await write("DELETE", "api/v1/users/me/identities/\(provider)")
    }

    /// Changes the password; true when this device stays signed in. nectar ends every other session. Since nectar
    /// #830 a device changing its own password gets a new pair back and keeps going; before it, every token was
    /// revoked, this app's too, and the caller signs in again. A wrong current password was nectar's 401, an answer
    /// here and not an expired token; #830 makes it a 400 in words.
    @discardableResult
    public func changePassword(current: String, new: String) async throws -> Bool {
        struct Change: Encodable, Sendable { let current_password: String; let new_password: String }
        struct Answer: Decodable {
            struct Device: Decodable { let access_token: String; let refresh_token: String?; let expires_in: Int? }
            let device: Device?
        }
        let data: Data
        do {
            data = try await once("PUT", "api/v1/users/me/password", json: Change(current_password: current, new_password: new))
        } catch NectarSessionError.refused(401, _) {
            throw NectarSessionError.refused(401, "The current password isn't right.")
        }
        guard let device = (try? JSONDecoder().decode(Answer.self, from: data))?.device, device.refresh_token != nil else { return false }
        adopt(TokenSet(accessToken: device.access_token, tokenType: "Bearer", expiresIn: device.expires_in, refreshToken: device.refresh_token))
        return true
    }

    /// The risk text and version a new Jellyfin credential has to accept, when the server sends one.
    public func jellyfinRisk() async throws -> (version: String, text: String)? {
        struct List: Decodable { struct Risk: Decodable { let version: String; let text: String }; let risk: Risk? }
        return try JSONDecoder().decode(List.self, from: try await get("api/v1/users/me/jellyfin-credentials")).risk.map { ($0.version, $0.text) }
    }

    /// Makes a Jellyfin app credential, accepting the risk version shown.
    public func createJellyfinCredential(label: String, riskVersion: String) async throws -> NewJellyfinCredential {
        let body = try JSONSerialization.data(withJSONObject: ["label": label, "accept_risk": true, "risk_version": riskVersion] as [String: Any])
        struct Made: Decodable { let id: String; let username: String; let password: String }
        let made = try JSONDecoder().decode(Made.self, from: try await write("POST", "api/v1/users/me/jellyfin-credentials", data: body))
        return NewJellyfinCredential(id: made.id, username: made.username, password: made.password)
    }

    /// The device behind a sign-in code.
    public func lookUp(code: String) async throws -> DeviceCode {
        struct Lookup: Decodable { let code: String; let device_name: String?; let status: String }
        let found = try JSONDecoder().decode(Lookup.self, from: try await get("api/v1/auth/device", query: [URLQueryItem(name: "code", value: code)]))
        return DeviceCode(code: found.code, deviceName: found.device_name, status: found.status)
    }

    /// Approves or denies another device's sign-in code; where it stands after.
    @discardableResult
    public func decide(code: String, approve: Bool) async throws -> String {
        let body = try JSONSerialization.data(withJSONObject: ["code": code, "approve": approve] as [String: Any])
        struct Decided: Decodable { let status: String }
        return try JSONDecoder().decode(Decided.self, from: try await write("POST", "api/v1/auth/device", data: body)).status
    }
}
