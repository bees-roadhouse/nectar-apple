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
    @State private var browser: GenreBrowser

    init(name: String, session: NectarSession, open: @escaping (MediaCard) -> Void) {
        self.name = name
        self.session = session
        self.open = open
        _browser = State(initialValue: GenreBrowser(session: session, genre: name))
    }

    private var failure: some View {
        VStack(spacing: 12) {
            Text("Couldn't load titles in this genre").foregroundStyle(.secondary)
            Button("Retry") { Task { await browser.load(reset: browser.failedReset) } }.foregroundStyle(Color.brhGold)
        }
        .frame(maxWidth: .infinity)
    }

    var body: some View {
        GeometryReader { proxy in
            let margin: CGFloat = proxy.size.width >= 428 ? 20 : 16
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    // A failed pull to refresh shows its error where the pull was, at the top.
                    if browser.failed && browser.failedReset && browser.loaded { failure }
                    VStack(alignment: .leading, spacing: 12) {
                        Text(name).font(.title2.bold()).fixedSize(horizontal: false, vertical: true)
                        if browser.loaded {
                            Text(browser.total == 1 ? "1 title" : "\(browser.total) titles").font(.subheadline).foregroundStyle(.secondary)
                        } else {
                            Text("000 titles").font(.subheadline).foregroundStyle(.secondary)
                                .redacted(reason: .placeholder).accessibilityHidden(true)
                        }
                    }
                    if browser.loaded && browser.cards.isEmpty {
                        ContentUnavailableView("No titles in this genre", systemImage: "tag").frame(maxWidth: .infinity)
                    }
                    CatalogGrid(cards: browser.cards, session: session, width: max(1, proxy.size.width - margin * 2), loading: browser.loading && !browser.refreshing || !browser.loaded && !browser.failed, appeared: { card in
                        guard card.id == browser.cards.last?.id else { return }
                        Task { await browser.loadMore() }
                    }, open: open)
                    if browser.failed && !(browser.failedReset && browser.loaded) { failure }
                }
                .padding(.horizontal, margin).padding(.vertical, 16).padding(.bottom, 32)
            }
            .refreshable { await browser.load(reset: true) }
        }
        .background(Color.brhNight)
        .task { await browser.start() }
    }
}
