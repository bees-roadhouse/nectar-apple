import NectarKit
import SwiftUI
import UIKit

@MainActor
final class PeopleController: UIHostingController<PeopleScreen>, UISearchResultsUpdating {
    private let model: PeopleBrowser
    init(model: PeopleBrowser, open: @escaping (Person) -> Void) {
        self.model = model
        super.init(rootView: PeopleScreen(model: model, open: open))
        let search = UISearchController(searchResultsController: nil)
        search.searchResultsUpdater = self
        search.obscuresBackgroundDuringPresentation = false
        search.searchBar.placeholder = "Search people"
        navigationItem.searchController = search
        navigationItem.hidesSearchBarWhenScrolling = false
        definesPresentationContext = true
        title = "People"
        rootView.clearSearch = { [weak self] in
            self?.navigationItem.searchController?.searchBar.text = ""
            self?.model.query = ""
        }
    }
    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not from a storyboard") }
    func updateSearchResults(for searchController: UISearchController) {
        let query = searchController.searchBar.text ?? ""
        if model.query != query { model.query = query }
    }

}

struct PeopleScreen: View {
    @Bindable var model: PeopleBrowser
    let open: (Person) -> Void
    var clearSearch: () -> Void = {}
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        List {
            if model.loaded && model.people.isEmpty {
                ContentUnavailableView {
                    Label(model.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "No people yet" : "No people found", systemImage: "person.2")
                } actions: {
                    if !model.query.isEmpty {
                        Button("Clear search", action: clearSearch).foregroundStyle(Color.brhGold)
                    }
                }
            }
            ForEach(model.people) { person in
                Button { open(person) } label: {
                    row(name: person.name, photo: person.photo, count: person.creditCount)
                }
                .buttonStyle(.plain)
                .task {
                    guard person.id == model.people.last?.id, !model.failed else { return }
                    await model.loadMore()
                }
            }
            if model.loading || !model.loaded && !model.failed {
                ForEach(0..<6) { _ in
                    row(name: "Person's name", photo: nil, count: 12)
                        .redacted(reason: .placeholder).accessibilityHidden(true)
                }
            }
            if model.failed {
                VStack(spacing: 12) {
                    Text("Couldn't load people").foregroundStyle(.secondary)
                    Button("Retry") {
                        Task {
                            if model.people.isEmpty { await model.search(debounce: false) }
                            else { await model.loadMore() }
                        }
                    }
                    .foregroundStyle(Color.brhGold)
                }
                .frame(maxWidth: .infinity)
            }
        }
        .listStyle(.plain).scrollContentBackground(.hidden).background(Color.brhNight)
        .task(id: model.query) { await model.start() }
        .refreshable { await model.search(debounce: false) }
    }

    private func row(name: String, photo: URL?, count: Int) -> some View {
        let layout = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 12)) : AnyLayout(HStackLayout(spacing: 12))
        return layout {
            PersonPortrait(url: photo, size: 56)
            VStack(alignment: .leading, spacing: 4) {
                Text(name).font(.headline).foregroundStyle(.primary).fixedSize(horizontal: false, vertical: true)
                // The directory count is global credits, not distinct or library-scoped titles.
                Text(count == 1 ? "1 credit" : "\(count) credits").font(.subheadline).foregroundStyle(.secondary)
            }
            if !typeSize.isAccessibilitySize {
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold)).foregroundStyle(.tertiary).accessibilityHidden(true)
            }
        }
        .frame(minHeight: 44).contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

struct PersonScreen: View {
    let id: String
    let name: String
    var photo: URL?
    let session: NectarSession
    let open: (MediaCard) -> Void
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var detail: PersonDetail?
    @State private var failed = false

    var body: some View {
        GeometryReader { proxy in
            let margin: CGFloat = proxy.size.width >= 428 ? 20 : 16
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    header
                    if let detail, detail.credits.isEmpty {
                        ContentUnavailableView("No titles in your libraries", systemImage: "film").frame(maxWidth: .infinity)
                    }
                    CatalogGrid(cards: detail?.credits.map(\.card) ?? [], roles: Dictionary((detail?.credits ?? []).compactMap { credit in credit.role.map { (credit.id, $0) } }, uniquingKeysWith: { first, _ in first }), session: session, width: max(1, proxy.size.width - margin * 2), loading: detail == nil && !failed, open: open)
                    if failed {
                        VStack(spacing: 12) {
                            Text("Couldn't load this person").foregroundStyle(.secondary)
                            Button("Retry") { Task { await load() } }.foregroundStyle(Color.brhGold)
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
                .padding(.horizontal, margin).padding(.vertical, 16).padding(.bottom, 32)
            }
            .refreshable { await load() }
        }
        .background(Color.brhNight).task { await load() }
    }

    private var header: some View {
        let layout = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 12)) : AnyLayout(HStackLayout(spacing: 16))
        return layout {
            PersonPortrait(url: detail?.person.photo ?? photo, size: 96)
            VStack(alignment: .leading, spacing: 12) {
                Text(detail?.person.name ?? name).font(.title2.bold()).fixedSize(horizontal: false, vertical: true)
                if let detail {
                    Text(detail.credits.count == 1 ? "1 title in your libraries" : "\(detail.credits.count) titles in your libraries")
                        .font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("Titles in your libraries").font(.subheadline).foregroundStyle(.secondary)
                        .redacted(reason: .placeholder).accessibilityHidden(true)
                }
            }
        }
    }

    private func load() async {
        do { detail = try await session.person(id); failed = false }
        catch { failed = true }
    }
}

private struct PersonPortrait: View {
    let url: URL?
    let size: CGFloat
    var body: some View {
        CachedImage(url: url, maxPixelSize: Int(size * 3)) { image in
            image.resizable().scaledToFill()
        } placeholder: {
            ZStack {
                Color.brhCard
                Image(systemName: "person.fill").font(.system(size: 24)).foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size).clipShape(Circle()).accessibilityHidden(true)
    }
}
