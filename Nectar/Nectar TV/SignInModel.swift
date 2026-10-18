import Foundation
import NectarKit

/// Drives the device flow for the sign-in screen: show a code, poll, and get a fresh code when one expires.
@MainActor
@Observable
final class SignInModel {

    enum Phase: Equatable {
        case requestingCode
        case waiting(DeviceAuthorization)
        case declined
        case failed(String)
    }

    private(set) var phase: Phase = .requestingCode

    private let flow: DeviceFlowClient
    private let onApproved: (TokenSet, DeviceFlowClient.Endpoints) async -> Void
    private var task: Task<Void, Never>?

    init(flow: DeviceFlowClient, onApproved: @escaping (TokenSet, DeviceFlowClient.Endpoints) async -> Void) {
        self.flow = flow
        self.onApproved = onApproved
    }

    func run() {
        task?.cancel()
        task = Task { await loop() }
    }

    private func loop() async {
        do {
            let endpoints = try await flow.discover()
            while !Task.isCancelled {
                phase = .requestingCode
                let authorization = try await flow.start(at: endpoints)
                phase = .waiting(authorization)

                switch try await flow.poll(authorization, at: endpoints) {
                case let .approved(tokens):
                    await onApproved(tokens, endpoints)
                    return
                case .denied:
                    phase = .declined
                    return
                case .expired:
                    continue
                }
            }
        } catch is CancellationError {
        } catch {
            phase = .failed("Can't reach nectar right now.")
        }
    }
}
