import AVKit
import NectarKit
import SwiftUI

/// Home, native (#158), to Capping's feel for the phone (#158's spec): the TV app's `HomeModel` in the web's order, so
/// the two can be judged side by side. The hero's inset cards, then Continue watching, New in each library, the genre
/// shelves and For You. A card opens its title (web until the native title page); Play opens the native player.
struct HomeScreen: View {

    let model: HomeModel
    let open: (MediaCard) -> Void
    let openDiscover: (Recommendation) -> Void
    /// A shelf's See all: its library or genre, by the shelf's id ("recent-<library>" or "genre-<name>").
    let seeAll: (HomeModel.Shelf) -> Void

    @State
    private var adding: PlaylistAdding.Target?

    var body: some View {
        GeometryReader { proxy in
            // The system's layout margins as the gutter: 16 on a 390 phone, 20 on a Pro Max.
            let margin: CGFloat = proxy.size.width >= 428 ? 20 : 16
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    switch model.continueWatching {
                    case .loading:
                        Placeholder(width: proxy.size.width, margin: margin)
                    case .failed:
                        Text("Can't reach nectar right now.").foregroundStyle(.secondary).padding(.horizontal, margin)
                    case let .loaded(watching):
                        if watching.isEmpty, model.shelves.isEmpty, model.hero.isEmpty {
                            Nothing().frame(minHeight: proxy.size.height * 0.7)
                        } else {
                            content(watching, width: proxy.size.width, margin: margin)
                        }
                    }
                }
                .padding(.bottom, 24)
            }
            // The last shelf clears the floating tab bar.
            .contentMargins(.bottom, 32, for: .scrollContent)
            .refreshable { await model.load() }
        }
        .background(Color.brhNight)
        .task { if case .loading = model.continueWatching { await model.load() } }
        .fullScreenCover(item: Binding(get: { model.playing }, set: { if $0 == nil { model.finishedPlaying() } })) { player in
            PlayerScreen(model: player) { model.finishedPlaying() }
        }
        .sheet(item: $adding) { target in
            AddToPlaylist(target: target, model: model.playlistAdding)
                .presentationDetents([.medium, .large])
        }
    }

    @ViewBuilder
    private func content(_ watching: [MediaCard], width: CGFloat, margin: CGFloat) -> some View {
        if !model.hero.isEmpty {
            Hero(slides: model.hero, session: model.session, width: width, margin: margin,
                 play: { slide in played(); Task { await model.play(slide) } }, open: open)
                .padding(.bottom, 8)
        }
        if !watching.isEmpty {
            Shelf(title: "Continue watching", margin: margin) {
                ForEach(watching) { card in
                    WideCard(card: card, session: model.session) { model.play(card) }
                        .contextMenu { actions(card) } preview: { Preview(card: card, session: model.session) }
                }
            }
        }
        ForEach(model.shelves) { shelf in
            Shelf(title: shelf.title, margin: margin, seeAll: { seeAll(shelf) }) {
                ForEach(shelf.cards) { card in
                    Poster(title: card.title ?? "Untitled", year: card.year, reason: nil,
                           url: model.session.resolve(card.posterPath, pixelWidth: Poster.width * 3),
                           blurHash: card.posterBlurHash, status: CardStatus.of(card.pipeline, owned: true)) { open(card) }
                        .contextMenu { actions(card) } preview: { Preview(card: card, session: model.session) }
                }
            }
        }
        if !model.forYou.isEmpty {
            Shelf(title: "For You", margin: margin) {
                ForEach(model.forYou) { recommendation in
                    Poster(title: recommendation.title, year: recommendation.year, reason: recommendation.reason ?? " ",
                           url: model.session.resolve(recommendation.posterPath, pixelWidth: Poster.width * 3),
                           blurHash: recommendation.posterBlurHash, status: nil) {
                        if let id = recommendation.mediaItemID, recommendation.inLibrary {
                            open(MediaCard(id: id, title: recommendation.title))
                        } else {
                            openDiscover(recommendation)
                        }
                    }
                }
            }
        }
    }

    /// The long-press menu: the system's own, in place of the web's sheet (Capping, #158). nectar has no "mark
    /// watched" yet, on the web either, so it isn't offered.
    @ViewBuilder
    private func actions(_ card: MediaCard) -> some View {
        Button("Play", systemImage: "play.fill") { played(); model.play(card) }
        Button("Add to playlist", systemImage: "text.badge.plus") { adding = .owned(id: card.id, title: card.title ?? "") }
        Button("Details", systemImage: "info.circle") { open(card) }
    }

    /// A medium tap on Play, from the hero or the menu; never on scroll, paging or press.
    private func played() {
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }
}

