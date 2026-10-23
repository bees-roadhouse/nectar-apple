import NectarKit
import SwiftUI

/// The Library tab, native (#158 slice 4): the libraries as a chip row pinned under the title, the current library's
/// titles as a grid (the TV app's `LibraryModel`, a page at a time), and the system's own sort and filter menus.
struct LibraryScreen: View {

    let session: NectarSession
    let open: (MediaCard) -> Void

    @State
    private var libraries: [Library]?
    @State
    private var selected: Library.ID?
    /// One model per library, so switching back keeps its place and its filters.
    @State
    private var models: [Library.ID: LibraryModel] = [:]
    @State
    private var filtering = false

    var body: some View {
        GeometryReader { proxy in
            let margin: CGFloat = proxy.size.width >= 428 ? 20 : 16
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16, pinnedViews: [.sectionHeaders]) {
                    Section {
                        if let model = current {
                            Grid(model: model, session: session, width: proxy.size.width, margin: margin, open: open)
                        } else {
                            Placeholders(width: proxy.size.width, margin: margin, square: false)
                        }
                    } header: {
                        chips(margin: margin)
                    }
                }
            }
            .contentMargins(.bottom, 32, for: .scrollContent)
            .refreshable { await current?.reload() }
        }
        .background(Color.brhNight)
        .toolbar {
            if let model = current {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Sorting(model: model)
                    if !model.filters.genres.isEmpty || !model.filters.resolutions.isEmpty {
                        Button { filtering = true } label: {
                            Image(systemName: "line.3.horizontal.decrease.circle").accessibilityLabel("Filter")
                        }
                    }
                }
            }
        }
        .sheet(isPresented: $filtering) {
            if let model = current {
                Filters(model: model).presentationDetents([.medium]).presentationDragIndicator(.visible)
            }
        }
        .task {
            guard libraries == nil else { return }
            libraries = (try? await session.libraries()) ?? []
            selected = selected ?? libraries?.first?.id
        }
        .task(id: selected) {
            // The chosen library's model, made once and kept, so coming back finds it where it was.
            guard let selected, models[selected] == nil, let library = libraries?.first(where: { $0.id == selected }) else { return }
            models[selected] = LibraryModel(library: library, session: session, posterWidth: Grid.width(for: library))
        }
    }

    private var current: LibraryModel? {
        selected.flatMap { models[$0] }
    }

    private func chips(margin: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ScrollViewReader { reader in
                libraryChips(margin: margin)
                    .onChange(of: selected, initial: true) { _, id in if let id { reader.scrollTo(id, anchor: .center) } }
            }
            if let model = current { ActiveFilters(model: model, margin: margin) }
        }
        .padding(.bottom, 4)
        .background(Color.brhNight)
    }

    private func libraryChips(margin: CGFloat) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(libraries ?? []) { library in
                    let on = library.id == selected
                    Button { withAnimation(snappy) { selected = library.id } } label: {
                        Label(library.name, systemImage: library.kind.symbol)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(on ? Color.brhGoldInk : .primary)
                            .padding(.horizontal, 14)
                            .frame(minHeight: 36)
                            .background(on ? Color.brhGold : Color.brhCard, in: .capsule)
                            .overlay { if !on { Capsule().stroke(Color.brhLineDim) } }
                            .frame(minHeight: 44)
                    }
                    .id(library.id)
                }
            }
        }
        .contentMargins(.horizontal, margin, for: .scrollContent)
    }
}

/// The filters that are on, as chips under the libraries, each undone with its ×, so the grid's state is visible and
/// undoable without opening the sheet (Capping, #158).
private struct ActiveFilters: View {
    let model: LibraryModel
    let margin: CGFloat

    var body: some View {
        let on: [(String, (inout LibraryQuery) -> Void)] = [
            model.query.genre.map { ($0, { $0.genre = nil }) },
            model.query.resolution.map { ($0, { $0.resolution = nil }) },
        ].compactMap(\.self)
        if !on.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(on, id: \.0) { label, clear in
                        Button { Task { await model.change(clear) } } label: {
                            HStack(spacing: 6) {
                                Text(label)
                                Image(systemName: "xmark").imageScale(.small)
                            }
                            .font(.subheadline)
                            .padding(.horizontal, 12)
                            .frame(minHeight: 32)
                            .background(Color.brhCard, in: .capsule)
                            .overlay { Capsule().stroke(Color.brhLineDim) }
                            .frame(minHeight: 44)
                        }
                        .accessibilityLabel("Remove \(label)")
                    }
                }
            }
            .contentMargins(.horizontal, margin, for: .scrollContent)
        }
    }
}

/// The filters, as a medium sheet with the system's rows.
private struct Filters: View {
    let model: LibraryModel
    @Environment(\.dismiss)
    private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                if !model.filters.genres.isEmpty {
                    Picker("Genre", selection: Binding(get: { model.query.genre }, set: { genre in Task { await model.change { $0.genre = genre } } })) {
                        Text("All genres").tag(String?.none)
                        ForEach(model.filters.genres, id: \.self) { Text($0).tag(String?.some($0)) }
                    }
                }
                if !model.filters.resolutions.isEmpty {
                    Picker("Resolution", selection: Binding(get: { model.query.resolution }, set: { resolution in Task { await model.change { $0.resolution = resolution } } })) {
                        Text("Any resolution").tag(String?.none)
                        ForEach(model.filters.resolutions, id: \.self) { Text($0).tag(String?.some($0)) }
                    }
                }
            }
            .navigationTitle("Filter")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}

