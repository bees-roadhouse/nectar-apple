import NectarKit
import SwiftUI

struct GenresScreen: View {
    let session: NectarSession
    let open: (String) -> Void
    @State private var genres: [String]?
    @State private var failed = false

    var body: some View {
        List {
            if let genres {
                if genres.isEmpty {
                    ContentUnavailableView("No genres yet", systemImage: "tag")
                } else {
                    ForEach(genres, id: \.self) { genre in
                        Button { open(genre) } label: { row(genre) }.buttonStyle(.plain)
                    }
                }
                if failed {
                    VStack(spacing: 12) {
                        Text("Couldn't refresh genres").foregroundStyle(.secondary)
                        Button("Retry") { Task { await load() } }.foregroundStyle(Color.brhGold)
                    }
                    .frame(maxWidth: .infinity)
                }
            } else if failed {
                ContentUnavailableView {
                    Label("Couldn't load genres", systemImage: "wifi.exclamationmark")
                } actions: {
                    Button("Retry") { Task { await load() } }.foregroundStyle(Color.brhGold)
                }
            } else {
                ForEach(0..<8) { _ in row("Genre name").redacted(reason: .placeholder).accessibilityHidden(true) }
            }
        }
        .listStyle(.plain).scrollContentBackground(.hidden).background(Color.brhNight)
        .task { await load() }.refreshable { await load() }
    }

    private func row(_ name: String) -> some View {
        HStack {
            Text(name).foregroundStyle(.primary).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold)).foregroundStyle(.tertiary).accessibilityHidden(true)
        }
        .frame(minHeight: 44).contentShape(Rectangle())
    }

    private func load() async {
        do { genres = try await session.filters(library: nil).genres; failed = false }
        catch { failed = true }
    }
}

struct GenreScreen: View {
    let name: String
    let session: NectarSession
    let open: (MediaCard) -> Void
    @State private var cards: [MediaCard] = []
    @State private var total = 0
    @State private var offset = 0
    @State private var loading = false
    @State private var loaded = false
    @State private var failed = false
    @State private var more = true
    @State private var generation = 0
    @State private var failedReset = false

    var body: some View {
        GeometryReader { proxy in
            let margin: CGFloat = proxy.size.width >= 428 ? 20 : 16
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(name).font(.title2.bold()).fixedSize(horizontal: false, vertical: true)
                        if loaded {
                            Text(total == 1 ? "1 title" : "\(total) titles").font(.subheadline).foregroundStyle(.secondary)
                        } else {
                            Text("000 titles").font(.subheadline).foregroundStyle(.secondary)
                                .redacted(reason: .placeholder).accessibilityHidden(true)
                        }
                    }
                    if loaded && cards.isEmpty {
                        ContentUnavailableView("No titles in this genre", systemImage: "tag").frame(maxWidth: .infinity)
                    }
                    CatalogGrid(cards: cards, session: session, width: max(1, proxy.size.width - margin * 2), loading: loading || !loaded && !failed, appeared: { card in
                        guard card.id == cards.last?.id, more, !failed else { return }
                        Task { await load(reset: false) }
                    }, open: open)
                    if failed {
                        VStack(spacing: 12) {
                            Text("Couldn't load titles in this genre").foregroundStyle(.secondary)
                            Button("Retry") { Task { await load(reset: failedReset) } }.foregroundStyle(Color.brhGold)
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
                .padding(.horizontal, margin).padding(.vertical, 16).padding(.bottom, 32)
            }
            .refreshable { await load(reset: true) }
        }
        .background(Color.brhNight)
        .task {
            guard !loaded, !loading, !failed else { return }
            await load(reset: true)
        }
    }

    private func load(reset: Bool) async {
        if reset {
            generation += 1
            loading = false
            offset = 0; more = true
        }
        guard !loading, more else { return }
        let request = generation
        loading = true; failed = false
        defer { if request == generation { loading = false } }
        var query = LibraryQuery(library: nil)
        query.genre = name; query.sort = .rating; query.descending = true; query.offset = offset
        do {
            let page = try await session.media(query)
            guard request == generation, !Task.isCancelled else { return }
            if reset { cards = page.items }
            else { cards += page.items.filter { item in !cards.contains { $0.id == item.id } } }
            offset += page.items.count; total = page.total; loaded = true
            more = !page.items.isEmpty && offset < page.total
        } catch {
            guard request == generation, !Task.isCancelled else { return }
            failed = true; failedReset = reset
        }
    }
}