/// The kit's snappy spring (response 0.3, damping 0.86), until feel.json's Swift output carries it (hive-mind #366).
private let snappy = Animation.spring(response: 0.3, dampingFraction: 0.86)

/// A shelf's header row (44 pt: the title, and See all where it goes somewhere), then its cards sideways, snapping.
private struct Shelf<Cards: View>: View {
    let title: String
    let margin: CGFloat
    var seeAll: (() -> Void)?
    @ViewBuilder
    let cards: () -> Cards

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(title).font(.title3.weight(.semibold)).lineLimit(1)
                Spacer()
                if let seeAll {
                    Button(action: seeAll) {
                        HStack(spacing: 2) {
                            Text("See all")
                            Image(systemName: "chevron.forward").imageScale(.small)
                        }
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .frame(minHeight: 44)
                    }
                }
            }
            .frame(minHeight: 44)
            .padding(.horizontal, margin)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 12) { cards() }
                    .scrollTargetLayout()
            }
            .contentMargins(.horizontal, margin, for: .scrollContent)
            .scrollTargetBehavior(.viewAligned)
        }
    }
}

/// The hero: inset cards at 4:5, a page at a time, the dots under; it never moves on its own.
private struct Hero: View {
    let slides: [HeroSlide]
    let session: NectarSession
    let width: CGFloat
    let margin: CGFloat
    let play: (HeroSlide) -> Void
    let open: (MediaCard) -> Void

    @State
    private var current: HeroSlide.ID?

    private var cardWidth: CGFloat { width - margin * 2 }

    var body: some View {
        VStack(spacing: 12) {
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: margin) {
                    ForEach(slides) { slide in
                        card(slide).frame(width: cardWidth, height: cardWidth * 1.25).id(slide.id)
                    }
                }
                .scrollTargetLayout()
            }
            .contentMargins(.horizontal, margin, for: .scrollContent)
            .scrollTargetBehavior(.viewAligned)
            .scrollPosition(id: $current)
            HStack(spacing: 8) {
                ForEach(slides) { slide in
                    Circle()
                        .fill(slide.id == (current ?? slides.first?.id) ? Color.brhGold : Color.secondary.opacity(0.4))
                        .frame(width: 6, height: 6)
                }
            }
            .frame(maxWidth: .infinity)
            .accessibilityHidden(true)
        }
    }

    private func card(_ slide: HeroSlide) -> some View {
        Color.brhCard
            .overlay {
                CachedImage(url: session.resolve(slide.card.backdropPath ?? slide.card.posterPath, pixelWidth: 1200), maxPixelSize: 1200,
                            blurHash: slide.card.backdropBlurHash) { image in
                    image.resizable().scaledToFill()
                } placeholder: { Color.brhCard }
            }
            .clipped()
            .overlay {
                LinearGradient(stops: [.init(color: .clear, location: 0.45), .init(color: .brhNight, location: 1)], startPoint: .top, endPoint: .bottom)
            }
            .overlay(alignment: .bottomLeading) {
                VStack(alignment: .leading, spacing: 8) {
                    if let logo = session.resolve(slide.card.logoPath, pixelWidth: 800) {
                        CachedImage(url: logo, maxPixelSize: 800) { image in
                            image.resizable().scaledToFit()
                        } placeholder: {
                            Text(slide.card.title ?? "").font(.system(size: 28, weight: .bold)).lineLimit(2)
                        }
                        .frame(maxWidth: cardWidth * 0.7, maxHeight: 72, alignment: .leading)
                    } else {
                        Text(slide.card.title ?? "").font(.system(size: 28, weight: .bold)).lineLimit(2)
                    }
                    Text(meta(slide.card)).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                    HStack(spacing: 12) {
                        Button { play(slide) } label: {
                            Label(slide.resumable ? "Resume" : "Play", systemImage: "play.fill")
                        }
                        .buttonStyle(CapsuleStyle(primary: true))
                        Button { open(slide.card) } label: { Text("Details") }
                            .buttonStyle(CapsuleStyle(primary: false))
                    }
                    .padding(.top, 4)
                }
                .padding(16)
            }
            .clipShape(.rect(cornerRadius: 12))
    }

    /// rating · year · runtime · genre, as the web's hero has them.
    private func meta(_ card: MediaCard) -> String {
        [card.communityRating?.percent.map { "\($0)%" }, card.year.map(String.init), card.runtimeSeconds.map(Durations.duration), card.genres?.first]
            .compactMap(\.self).joined(separator: " · ")
    }
}