/// The current library's titles: three across on a phone, wider screens more, a page at a time as the end nears.
private struct Grid: View {
    let model: LibraryModel
    let session: NectarSession
    let width: CGFloat
    let margin: CGFloat
    let open: (MediaCard) -> Void

    @State
    private var adding: PlaylistAdding.Target?

    /// The poster's width on this screen, for the model's image prefetch: three across at a phone's width.
    static func width(for library: Library) -> CGFloat { 120 }

    private var square: Bool { model.library.kind == .music }

    var body: some View {
        let columns = max(3, Int((width - margin * 2 + 12) / (120 + 12)))
        let cell = (width - margin * 2 - CGFloat(columns - 1) * 12) / CGFloat(columns)
        VStack(alignment: .leading, spacing: 12) {
            if model.total > 0 {
                Text(model.library.kind.count(model.total)).font(.subheadline).foregroundStyle(.secondary).padding(.horizontal, margin)
            }
            switch model.state {
            case .loading where model.items.isEmpty:
                Placeholders(width: width, margin: margin, square: square)
            case .failed where model.items.isEmpty:
                Text("Can't reach nectar right now.").foregroundStyle(.secondary).padding(.horizontal, margin)
            case .loaded where model.items.isEmpty:
                // An empty library, or nothing left after the filters: the one-thing pattern, one line.
                Text(model.query.genre != nil || model.query.resolution != nil ? "Nothing matches these filters." : "Nothing in this library yet.")
                    .font(.subheadline).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 240)
            default:
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(cell), spacing: 12, alignment: .top), count: columns), alignment: .leading, spacing: 18) {
                    ForEach(model.items) { card in
                        tile(card, cell: cell)
                            .task { await model.loadMore(after: card) }
                    }
                    // The next page's tiles at their size, six at a time, never a spinner.
                    if model.items.count < model.total {
                        ForEach(0 ..< 6, id: \.self) { _ in
                            RoundedRectangle(cornerRadius: 8).fill(Color.brhCard).frame(width: cell, height: square ? cell : cell * 1.5)
                        }
                    }
                }
                .padding(.horizontal, margin)
            }
        }
        .task { await model.start() }
        .sheet(item: $adding) { target in
            AddToPlaylist(target: target, model: model.playlistAdding).presentationDetents([.medium, .large])
        }
    }

    private func tile(_ card: MediaCard, cell: CGFloat) -> some View {
        Button { open(card) } label: {
            VStack(alignment: .leading, spacing: 3) {
                CachedImage(url: session.resolve(card.posterPath, pixelWidth: Double(cell) * 3), maxPixelSize: Int(cell * 3), blurHash: card.posterBlurHash) { image in
                    image.resizable().scaledToFill()
                } placeholder: { Color.brhCard }
                .frame(width: cell, height: square ? cell : cell * 1.5)
                .cardStatus(CardStatus.of(card.pipeline, owned: true))
                .clipShape(.rect(cornerRadius: 8))
                .shadow(color: .black.opacity(0.3), radius: 6, y: 3)
                Text(card.title ?? "Untitled").font(.subheadline.weight(.medium)).lineLimit(1).padding(.top, 3)
                Text(card.year.map(String.init) ?? " ").font(.footnote).foregroundStyle(.secondary)
            }
        }
        .buttonStyle(Pressed())
        .contextMenu {
            Button("Details", systemImage: "info.circle") { open(card) }
            Button("Add to playlist", systemImage: "text.badge.plus") { adding = .owned(id: card.id, title: card.title ?? "") }
        } preview: {
            Preview(card: card, session: session)
        }
    }
}

/// Sort, order and the filters, as the system's own menu.
private struct Sorting: View {
    let model: LibraryModel

    var body: some View {
        Menu {
            Picker("Sort", selection: Binding(get: { model.query.sort }, set: { sort in Task { await model.change { $0.sort = sort } } })) {
                ForEach(LibraryQuery.Sort.allCases, id: \.self) { sort in Text(label(sort)).tag(sort) }
            }
            Picker("Order", selection: Binding(get: { model.query.descending }, set: { on in Task { await model.change { $0.descending = on } } })) {
                Text("Ascending").tag(false)
                Text("Descending").tag(true)
            }
        } label: {
            Image(systemName: "arrow.up.arrow.down.circle").accessibilityLabel("Sort")
        }
    }

    private func label(_ sort: LibraryQuery.Sort) -> String {
        switch sort {
        case .title: "Title"
        case .year: "Year"
        case .dateAdded: "Date added"
        case .rating: "Rating"
        }
    }
}

/// The grid arriving whole: tiles at their final size, never a spinner.
private struct Placeholders: View {
    let width: CGFloat
    let margin: CGFloat
    let square: Bool

    var body: some View {
        let cell = (width - margin * 2 - 24) / 3
        LazyVGrid(columns: Array(repeating: GridItem(.fixed(cell), spacing: 12), count: 3), spacing: 18) {
            ForEach(0 ..< 9, id: \.self) { _ in
                RoundedRectangle(cornerRadius: 8).fill(Color.brhCard).frame(width: cell, height: square ? cell : cell * 1.5)
            }
        }
        .padding(.horizontal, margin)
        .accessibilityLabel("Loading")
    }
}
