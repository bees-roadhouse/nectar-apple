import NectarKit
import SwiftUI

extension PreloadManager {
    /// What's pre-loaded, by title; reading it redraws a view when it changes.
    var entries: [PreloadEntry] {
        _ = revision
        return store.index.entries.values.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }
}

/// Pre-load on a title's page (#85): start it, watch it come down (selecting cancels), or remove the TV's copy.
/// A file the TV can't play as it is says so up front; nectar#504's remux will widen what can.
struct PreloadButton: View {

    let detail: ItemDetail
    let session: NectarSession

    private var manager: PreloadManager { .shared }

    var body: some View {
        if !PreloadIndex.canPlayLocally(detail.source, capabilities: PlayerModel.capabilities) {
            Button("Can't pre-load this one yet", systemImage: "arrow.down.circle") {}
                .disabled(true)
        } else {
            switch manager.state(for: detail.id) {
            case .none:
                Button("Pre-load", systemImage: "arrow.down.circle") { start() }
            case let .downloading(fraction):
                Button(fraction.map { "Pre-loading \(Int($0 * 100))%" } ?? "Pre-loading…", systemImage: "xmark.circle") {
                    manager.remove(detail.id)
                }
            case .loaded:
                Button("Pre-loaded · Remove", systemImage: "checkmark.circle.fill") { manager.remove(detail.id) }
            case let .unavailable(why):
                Button("\(why) · Try again", systemImage: "exclamationmark.circle") { start() }
            }
        }
    }

    private func start() {
        Task { await manager.preload(itemID: detail.id, title: detail.title, source: detail.source, session: session) }
    }
}

/// Account → Pre-loaded on this TV: the space set aside, what's in it, and removing it.
struct PreloadStorage: View {

    private var manager: PreloadManager { .shared }

    var body: some View {
        let entries = manager.entries
        let used = entries.reduce(0) { $0 + $1.bytes }
        VStack(alignment: .leading, spacing: 20) {
            Text("\(Self.size(used)) of \(manager.budgetGB) GB used · \(Self.size(PreloadManager.freeSpace())) free on this TV")
                .foregroundStyle(.secondary)
            HStack(spacing: 20) {
                Text("Space for pre-loads")
                ForEach(PreloadManager.budgets, id: \.self) { gigabytes in
                    Button("\(gigabytes) GB") { manager.budgetGB = gigabytes }
                        .tint(manager.budgetGB == gigabytes ? .white : nil)
                }
            }
            if entries.isEmpty {
                Text("Nothing pre-loaded. A film's page offers Pre-load when this TV can play its file as it is.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(entries, id: \.itemID) { entry in
                    Button { manager.remove(entry.itemID) } label: {
                        HStack(spacing: 32) {
                            Text(entry.title)
                                .frame(width: 640, alignment: .leading)
                                .lineLimit(1)
                            Text(Self.size(entry.bytes))
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                            Text("Remove")
                        }
                    }
                }
                Button("Remove all", role: .destructive) { manager.removeAll() }
            }
        }
    }

    private static func size(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

/// "Pre-load next 3" on a series' page: the episodes it would play next, with how they're coming along.
struct PreloadNextButton: View {

    let series: ItemDetail
    let seasons: [Season]
    let session: NectarSession

    @State
    private var skipped: Int?

    private var manager: PreloadManager { .shared }

    var body: some View {
        let next = PreloadIndex.nextEpisodes(in: seasons)
        if !next.isEmpty {
            Button(label(next), systemImage: icon(next)) {
                Task { skipped = await manager.preloadNext(next, series: series.title, session: session) }
            }
        }
    }

    private func label(_ next: [Episode]) -> String {
        let states = next.map { manager.state(for: $0.id) }
        let loaded = states.filter { $0 == .loaded }.count
        let coming = states.compactMap { state -> Double? in
            if case let .downloading(fraction) = state { return fraction ?? 0 }
            return nil
        }
        if !coming.isEmpty {
            return "Pre-loading next \(next.count) · \(Int(coming.reduce(0, +) / Double(coming.count) * 100))%"
        }
        if loaded == next.count { return "Next \(next.count) pre-loaded" }
        if let skipped, skipped > 0 {
            return loaded > 0 ? "\(loaded) pre-loaded · \(skipped) can't be yet" : "Can't pre-load these yet"
        }
        return "Pre-load next \(next.count)"
    }

    private func icon(_ next: [Episode]) -> String {
        next.allSatisfy { manager.isPreloaded($0.id) } ? "checkmark.circle.fill" : "arrow.down.circle"
    }
}

extension View {
    /// A small mark on a title's artwork when this TV has it pre-loaded (#85).
    func preloadBadge(_ itemID: String) -> some View {
        modifier(PreloadBadge(itemID: itemID))
    }
}

private struct PreloadBadge: ViewModifier {
    let itemID: String

    func body(content: Content) -> some View {
        content.overlay(alignment: .topLeading) {
            if PreloadManager.shared.isPreloaded(itemID) {
                Image(systemName: "arrow.down.circle.fill")
                    .font(.title3)
                    .foregroundStyle(.white, .black.opacity(0.6))
                    .padding(10)
                    .accessibilityLabel("Pre-loaded")
            }
        }
    }
}
