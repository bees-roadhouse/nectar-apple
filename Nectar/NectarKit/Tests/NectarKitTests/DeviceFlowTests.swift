import Foundation
import Testing
@testable import NectarKit

/// A transport that answers from a script and records what it was asked.
private final class ScriptedTransport: HTTPTransport, @unchecked Sendable {

    enum Step {
        case json(Int, String)
        case failure(URLError.Code)
    }

    private var steps: [Step]
    private(set) var requests: [URLRequest] = []

    init(_ steps: [Step]) {
        self.steps = steps
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        guard !steps.isEmpty else { Issue.record("transport called more often than scripted"); throw URLError(.unknown) }
        switch steps.removeFirst() {
        case let .json(status, body):
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
            return (Data(body.utf8), response)
        case let .failure(code):
            throw URLError(code)
        }
    }

    func formBody(_ index: Int) -> [String: String] {
        let body = String(decoding: requests[index].httpBody ?? Data(), as: UTF8.self)
        var fields: [String: String] = [:]
        for pair in body.split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1).map { String($0).removingPercentEncoding ?? String($0) }
            fields[parts[0]] = parts.count > 1 ? parts[1] : ""
        }
        return fields
    }
}

/// Records requested sleeps instead of sleeping.
private final class SleepRecorder: @unchecked Sendable {
    private(set) var seconds: [Int] = []
    var sleep: @Sendable (Duration) async throws -> Void {
        { [self] duration in seconds.append(Int(duration.components.seconds)) }
    }
}

private let endpoints = DeviceFlowClient.Endpoints(
    deviceAuthorization: URL(string: "https://nectar.test/device_authorization")!,
    token: URL(string: "https://nectar.test/token")!
)

private let authorization = DeviceAuthorization(
    deviceCode: "dev-123",
    userCode: "BCDF-GHJK",
    verificationURI: URL(string: "https://nectar.test/activate")!,
    verificationURIComplete: URL(string: "https://nectar.test/activate?code=BCDF-GHJK"),
    expiresIn: 600,
    interval: 5
)

private let tokenJSON = #"{"access_token":"jwt","token_type":"Bearer","expires_in":86400,"refresh_token":"r1"}"#

private func pending() -> ScriptedTransport.Step { .json(400, #"{"error":"authorization_pending"}"#) }

private func client(_ transport: ScriptedTransport, _ sleeper: SleepRecorder) -> DeviceFlowClient {
    DeviceFlowClient(
        issuer: URL(string: "https://nectar.test")!,
        clientID: "nectar-tv",
        deviceName: "Living Room TV",
        transport: transport,
        sleep: sleeper.sleep
    )
}

@Suite("Device flow (RFC 8628)")
struct DeviceFlowTests {

    @Test func discoversEndpointsFromOpenIDConfiguration() async throws {
        let transport = ScriptedTransport([.json(200, #"{"issuer":"https://nectar.test","token_endpoint":"https://nectar.test/token","device_authorization_endpoint":"https://nectar.test/device_authorization"}"#)])
        let found = try await client(transport, SleepRecorder()).discover()
        #expect(found == endpoints)
        #expect(transport.requests.first?.url?.path == "/.well-known/openid-configuration")
    }

    @Test func startRequestsACodeWithClientScopeAndDeviceName() async throws {
        let transport = ScriptedTransport([.json(200, #"{"device_code":"dev-123","user_code":"BCDF-GHJK","verification_uri":"https://nectar.test/activate","verification_uri_complete":"https://nectar.test/activate?code=BCDF-GHJK","expires_in":600,"interval":5}"#)])
        let started = try await client(transport, SleepRecorder()).start(at: endpoints)
        #expect(started == authorization)
        let form = transport.formBody(0)
        #expect(transport.requests[0].httpMethod == "POST")
        #expect(transport.requests[0].value(forHTTPHeaderField: "Content-Type") == "application/x-www-form-urlencoded")
        #expect(form["client_id"] == "nectar-tv")
        #expect(form["scope"] == "openid profile offline_access")
        #expect(form["device_name"] == "Living Room TV")
    }

    @Test func pollsAtTheIntervalUntilApproved() async throws {
        let transport = ScriptedTransport([pending(), pending(), .json(200, tokenJSON)])
        let sleeper = SleepRecorder()
        let outcome = try await client(transport, sleeper).poll(authorization, at: endpoints)
        #expect(outcome == .approved(TokenSet(accessToken: "jwt", tokenType: "Bearer", expiresIn: 86400, refreshToken: "r1")))
        #expect(sleeper.seconds == [5, 5, 5])
        let form = transport.formBody(2)
        #expect(form["grant_type"] == "urn:ietf:params:oauth:grant-type:device_code")
        #expect(form["device_code"] == "dev-123")
        #expect(form["client_id"] == "nectar-tv")
    }

    @Test func slowDownAddsFiveSecondsForTheRestOfTheFlow() async throws {
        let transport = ScriptedTransport([.json(400, #"{"error":"slow_down"}"#), pending(), .json(200, tokenJSON)])
        let sleeper = SleepRecorder()
        _ = try await client(transport, sleeper).poll(authorization, at: endpoints)
        #expect(sleeper.seconds == [5, 10, 10])
    }

    @Test func deniedStopsPolling() async throws {
        let transport = ScriptedTransport([.json(400, #"{"error":"access_denied"}"#)])
        let outcome = try await client(transport, SleepRecorder()).poll(authorization, at: endpoints)
        #expect(outcome == .denied)
    }

    @Test(arguments: ["expired_token", "invalid_grant"])
    func expiredOrUnknownCodeMeansStartOver(error: String) async throws {
        let transport = ScriptedTransport([.json(400, #"{"error":"\#(error)"}"#)])
        let outcome = try await client(transport, SleepRecorder()).poll(authorization, at: endpoints)
        #expect(outcome == .expired)
    }

    @Test func networkFailureKeepsPolling() async throws {
        let transport = ScriptedTransport([.failure(.notConnectedToInternet), pending(), .json(200, tokenJSON)])
        let outcome = try await client(transport, SleepRecorder()).poll(authorization, at: endpoints)
        #expect(outcome == .approved(TokenSet(accessToken: "jwt", tokenType: "Bearer", expiresIn: 86400, refreshToken: "r1")))
    }

    @Test func givesUpWhenTheCodeLifetimeRunsOut() async throws {
        let short = DeviceAuthorization(deviceCode: "d", userCode: "U", verificationURI: authorization.verificationURI, verificationURIComplete: nil, expiresIn: 12, interval: 5)
        let transport = ScriptedTransport([pending(), pending()])
        let sleeper = SleepRecorder()
        let outcome = try await client(transport, sleeper).poll(short, at: endpoints)
        #expect(outcome == .expired)
        #expect(sleeper.seconds == [5, 5])
    }

    @Test func missingIntervalDefaultsToFiveSeconds() async throws {
        let noInterval = DeviceAuthorization(deviceCode: "d", userCode: "U", verificationURI: authorization.verificationURI, verificationURIComplete: nil, expiresIn: 600, interval: nil)
        let transport = ScriptedTransport([.json(200, tokenJSON)])
        let sleeper = SleepRecorder()
        _ = try await client(transport, sleeper).poll(noInterval, at: endpoints)
        #expect(sleeper.seconds == [5])
    }
}
