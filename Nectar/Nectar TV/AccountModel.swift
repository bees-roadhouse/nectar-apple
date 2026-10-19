import Foundation
import NectarKit

/// My Account: language and playback, devices, Jellyfin credentials. Changes save as they're made.
@MainActor
@Observable
final class AccountModel {

    let user: NectarUser
    let session: NectarSession
    private(set) var preferences: Preferences?
    private(set) var devices: [Device]?
    private(set) var credentials: [JellyfinCredential] = []
    private(set) var credentialsEnabled = false
    /// The last thing that didn't work, said plainly.
    private(set) var problem: String?

    init(user: NectarUser, session: NectarSession) {
        self.user = user
        self.session = session
    }

    func load() async {
        async let preferences = try? session.preferences()
        async let devices = try? session.devices()
        async let credentials = try? session.jellyfinCredentials()
        self.preferences = await preferences
        self.devices = await devices ?? []
        if let (enabled, list) = await credentials {
            credentialsEnabled = enabled
            self.credentials = list
        }
    }

    /// Change a preference and save the whole document; on failure, show what nectar still has.
    func update(_ change: (inout Preferences) -> Void) async {
        guard var next = preferences else { return }
        change(&next)
        preferences = next
        do {
            preferences = try await session.save(next)
            problem = nil
        } catch {
            problem = "Couldn't save that. It's back to how it was."
            preferences = try? await session.preferences()
        }
    }

    func signOut(_ device: Device) async {
        guard !device.isCurrent else { return }
        do {
            try await session.signOut(device: device.id)
            devices = try? await session.devices()
        } catch {
            problem = "Couldn't sign out \(device.name)."
        }
    }

    func signOutOthers() async {
        do {
            _ = try await session.signOutOtherDevices()
            problem = nil
            devices = try? await session.devices()
        } catch {
            problem = "Couldn't sign the other devices out."
        }
    }

    func revoke(_ credential: JellyfinCredential) async {
        do {
            try await session.revokeJellyfinCredential(credential.id)
            credentials.removeAll { $0.id == credential.id }
        } catch {
            problem = "Couldn't revoke \(credential.label)."
        }
    }

    /// The languages nectar's libraries usually hold (ISO 639-2/T), as the web's Account page offers them.
    static let languages = ["eng", "fra", "deu", "spa", "ita", "por", "nld", "swe", "nor", "dan", "fin", "pol", "ces", "rus", "ukr",
                            "ell", "tur", "heb", "ara", "hin", "jpn", "kor", "zho", "tha", "vie", "ind"]

    private static let iso1 = ["eng": "en", "fra": "fr", "deu": "de", "spa": "es", "ita": "it", "por": "pt", "nld": "nl", "swe": "sv",
                               "nor": "no", "dan": "da", "fin": "fi", "pol": "pl", "ces": "cs", "rus": "ru", "ukr": "uk", "ell": "el",
                               "tur": "tr", "heb": "he", "ara": "ar", "hin": "hi", "jpn": "ja", "kor": "ko", "zho": "zh", "tha": "th",
                               "vie": "vi", "ind": "id"]

    /// "English", in the TV's own language.
    static func name(of code: String) -> String {
        Locale.current.localizedString(forLanguageCode: iso1[code] ?? code) ?? code
    }
}
