import Charts
import NectarKit
import SwiftUI

/// The admin Server screen: **Stats** (#81), what the household has watched as nectar counts it, and **Now**
/// (#83), who's watching and how the server is coping.
struct ServerView: View {

    enum Section: Hashable {
        case stats
        case now
    }

    @State
    private var model: ServerModel
    @State
    private var now: NowModel
    @State
    private var section: Section = .stats
    let playlistAdding: PlaylistAdding

    init(session: NectarSession, playlistAdding: PlaylistAdding) {
        _model = State(initialValue: ServerModel(session: session))
        _now = State(initialValue: NowModel(session: session))
        self.playlistAdding = playlistAdding
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // The title, the section and Stats' totals stay put; tvOS scrolls the rest to keep the focused row in view.
            VStack(alignment: .leading, spacing: 32) {
                HStack(spacing: 48) {
                    Text("Server")
                        .font(.title2.bold())
                    Picker("Section", selection: $section) {
                        Text("Stats").tag(Section.stats)
                        Text("Now").tag(Section.now)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 420)
                }
                if section == .stats, case .loaded = model.state, let overview = model.overview {
                    Totals(overview: overview)
                }
            }
            .padding(.horizontal, 80)
            .padding(.top, 60)
            switch section {
            case .stats:
                stats
            case .now:
                NowView(model: now)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.black.ignoresSafeArea())
        .task { await model.load() }
        .fullScreenCover(item: $model.opened) { card in
            ItemDetailView(id: card.id, session: model.session, playlistAdding: playlistAdding)
        }
    }

    private var stats: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 56) {
                switch model.state {
                case .loading:
                    ProgressView()
                case .refused:
                    Text("Only an admin can see the server's stats.")
                        .foregroundStyle(.secondary)
                case .failed:
                    VStack(alignment: .leading, spacing: 24) {
                        Text("Couldn't load the server's stats.")
                            .foregroundStyle(.secondary)
                        Button("Try again") { Task { await model.load() } }
                    }
                case .loaded:
                    LastThirtyDays(days: model.days)
                    WhoWatches(users: model.users)
                    MostWatched(items: model.mostWatched) { model.open($0) }
                }
            }
            .padding(80)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct Totals: View {
    let overview: StatsOverview

    var body: some View {
        HStack(spacing: 40) {
            tile("\(overview.totalPlays)", "plays")
            tile(watchTimeText(overview.totalWatchTimeSeconds), "watched")
            // nectar's total counts every item, episodes and tracks too; films and series are what people mean.
            tile("\(overview.itemsByType["movie"] ?? 0)", "films")
            tile("\(overview.itemsByType["series"] ?? 0)", "series")
            tile("\(overview.users)", overview.users == 1 ? "person" : "people")
            tile("\(overview.transcodePercent)%", "transcoded")
        }
    }

    private func tile(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(value)
                .font(.title.bold())
                .monospacedDigit()
            Text(label)
                .foregroundStyle(.secondary)
        }
        .frame(minWidth: 180, alignment: .leading)
    }
}

private struct LastThirtyDays: View {
    let days: [ActivityPoint]

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            Text("Plays, the last 30 days")
                .font(.headline)
            Chart(days, id: \.bucket) { day in
                BarMark(x: .value("Day", day.bucket, unit: .day), y: .value("Plays", day.plays))
                    .foregroundStyle(.white)
            }
            .chartXAxis {
                AxisMarks(values: .stride(by: .day, count: 7)) { _ in
                    AxisGridLine()
                    AxisValueLabel(format: .dateTime.month(.abbreviated).day())
                }
            }
            .frame(height: 320)
        }
    }
}

private struct WhoWatches: View {
    let users: [UserStat]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Who watches")
                .font(.headline)
            ForEach(users) { user in
                // Focusable so the remote can scroll down the screen; there's nothing to open.
                HStack(spacing: 32) {
                    Text(user.username ?? "Removed user")
                        .frame(width: 280, alignment: .leading)
                    Text("\(user.plays) plays · \(watchTimeText(user.watchTimeSeconds))")
                        .monospacedDigit()
                        .frame(width: 320, alignment: .leading)
                    Text(user.lastSeen.map { "seen \(Self.ago.localizedString(for: $0, relativeTo: .now))" } ?? "")
                        .foregroundStyle(.secondary)
                        .frame(width: 320, alignment: .leading)
                    Text(user.favoriteGenres.prefix(3).joined(separator: ", "))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .modifier(FocusRow())
            }
        }
    }

    private static let ago: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter
    }()
}

/// A row the remote can rest on, lit while it has focus, so the screen scrolls and shows where you are.
struct FocusRow: ViewModifier {
    @FocusState
    private var focused: Bool

    func body(content: Content) -> some View {
        content
            .padding(.vertical, 12)
            .padding(.horizontal, 20)
            .background(RoundedRectangle(cornerRadius: 12).fill(.white.opacity(focused ? 0.18 : 0)))
            .scaleEffect(focused ? 1.02 : 1)
            .animation(.easeOut(duration: 0.15), value: focused)
            .focusable()
            .focused($focused)
    }
}

private struct MostWatched: View {
    let items: [ItemStat]
    let open: (ItemStat) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Most watched")
                .font(.headline)
            ForEach(Array(items.enumerated()), id: \.offset) { rank, item in
                Button { open(item) } label: {
                    HStack(spacing: 32) {
                        Text("\(rank + 1)")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .frame(width: 60, alignment: .trailing)
                        Text(item.itemName ?? "A removed title")
                            .frame(width: 640, alignment: .leading)
                            .lineLimit(1)
                        Text("\(item.plays) plays")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }
                .disabled(item.itemID == nil)
            }
        }
    }
}
