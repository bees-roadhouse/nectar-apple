import NectarKit
import SwiftUI

/// Server → Now (#83): who's watching what, and how the host and transcoders are coping, every five seconds
/// while it's on screen.
@MainActor
@Observable
final class NowModel {

    enum State {
        case loading
        case loaded
        case refused
        case failed
    }

    let session: NectarSession
    private(set) var state: State = .loading
    private(set) var sessions: [LiveSession] = []
    private(set) var system: SystemStatus?

    init(session: NectarSession) {
        self.session = session
    }

    /// Ends when the Now section leaves the screen (its task is cancelled).
    func follow() async {
        while !Task.isCancelled {
            await load()
            try? await Task.sleep(for: .seconds(5))
        }
    }

    private func load() async {
        async let watching = session.liveSessions()
        async let host = session.systemStatus()
        do {
            (sessions, system) = try await (watching, host)
            state = .loaded
        } catch NectarSessionError.unexpectedStatus(403) {
            state = .refused
        } catch {
            // A missed refresh keeps what was last seen; only a first failure says so.
            if case .loading = state { state = .failed }
        }
    }
}

struct NowView: View {

    let model: NowModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 56) {
                switch model.state {
                case .loading:
                    ProgressView()
                case .refused:
                    Text("Only an admin can see the server.")
                        .foregroundStyle(.secondary)
                case .failed:
                    Text("Couldn't reach the server. Trying again every few seconds.")
                        .foregroundStyle(.secondary)
                case .loaded:
                    WatchingNow(sessions: model.sessions)
                    if let system = model.system {
                        Host(system: system)
                        Transcoders(gpus: system.gpus, active: system.activeTranscodes)
                        Backlog(queues: system.queues)
                    }
                }
            }
            .padding(80)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task { await model.follow() }
    }
}

private struct WatchingNow: View {
    let sessions: [LiveSession]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Watching now")
                .font(.headline)
            if sessions.isEmpty {
                Text("Nobody's watching.")
                    .foregroundStyle(.secondary)
                    .modifier(FocusRow())
            }
            ForEach(sessions) { session in
                HStack(spacing: 32) {
                    Text(session.username ?? "Someone")
                        .frame(width: 200, alignment: .leading)
                    Text(session.itemName ?? "Something")
                        .lineLimit(1)
                        .frame(width: 520, alignment: .leading)
                    Text([session.device, session.client].compactMap { $0 }.joined(separator: " · "))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .frame(width: 380, alignment: .leading)
                    Text(method(session.playMethod))
                        .frame(width: 180, alignment: .leading)
                    if let progress = session.progress {
                        ProgressView(value: progress)
                            .frame(width: 160)
                    }
                    if session.isPaused {
                        Image(systemName: "pause.fill")
                            .foregroundStyle(.secondary)
                    }
                }
                .modifier(FocusRow())
            }
        }
    }

    /// The badge's words for nectar's play methods.
    private func method(_ playMethod: String?) -> String {
        switch playMethod {
        case "DirectPlay": "Direct play"
        case "DirectStream": "Remux"
        case "Transcode": "Transcode"
        default: playMethod ?? ""
        }
    }
}

private struct Host: View {
    let system: SystemStatus

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            Text("The server")
                .font(.headline)
            HStack(spacing: 56) {
                tile("\(Int(system.cpuPercent.rounded()))%", "processor")
                tile("\(byteText(system.memoryUsed)) of \(byteText(system.memoryTotal))", "memory")
                tile("↓ \(byteText(system.receivedBytesPerSecond))/s  ↑ \(byteText(system.sentBytesPerSecond))/s", "network")
            }
            ForEach(system.disks, id: \.mount) { disk in
                HStack(spacing: 24) {
                    Text(disk.mount)
                        .frame(width: 320, alignment: .leading)
                        .lineLimit(1)
                    ProgressView(value: disk.share)
                        .frame(width: 360)
                    Text("\(byteText(disk.used)) of \(byteText(disk.total))")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                .modifier(FocusRow())
            }
        }
    }

    private func tile(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(value)
                .font(.title3.bold())
                .monospacedDigit()
            Text(label)
                .foregroundStyle(.secondary)
        }
    }
}

private struct Transcoders: View {
    let gpus: [SystemStatus.GPU]
    let active: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(active == 1 ? "Transcoders · 1 stream" : "Transcoders · \(active) streams")
                .font(.headline)
            if gpus.isEmpty {
                Text("No transcoders have checked in.")
                    .foregroundStyle(.secondary)
            }
            ForEach(gpus, id: \.workerID) { gpu in
                HStack(spacing: 32) {
                    Text(gpu.workerID)
                        .frame(width: 320, alignment: .leading)
                        .lineLimit(1)
                    if gpu.alive {
                        Text(details(gpu))
                            .monospacedDigit()
                    } else {
                        Text("offline")
                            .foregroundStyle(.secondary)
                    }
                }
                .modifier(FocusRow())
            }
        }
    }

    private func details(_ gpu: SystemStatus.GPU) -> String {
        var parts = [gpu.type.map { $0.uppercased() } ?? "CPU"]
        if let utilization = gpu.utilizationPercent { parts.append("\(Int(utilization.rounded()))%") }
        if let sessions = gpu.encodeSessions { parts.append(sessions == 1 ? "1 encode" : "\(sessions) encodes") }
        if let used = gpu.memoryUsed, let total = gpu.memoryTotal { parts.append("\(byteText(used)) of \(byteText(total))") }
        return parts.joined(separator: " · ")
    }
}

private struct Backlog: View {
    let queues: [String: Int]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Waiting to be done")
                .font(.headline)
            Text(queues.isEmpty ? "Nothing waiting." : queues.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: " · "))
                .foregroundStyle(.secondary)
                .modifier(FocusRow())
        }
    }
}
