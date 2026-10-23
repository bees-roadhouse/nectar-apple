import NectarKit
import SwiftUI
import UIKit

/// The Discover tab, native (#158, Capping's `native-discover.md`): titles you don't have, and one tap to ask for one.
/// Its own search field (what you don't own; the Search tab is what you do), the kind as a segmented control, and the
/// server's shelves. Until nectar #697 serves shelves and browse filters, the shelves are today's trending movies and
/// shows, and the Browse chips wait for it. The TV app's `DiscoverModel` asks nectar; this controller feeds it the field.
final class DiscoverController: UIHostingController<DiscoverScreen>, UISearchResultsUpdating {

    private let model: DiscoverModel
    private var running: Task<Void, Never>?

    init(model: DiscoverModel, screen: DiscoverScreen) {
        self.model = model
        super.init(rootView: screen)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not from a storyboard") }

    override func viewDidLoad() {
        super.viewDidLoad()
        let search = UISearchController(searchResultsController: nil)
        search.searchResultsUpdater = self
        search.obscuresBackgroundDuringPresentation = false
        search.searchBar.placeholder = "Movies and TV not in your library"
        navigationItem.searchController = search
        navigationItem.hidesSearchBarWhenScrolling = false
        // As Search's: presents within this tab, so the player and the other tabs stay free.
        definesPresentationContext = true
    }

    func updateSearchResults(for searchController: UISearchController) {
        let text = searchController.searchBar.text ?? ""
        guard text != model.query else { return }
        model.query = text
        running?.cancel()
        running = Task { [model] in await model.search() }
    }
}

/// All, Movies, TV: which titles the shelves and the results show (the web's pills). Music waits for nectar's music
/// discovery.
enum DiscoverFilter: String, CaseIterable, Identifiable {
    case all = "All"
    case movies = "Movies"
    case tv = "TV"

    var id: Self { self }

    func admits(_ item: DiscoverItem) -> Bool {
        switch self {
        case .all: true
        case .movies: item.kind == .movie
        case .tv: item.kind == .series
        }
    }
}

struct DiscoverScreen: View {

    let model: DiscoverModel
    let open: (DiscoverItem) -> Void
    let openRequests: () -> Void

    @State
    private var filter: DiscoverFilter = .all

    var body: some View {
        GeometryReader { proxy in
            let margin: CGFloat = proxy.size.width >= 428 ? 20 : 16
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    Picker("Kind", selection: $filter) {
                        ForEach(DiscoverFilter.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .padding(.horizontal, margin)
                    if model.query.trimmingCharacters(in: .whitespaces).isEmpty {
                        shelves(width: proxy.size.width, margin: margin)
                    } else {
                        results(width: proxy.size.width, margin: margin)
                    }
                }
                .padding(.top, 8)
            }
            .contentMargins(.bottom, 32, for: .scrollContent)
            .scrollDismissesKeyboard(.immediately)
            .refreshable { await model.reload() }
        }
        .background(Color.brhNight)
        .task { await model.loadTrending() }
    }

    @ViewBuilder
    private func shelves(width: CGFloat, margin: CGFloat) -> some View {
        switch model.trending {
        case .loading:
            ForEach(0 ..< 2, id: \.self) { _ in ShelfPlaceholder(margin: margin) }
        case let .failed(why):
            Unavailable(title: "Discover isn't available right now", detail: why, retry: { Task { await model.reload() } })
        case let .loaded(movies, shows):
            let movies = movies.filter(filter.admits)
            let shows = shows.filter(filter.admits)
            if !movies.isEmpty { shelf("Trending movies", movies, margin: margin) }
            if !shows.isEmpty { shelf("Trending shows", shows, margin: margin) }
            Foot(margin: margin, openRequests: openRequests)
        }
    }

    private func shelf(_ title: String, _ items: [DiscoverItem], margin: CGFloat) -> some View {
        Shelf(title: title, margin: margin) {
            ForEach(items) { item in
                DiscoverCard(item: item, state: model.state(of: item), width: Poster.width, open: open) { Task { await model.want(item) } }
            }
        }
    }

