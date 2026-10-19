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

    private func string(_ key: String) -> String? {
        fields[key] as? String
    }

    private mutating func set(_ key: String, _ value: Any?) {
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
