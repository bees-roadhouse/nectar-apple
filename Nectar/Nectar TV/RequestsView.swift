import NectarKit
import SwiftUI

/// Your requests: what you asked for and where each stands. Approving is the server admin's, not the TV's;
/// cancelling comes with nectar#434.
struct RequestsView: View {

    let model: DiscoverModel

    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 24) {
                Text("Your requests").font(.largeTitle.bold())
                switch model.requests {
                case nil:
                    ProgressView()
                case let requests? where requests.isEmpty:
                    Text("You haven't asked for anything yet. Find something in Discover and choose Want it.")
                        .foregroundStyle(.secondary)
                case let requests?:
                    ForEach(requests) { request in
                        // Focusable so the list scrolls with the remote; it does nothing until cancel lands.
                        Button {} label: { RequestRow(request: request) }
                            .buttonStyle(.plain)
                    }
                }
            }
            .padding(80)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.ignoresSafeArea())
        .task { await model.loadRequests() }
    }
}

private struct RequestRow: View {

    let request: MyRequest

    var body: some View {
        HStack(spacing: 30) {
            Image(systemName: request.kind == .series ? "tv" : "film")
                .font(.title2)
                .frame(width: 60)
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.headline)
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Text(request.status.label)
                .font(.caption.bold())
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(badge, in: Capsule())
        }
        .padding(24)
        .frame(width: 1500)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
    }

    private var title: String {
        request.year.map { "\(request.title) (\(String($0)))" } ?? request.title
    }

    private var subtitle: String {
        var parts = [request.kind == .series ? "Series" : "Movie"]
        if let asked = request.requestedAt {
            parts.append("asked for " + asked.formatted(.relative(presentation: .named)))
        }
        if request.autoApproved, request.status != .pending { parts.append("approved automatically") }
        return parts.joined(separator: " · ")
    }

    private var badge: Color {
        switch request.status {
        case .pending: .orange.opacity(0.5)
        case .approved: .blue.opacity(0.5)
        case .fulfilled: .green.opacity(0.5)
        case .denied: .red.opacity(0.4)
        }
    }
}