    @ViewBuilder
    private func results(width: CGFloat, margin: CGFloat) -> some View {
        let cell = discoverCell(width: width, margin: margin)
        switch model.results {
        case .idle, .searching:
            DiscoverGrid(margin: margin, cell: cell) {
                ForEach(0 ..< 9, id: \.self) { _ in RoundedRectangle(cornerRadius: 8).fill(Color.brhCard).frame(width: cell, height: cell * 1.5) }
            }
        case let .failed(why):
            Unavailable(title: "Discover isn't available right now", detail: why, retry: { Task { await model.search() } })
        case let .found(items):
            let items = items.filter(filter.admits)
            if items.isEmpty {
                Unavailable(title: "Nothing matches “\(model.query)”", detail: scopeLine, retry: nil)
            } else {
                Text("Results for “\(model.query)”").font(.title3.weight(.semibold)).padding(.horizontal, margin)
                DiscoverGrid(margin: margin, cell: cell) {
                    ForEach(items) { item in
                        DiscoverCard(item: item, state: model.state(of: item), width: cell, open: open) { Task { await model.want(item) } }
                    }
                }
            }
        }
    }

    private var scopeLine: String {
        switch filter {
        case .all: "in movies and TV"
        case .movies: "in movies"
        case .tv: "in TV"
        }
    }
}

/// A poster you don't have: 2:3, the title and year under it, the state tag top-right; tap for the detail, hold to
/// request.
private struct DiscoverCard: View {
    let item: DiscoverItem
    let state: DiscoverState?
    let width: CGFloat
    let open: (DiscoverItem) -> Void
    let request: () -> Void

    var body: some View {
        Button { open(item) } label: {
            VStack(alignment: .leading, spacing: 3) {
                CachedImage(url: item.posterURL, maxPixelSize: Int(width * 3), blurHash: nil) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    Color.brhCard.overlay { Image(systemName: item.kind == .movie ? "film" : "tv").foregroundStyle(.tertiary) }
                }
                .frame(width: width, height: width * 1.5)
                .clipShape(.rect(cornerRadius: 8))
                .overlay(alignment: .topTrailing) { if let state { StateTag(state: state).padding(6) } }
                .shadow(color: .black.opacity(0.3), radius: 6, y: 3)
                Text(item.title).font(.subheadline.weight(.medium)).lineLimit(1).padding(.top, 3)
                Text(item.year.map(String.init) ?? " ").font(.footnote).foregroundStyle(.secondary)
            }
            .frame(width: width, alignment: .leading)
        }
        .buttonStyle(Pressed())
        .contextMenu {
            if let state {
                Button(state.label, systemImage: "checkmark") {}.disabled(true)
            } else {
                Button("Request", systemImage: "plus.circle", action: request)
            }
            Button("Details", systemImage: "info.circle") { open(item) }
        }
    }
}

/// Where a title you don't have stands (#142's words): Requested at rest, Wanted green while it downloads.
struct StateTag: View {
    let state: DiscoverState

    var body: some View {
        let wanted = state == .wanted
        HStack(spacing: 3) {
            if wanted { Image(systemName: "arrow.down") }
            Text(state.label)
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(wanted ? Color.black : .primary)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(wanted ? Color.brhOk : Color.brhCard.opacity(0.92), in: .capsule)
        .lineLimit(1)
        .fixedSize()
    }
}

/// A grid cell's width: three posters a row on a phone, more on wider screens.
private func discoverCell(width: CGFloat, margin: CGFloat) -> CGFloat {
    let inner: CGFloat = width - margin * 2
    let columns: Int = max(3, Int((inner + 12) / 132))
    return (inner - CGFloat(columns - 1) * 12) / CGFloat(columns)
}

/// Results and See all.
private struct DiscoverGrid<Cells: View>: View {
    let margin: CGFloat
    let cell: CGFloat
    @ViewBuilder
    let cells: () -> Cells

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: cell, maximum: cell), spacing: 12, alignment: .top)], alignment: .leading, spacing: 18) {
            cells()
        }
        .padding(.horizontal, margin)
    }
}

/// A shelf arriving whole: the header bar and the posters at their size.
private struct ShelfPlaceholder: View {
    let margin: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            RoundedRectangle(cornerRadius: 4).fill(Color.brhCard).frame(width: 180, height: 20).frame(minHeight: 44)
            HStack(spacing: 12) {
                ForEach(0 ..< 4, id: \.self) { _ in RoundedRectangle(cornerRadius: 8).fill(Color.brhCard).frame(width: Poster.width, height: Poster.width * 1.5) }
            }
        }
        .padding(.horizontal, margin)
        .accessibilityLabel("Loading")
    }
}