/// Page 2451's capsules at 44 pt: gold with gold-ink lettering, or the card with a dim line.
private struct CapsuleStyle: ButtonStyle {
    let primary: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .foregroundStyle(primary ? Color.brhGoldInk : .primary)
            .padding(.horizontal, 20)
            .frame(minHeight: 44)
            .background(primary ? Color.brhGold : Color.brhCard.opacity(0.85), in: .capsule)
            .overlay { if !primary { Capsule().stroke(Color.brhLineDim) } }
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(snappy, value: configuration.isPressed)
    }
}

/// A Continue watching card: 16:9 at 240, the time left top-left, the 2 pt gold hairline along the foot.
private struct WideCard: View {
    static let width: CGFloat = 240

    let card: MediaCard
    let session: NectarSession
    let play: () -> Void

    var body: some View {
        Button(action: play) {
            VStack(alignment: .leading, spacing: 6) {
                CachedImage(url: session.resolve(card.backdropPath ?? card.posterPath, pixelWidth: 720), maxPixelSize: 720,
                            blurHash: card.backdropBlurHash) { image in
                    image.resizable().scaledToFill()
                } placeholder: { Color.brhCard }
                .frame(width: Self.width, height: Self.width * 9 / 16)
                .clipped()
                .overlay(alignment: .bottomLeading) {
                    if let progress = card.progress {
                        GeometryReader { box in
                            Rectangle().fill(Color.brhGold).frame(width: box.size.width * progress, height: 2)
                                .frame(maxHeight: .infinity, alignment: .bottom)
                        }
                    }
                }
                // #142's pill top-right; the time left bottom-right, 8 pt above the hairline it describes (Capping, #159).
                .overlay(alignment: .topTrailing) {
                    if case .upgrading = CardStatus.of(card.pipeline, owned: true) { UpgradingPill().padding(8) }
                }
                .overlay(alignment: .bottomTrailing) {
                    if let left = timeLeft {
                        Text(left).font(.caption.weight(.semibold))
                            .padding(.horizontal, 6).padding(.vertical, 3)
                            .background(.ultraThinMaterial, in: .capsule)
                            .padding(.trailing, 8).padding(.bottom, 10)
                    }
                }
                .overlay(alignment: .bottom) {
                    if case let .arriving(arrival) = CardStatus.of(card.pipeline, owned: true) { ArrivalFoot(arrival: arrival).padding(8) }
                }
                .clipShape(.rect(cornerRadius: 12))
                Text(card.title ?? "Untitled").font(.subheadline.weight(.medium)).lineLimit(1)
            }
            .frame(width: Self.width, alignment: .leading)
        }
        .buttonStyle(Pressed())
    }

    private var timeLeft: String? {
        guard let runtime = card.runtimeSeconds, let at = card.progressSeconds, runtime > at else { return nil }
        return "\(Durations.duration(runtime - at)) left"
    }
}

/// A poster, 2:3 at 120 with radius 8, its title and year under it (and For You's reason, two lines kept).
private struct Poster: View {
    static let width: Double = 120

    let title: String
    let year: Int?
    let reason: String?
    let url: URL?
    let blurHash: String?
    let status: CardStatus?
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            VStack(alignment: .leading, spacing: 3) {
                CachedImage(url: url, maxPixelSize: Int(Self.width * 3), blurHash: blurHash) { image in
                    image.resizable().scaledToFill()
                } placeholder: { Color.brhCard }
                .frame(width: Self.width, height: Self.width * 1.5)
                .cardStatus(status)
                .clipShape(.rect(cornerRadius: 8))
                .shadow(color: .black.opacity(0.3), radius: 6, y: 3)
                Text(title).font(.subheadline.weight(.medium)).lineLimit(1).padding(.top, 3)
                Text(year.map(String.init) ?? " ").font(.footnote).foregroundStyle(.secondary)
                if let reason {
                    Text(reason).font(.caption).foregroundStyle(.secondary).lineLimit(2, reservesSpace: true)
                }
            }
            .frame(width: Self.width, alignment: .leading)
        }
        .buttonStyle(Pressed())
    }
}

