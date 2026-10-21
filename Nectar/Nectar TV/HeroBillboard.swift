import NectarKit
import SwiftUI

/// Home's billboard, as the web's: a full-width backdrop, the logo or title, what it is, and Play or Resume.
/// It moves on every 8 s, and waits while the remote is moving around its buttons (focus starts on them,
/// so "never while focused" would mean never).
struct HeroBillboard: View {

    let slides: [HeroSlide]
    let session: NectarSession
    /// Home's focus scope: the billboard's main button is where focus starts.
    let focusScope: Namespace.ID
    let play: (HeroSlide) -> Void
    let open: (MediaCard) -> Void

    @State
    private var index = 0
    @FocusState
    private var focus: Button?
    @State
    private var lastMove = ContinuousClock.now

    private enum Button: Hashable { case main, details }

    private static let height: CGFloat = 640
    private static let every: Duration = .seconds(8)

    private var slide: HeroSlide? { slides.isEmpty ? nil : slides[index % slides.count] }

    var body: some View {
        if let slide {
            ZStack(alignment: .bottomLeading) {
                CachedImage(
                    url: session.resolve(slide.card.backdropPath ?? slide.card.posterPath, pixelWidth: 1920), maxPixelSize: 3840,
                    blurHash: slide.card.artworkBlurHash
                ) { image in
                    image.resizable().aspectRatio(contentMode: .fill)
                } placeholder: {
                    Rectangle().fill(.quaternary)
                }
                .frame(maxWidth: .infinity, maxHeight: Self.height)
                .clipped()
                .overlay(LinearGradient(colors: [.clear, .black.opacity(0.85)], startPoint: .center, endPoint: .bottom))
                .overlay(LinearGradient(colors: [.black.opacity(0.7), .clear], startPoint: .leading, endPoint: .center))
                .id(slide.id)
                .transition(.opacity)

                VStack(alignment: .leading, spacing: 16) {
                    title(slide.card)
                    if !facts(slide.card).isEmpty {
                        Text(facts(slide.card)).font(.callout).foregroundStyle(.secondary)
                    }
                    if let overview = slide.card.overview, !overview.isEmpty {
                        Text(overview).font(.callout).lineLimit(3).frame(maxWidth: 900, alignment: .leading)
                    }
                    HStack(spacing: 24) {
                        SwiftUI.Button(mainLabel(slide), systemImage: slide.card.itemType == "series" ? "list.bullet" : "play.fill") {
                            if slide.card.itemType == "series" { open(slide.card) } else { play(slide) }
                        }
                        .focused($focus, equals: .main)
                        .prefersDefaultFocus(true, in: focusScope)
                        SwiftUI.Button("Details", systemImage: "info.circle") { open(slide.card) }
                            .focused($focus, equals: .details)
                    }
                    if slides.count > 1 { dots }
                }
                .padding(60)
            }
            .frame(height: Self.height)
            .clipShape(RoundedRectangle(cornerRadius: 24))
            .task(id: slides.map(\.id)) { await rotate() }
            .onChange(of: focus) { lastMove = .now }
        }
    }

    /// The next slide every 8 s, once the remote has left the billboard's buttons alone for that long.
    private func rotate() async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(1))
            guard slides.count > 1, lastMove.duration(to: .now) >= Self.every else { continue }
            withAnimation(.easeInOut(duration: 0.8)) { index = (index + 1) % slides.count }
            lastMove = .now
        }
    }

    @ViewBuilder
    private func title(_ card: MediaCard) -> some View {
        if let logo = card.logoPath {
            CachedImage(url: session.resolve(logo, pixelWidth: 780), maxPixelSize: 780) { image in
                image.resizable().aspectRatio(contentMode: .fit)
            } placeholder: {
                Text(card.title ?? "").font(.largeTitle.bold())
            }
            .frame(maxWidth: 620, maxHeight: 180, alignment: .leading)
        } else {
            Text(card.title ?? "Untitled").font(.largeTitle.bold()).lineLimit(2)
        }
    }

    private var dots: some View {
        HStack(spacing: 10) {
            ForEach(slides.indices, id: \.self) { i in
                Circle().fill(i == index % slides.count ? .white : .white.opacity(0.35)).frame(width: 10, height: 10)
            }
        }
        .padding(.top, 8)
    }

    private func mainLabel(_ slide: HeroSlide) -> String {
        if slide.card.itemType == "series" { return "Episodes" }
        return slide.resumable ? "Resume" : "Play"
    }

    /// "2016 · 1h 56m · Drama, Science Fiction", or for an episode its series and number.
    private func facts(_ card: MediaCard) -> String {
        var parts: [String] = []
        if card.itemType == "episode", let series = card.seriesTitle {
            parts.append([series, card.seasonNumber.flatMap { s in card.episodeNumber.map { "S\(s) E\($0)" } }].compactMap(\.self).joined(separator: " · "))
        } else if let year = card.year {
            parts.append(String(year))
        }
        if let runtime = card.runtimeSeconds, runtime > 0, card.itemType != "series" { parts.append(ItemDetailView.duration(runtime)) }
        if let genres = card.genres, !genres.isEmpty { parts.append(genres.prefix(3).joined(separator: ", ")) }
        return parts.joined(separator: " · ")
    }
}