/// One thing went wrong, said once, with a way out when there is one.
private struct Unavailable: View {
    let title: String
    let detail: String?
    let retry: (() -> Void)?

    var body: some View {
        VStack(spacing: 8) {
            Text(title).font(.subheadline.weight(.semibold))
            if let detail { Text(detail).font(.footnote).foregroundStyle(.secondary) }
            if let retry { Button("Check again", action: retry).buttonStyle(CapsuleStyle(primary: false)).padding(.top, 6) }
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity, minHeight: 240)
        .padding(.horizontal, 32)
    }
}

/// After the last shelf: your requests.
private struct Foot: View {
    let margin: CGFloat
    let openRequests: () -> Void

    var body: some View {
        Button(action: openRequests) {
            HStack {
                Text("Your requests")
                Spacer()
                Image(systemName: "chevron.forward").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
            }
            .font(.subheadline)
            .foregroundStyle(.primary)
            .frame(minHeight: 44)
            .padding(.horizontal, margin)
            .contentShape(.rect)
        }
        .buttonStyle(Pressed())
    }
}

/// A title you don't have (the TV's `DiscoverDetail`, on the phone): the backdrop, what it is, and one Request
/// capsule. No Play, no cast: it isn't yours yet, and the page says so by what it lacks.
struct DiscoverDetail: View {
    let item: DiscoverItem
    let model: DiscoverModel

    @State
    private var expanded = false
    @State
    private var failed = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                CachedImage(url: item.backdropURL ?? item.posterURL, maxPixelSize: 1600, blurHash: nil) { image in
                    image.resizable().scaledToFill()
                } placeholder: { Color.brhCard }
                .frame(maxWidth: .infinity)
                .aspectRatio(16 / 9, contentMode: .fit)
                .clipped()
                .overlay(alignment: .bottom) {
                    LinearGradient(colors: [.clear, Color.brhNight], startPoint: .top, endPoint: .bottom).frame(height: 80)
                }
                VStack(alignment: .leading, spacing: 12) {
                    Text(item.title).font(.title.weight(.bold))
                    Text(meta).font(.subheadline).foregroundStyle(.secondary)
                    if let overview = item.overview, !overview.isEmpty {
                        Text(overview).font(.body).lineLimit(expanded ? nil : 3)
                        if !expanded { Button("More") { withAnimation(snappy) { expanded = true } }.font(.subheadline.weight(.semibold)) }
                    }
                    request.padding(.top, 8)
                }
                .padding(.horizontal, 16)
            }
        }
        // The system's soft edge keeps the status bar and the glass back button legible over the art (Capping).
        .scrollEdgeEffectStyle(.soft, for: .top)
        .ignoresSafeArea(edges: .top)
        .background(Color.brhNight)
        .sensoryFeedback(.success, trigger: model.state(of: item))
    }

    private var meta: String {
        [item.year.map(String.init), item.kind == .movie ? "Movie" : "TV", item.rating.map { String(format: "%.1f", $0) }]
            .compactMap(\.self).joined(separator: " · ")
    }

    /// Request's outcomes: in flight keeps the label with progress inside; confirmed becomes the state; refused or
    /// unreachable says so under the capsule, which goes back to Request.
    @ViewBuilder
    private var request: some View {
        if let state = model.state(of: item) {
            VStack(alignment: .leading, spacing: 6) {
                StateTag(state: state).scaleEffect(1.2, anchor: .leading)
                Text(state.detail).font(.footnote).foregroundStyle(.secondary)
            }
        } else {
            VStack(alignment: .leading, spacing: 8) {
                Button {
                    failed = false
                    Task {
                        await model.want(item)
                        failed = model.state(of: item) == nil
                    }
                } label: {
                    HStack(spacing: 8) {
                        if model.asking == item.id { ProgressView().tint(Color.brhGoldInk) }
                        Text("Request")
                    }
                    .frame(maxWidth: .infinity, minHeight: 48)
                }
                .buttonStyle(CapsuleStyle(primary: true))
                .disabled(model.asking == item.id)
                Text(failed ? "Couldn't request it. Check your connection, or ask an admin." : "An admin approves it, then the search starts.")
                    .font(.footnote).foregroundStyle(failed ? Color.red : .secondary)
            }
        }
    }
}