/// The long-press preview: the poster at full size, with the card's status words.
private struct Preview: View {
    let card: MediaCard
    let session: NectarSession

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            CachedImage(url: session.resolve(card.posterPath, pixelWidth: 900), maxPixelSize: 900, blurHash: card.posterBlurHash) { image in
                image.resizable().scaledToFill()
            } placeholder: { Color.brhCard }
            .frame(width: 280, height: 420)
            .clipped()
            VStack(alignment: .leading, spacing: 2) {
                Text(card.title ?? "Untitled").font(.headline)
                if let words = CardStatus.of(card.pipeline, owned: true)?.words {
                    Text(words).font(.footnote).foregroundStyle(.secondary)
                }
            }
            .padding([.horizontal, .bottom], 12)
        }
        .frame(width: 280)
        .background(Color.brhCard)
    }
}

/// The touch press: into the page at 0.97 on the kit's spring; a touch that becomes a scroll fires nothing.
private struct Pressed: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(snappy, value: configuration.isPressed)
    }
}

/// Home arriving whole: the final geometry, redacted, never a spinner or "Loading…".
private struct Placeholder: View {
    let width: CGFloat
    let margin: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            RoundedRectangle(cornerRadius: 12).fill(Color.brhCard)
                .frame(width: width - margin * 2, height: (width - margin * 2) * 1.25)
                .padding(.horizontal, margin)
                .padding(.bottom, 8 + 18)
            ForEach(0 ..< 2, id: \.self) { _ in
                VStack(alignment: .leading, spacing: 12) {
                    RoundedRectangle(cornerRadius: 4).fill(Color.brhCard).frame(width: width * 0.36, height: 20)
                        .frame(minHeight: 44)
                    HStack(spacing: 12) {
                        ForEach(0 ..< 4, id: \.self) { _ in
                            RoundedRectangle(cornerRadius: 8).fill(Color.brhCard).frame(width: 120, height: 180)
                        }
                    }
                }
                .padding(.horizontal, margin)
            }
        }
        .accessibilityLabel("Loading")
    }
}

/// An empty Home: the one-thing pattern.
private struct Nothing: View {
    var body: some View {
        VStack(spacing: 16) {
            Image("Lockup").resizable().scaledToFit().frame(height: 44)
            Text("Nothing here yet").font(.title3.weight(.semibold))
            Text("Ask whoever runs your nectar to add a library.").font(.subheadline).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}

/// Add to playlist, as a sheet: the playlists, or a new one by name.
private struct AddToPlaylist: View {
    let target: PlaylistAdding.Target
    let model: PlaylistAdding

    @Environment(\.dismiss)
    private var dismiss
    @State
    private var playlists: [Playlist]?
    @State
    private var newName = ""

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack {
                        TextField("New playlist", text: $newName).submitLabel(.done).onSubmit(create)
                        Button("Add", action: create).disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
                Section {
                    if let playlists {
                        ForEach(playlists) { playlist in
                            Button(playlist.name) {
                                Task {
                                    await model.add(target, to: playlist)
                                    dismiss()
                                }
                            }
                        }
                    } else {
                        ProgressView()
                    }
                }
                if let failure = model.failure {
                    Text(failure).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Add to playlist")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            .task { playlists = await model.playlists(for: target) }
        }
    }

    private func create() {
        let name = newName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        Task {
            await model.add(target, toNewPlaylistNamed: name)
            dismiss()
        }
    }
}

/// The player, minimal until #157: the system's own controls over what nectar decided, PiP and AirPlay included.
struct PlayerScreen: View {
    let model: PlayerModel
    let done: () -> Void

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            switch model.phase {
            case .deciding:
                ProgressView().tint(.white)
            case let .playing(player, _):
                SystemPlayer(player: player).ignoresSafeArea()
            case let .failed(failure):
                VStack(spacing: 16) {
                    Text(PlaybackFailure.headline).font(.headline)
                    Text(failure.why ?? "").foregroundStyle(.secondary).multilineTextAlignment(.center)
                    Button("Close") { done() }.buttonStyle(.bordered)
                }
                .padding()
            }
        }
        .task { await model.start() }
        .onDisappear { model.stop() }
    }
}

private struct SystemPlayer: UIViewControllerRepresentable {
    let player: AVPlayer

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        controller.player = player
        controller.allowsPictureInPicturePlayback = true
        controller.canStartPictureInPictureAutomaticallyFromInline = true
        player.play()
        return controller
    }

    func updateUIViewController(_ controller: AVPlayerViewController, context: Context) {
        if controller.player !== player { controller.player = player }
    }
}
