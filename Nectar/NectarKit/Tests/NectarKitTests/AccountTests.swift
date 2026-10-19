import Foundation
import Testing
@testable import NectarKit

private actor Server: HTTPTransport {
    private let answers: [String: (Int, String)]
    private(set) var requests: [URLRequest] = []

    init(_ answers: [String: (Int, String)]) {
        self.answers = answers
    }

    nonisolated func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        try await answer(request)
    }

    private func answer(_ request: URLRequest) throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        let key = "\(request.httpMethod ?? "GET") \(request.url!.path)"
        guard let (status, body) = answers[key] else { throw URLError(.fileDoesNotExist) }
        return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }
}

private func session(_ transport: Server) -> NectarSession {
    NectarSession(
        baseURL: URL(string: "https://nectar.test")!,
        tokenEndpoint: URL(string: "https://nectar.test/token")!,
        clientID: "nectar-tv",
        store: InMemoryTokenStore(TokenSet(accessToken: "jwt-1", tokenType: "Bearer", expiresIn: nil, refreshToken: "r1")),
        transport: transport
    )
}

private let prefs = #"""
{"preferred_audio_language":"eng","preferred_subtitle_language":null,"subtitle_mode":"auto","max_streaming_bitrate":40000000,
 "transcode_preference":"quality","theme":"dark","home_sections":["continue","recent"],"locale":"en-US","region":"US",
 "time_zone":"America/New_York","prefer_original_audio":false}
"""#

private func body(_ request: URLRequest?) throws -> [String: Any] {
    try #require(JSONSerialization.jsonObject(with: request?.httpBody ?? Data()) as? [String: Any])
}

@Suite("My account")
struct AccountTests {

    @Test func preferencesReadTheFieldsTheTVShows() async throws {
        let p = try await session(Server(["GET /api/v1/users/me/preferences": (200, prefs)])).preferences()
        #expect(p.audioLanguage == "eng" && p.subtitleLanguage == nil)
        #expect(p.subtitleMode == .auto && p.preferOriginalAudio == false)
    }

    @Test func savingSendsBackEverythingItRead() async throws {
        let server = Server(["GET /api/v1/users/me/preferences": (200, prefs), "PUT /api/v1/users/me/preferences": (200, prefs)])
        var p = try await session(server).preferences()
        p.subtitleLanguage = "spa"
        p.subtitleMode = .always
        p.preferOriginalAudio = true
        _ = try await session(server).save(p)

        let sent = try body(await server.requests.last)
        #expect(await server.requests.last?.httpMethod == "PUT")
        #expect(sent["preferred_subtitle_language"] as? String == "spa")
        #expect(sent["subtitle_mode"] as? String == "always")
        #expect(sent["prefer_original_audio"] as? Bool == true)
        // A full replace: the fields the TV doesn't show go back as they came.
        #expect(sent["max_streaming_bitrate"] as? Int == 40000000)
        #expect(sent["home_sections"] as? [String] == ["continue", "recent"])
        #expect(sent["time_zone"] as? String == "America/New_York")
        #expect(sent["preferred_audio_language"] as? String == "eng")
    }

    @Test func theSameSettingsAreEqualWhateverTheKeyOrder() {
        let a = Preferences(document: Data(#"{"subtitle_mode":"auto","preferred_audio_language":"eng"}"#.utf8))
        let b = Preferences(document: Data(#"{"preferred_audio_language":"eng","subtitle_mode":"auto"}"#.utf8))
        var c = b
        c.subtitleMode = .always
        #expect(a == b)
        #expect(a != c)
    }

    @Test func nectarsDefaultSubtitlesAreNull() async throws {
        let server = Server(["GET /api/v1/users/me/preferences": (200, prefs), "PUT /api/v1/users/me/preferences": (200, prefs)])
        var p = try await session(server).preferences()
        p.subtitleMode = .serverDefault
        _ = try await session(server).save(p)
        #expect(try body(await server.requests.last)["subtitle_mode"] is NSNull)
    }

    @Test func devicesKnowWhichIsThisOne() async throws {
        let server = Server(["GET /api/v1/auth/devices": (200, #"""
        {"devices":[
          {"id":"d1","kind":"device","client_id":"nectar-tv","device_name":"Master Bedroom TV","sign_in_method":"device_code","bypasses_mfa":false,
           "created_at":"2026-10-18T22:00:00Z","last_used_at":"2026-10-19T17:50:00.5Z","last_ip":"192.168.67.40","current":true},
          {"id":"d2","kind":"web","client_id":null,"device_name":null,"sign_in_method":"password","bypasses_mfa":false,
           "created_at":"2026-10-10T08:00:00Z","last_used_at":"2026-10-19T09:00:00Z","last_ip":"192.168.67.10","current":false}
        ]}
        """#)])
        let devices = try await session(server).devices()
        #expect(devices.map(\.id) == ["d1", "d2"])
        #expect(devices[0].isCurrent && devices[0].name == "Master Bedroom TV")
        #expect(devices[1].name == "Web browser", "an unnamed web session gets a name to show")
        #expect(devices[0].lastUsed != nil)
    }

    @Test func signingOutIsTheRightCall() async throws {
        let server = Server([
            "DELETE /api/v1/auth/devices/d2": (200, #"{"ok":true}"#),
            "POST /api/v1/auth/devices/sign-out-others": (200, #"{"ok":true,"signed_out":3}"#),
            "DELETE /api/v1/users/me/jellyfin-credentials/j1": (204, ""),
        ])
        try await session(server).signOut(device: "d2")
        #expect(try await session(server).signOutOtherDevices() == 3)
        try await session(server).revokeJellyfinCredential("j1")
        #expect(await server.requests.map { "\($0.httpMethod ?? "") \($0.url!.path)" } == [
            "DELETE /api/v1/auth/devices/d2", "POST /api/v1/auth/devices/sign-out-others", "DELETE /api/v1/users/me/jellyfin-credentials/j1",
        ])
    }

    @Test func jellyfinCredentialsAndWhetherTheyreOn() async throws {
        let server = Server(["GET /api/v1/users/me/jellyfin-credentials": (200, #"""
        {"credentials":[{"id":"j1","username":"nate","label":"Infuse on the iPad","created_at":"2026-10-01T10:00:00Z","last_used_at":null}],
         "enabled":true,"risk":{"version":"1","text":"…"}}
        """#)])
        let list = try await session(server).jellyfinCredentials()
        #expect(list.enabled && list.credentials.map(\.label) == ["Infuse on the iPad"])
        #expect(list.credentials[0].lastUsed == nil)
    }
}
