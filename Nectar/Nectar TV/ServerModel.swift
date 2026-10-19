import Foundation
import NectarKit

/// The admin Server screen's Stats (#81): the server's totals, the last 30 days, who watches, and the most watched.
@MainActor
@Observable
final class ServerModel {

    enum State {
        case loading
        case loaded
        /// nectar said this user isn't an admin.
        case refused
        case failed
    }

    let session: NectarSession
    private(set) var state: State = .loading
    private(set) var overview: StatsOverview?
    /// Thirty days to today, a quiet day as zero.
    private(set) var days: [ActivityPoint] = []
    private(set) var users: [UserStat] = []
    private(set) var mostWatched: [ItemStat] = []
    /// A most-watched title opened from the list.
    var opened: MediaCard?

    init(session: NectarSession) {
        self.session = session
    }

    func load() async {
        async let overview = session.statsOverview()
        async let activity = session.statsActivity()
        async let users = session.statsUsers()
        async let items = session.statsItems()
        do {
            let (totals, series, viewers, titles) = try await (overview, activity, users, items)
            self.overview = totals
            days = ActivityPoint.days(series, count: 30, endingOn: .now)
            self.users = viewers
            mostWatched = titles
            state = .loaded
        } catch NectarSessionError.unexpectedStatus(403) {
            state = .refused
        } catch {
            state = .failed
        }
    }

    func open(_ item: ItemStat) {
        guard let id = item.itemID else { return }
        opened = MediaCard(id: id, title: item.itemName)
    }
}
