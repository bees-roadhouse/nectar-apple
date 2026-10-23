import AVKit
import NectarKit
import SwiftUI

/// Home, native (#158): the TV app's `HomeModel` laid out for the phone. The billboard, Continue Watching, what's
/// recommended, and the shelves, with #142's status marks on the cards. A card opens its title (web until the native
/// title page, slice 2); Play opens the native player.
struct HomeScreen: View {

    let model: HomeModel
    let open: (MediaCard) -> Void
    let openDiscover: (Recommendation) -> Void

    @Environment(\.horizontalSizeClass)
    private var width

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 28) {
                if !model.hero.isEmpty {
                    Billboard(slides: model.hero, session: model.session, play: { slide in Task { await model.play(slide) } }, open: open)
                }
                switch model.continueWatching {
                case .loading:
                    ProgressView().frame(maxWidth: .infinity).padding(.vertical, 40)
                case .failed:
                    Text("Can't reach nectar right now.").foregroundStyle(.secondary).padding(.horizontal)
                case let .loaded(cards) where !cards.isEmpty:
                    Shelf(title: "Continue watching") {
                        ForEach(cards) { card in
                            WideCard(card: card, session: model.session) { model.play(card) }
                        }
                    }
                case .loaded:
                    EmptyView()
                }
                if !model.forYou.isEmpty {
                    Shelf(title: "For you") {
                        ForEach(model.forYou) { recommendation in
                            Poster(title: recommendation.title, subtitle: recommendation.year.map(String.init),
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
                ForEach(model.shelves) { shelf in
                    Shelf(title: shelf.title) {
                        ForEach(shelf.cards) { card in
                            Poster(title: card.title ?? "Untitled", subtitle: card.year.map(String.init),
                                   url: model.session.resolve(card.posterPath, pixelWidth: Poster.width * 3),
                                   blurHash: card.posterBlurHash, status: CardStatus.of(card.pipeline, owned: true)) {
                                open(card)
                            }
                        }
                    }
                }
            }
            .padding(.bottom, 24)
        }
        .refreshable { await model.load() }
        .background(Color.brhNight)
        .task { if case .loading = model.continueWatching { await model.load() } }
        .fullScreenCover(item: Binding(get: { model.playing }, set: { if $0 == nil { model.finishedPlaying() } })) { player in
            PlayerScreen(model: player) { model.finishedPlaying() }
        }
    }
}

/// A titled row that scrolls sideways, snapping to its cards.
private struct Shelf<Cards: View>: View {
    let title: String
    @ViewBuilder
    let cards: () -> Cards

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.title3.bold()).padding(.horizontal)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 12) { cards() }
                    .scrollTargetLayout()
                    .padding(.horizontal)
            }
            .scrollTargetBehavior(.viewAligned)
        }
    }
}

/// The billboard: what's being watched, then what's new, a page each.
private struct Billboard: View {
    let slides: [HeroSlide]
    let session: NectarSession
    let play: (HeroSlide) -> Void
    let open: (MediaCard) -> Void

    var body: some View {
        TabView {
            ForEach(slides) { slide in
                // The page's own size holds the picture: filled and cropped to it, never wider than the screen.
                Color.brhCard
                    .overlay {
                        CachedImage(url: session.resolve(slide.card.backdropPath, pixelWidth: 1200), maxPixelSize: 1200,
                                    blurHash: slide.card.backdropBlurHash) { image in
                            image.resizable().scaledToFill()
                        } placeholder: { Color.brhCard }
                    }
                    .clipped()
                    .overlay {
                        LinearGradient(colors: [.clear, Color.brhNight.opacity(0.95)], startPoint: .center, endPoint: .bottom)
                    }
                    .overlay(alignment: .bottomLeading) {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(slide.card.title ?? "").font(.title.bold()).lineLimit(2)
                        HStack(spacing: 12) {
                            Button(slide.resumable ? "Resume" : "Play", systemImage: "play.fill") { play(slide) }
                                .buttonStyle(.borderedProminent)
                            Button("Details", systemImage: "info.circle") { open(slide.card) }
                                .buttonStyle(.bordered)
                        }
                        .controlSize(.large)
                    }
                    .padding()
                    .padding(.bottom, 24)
                    }
            }
        }
        .tabViewStyle(.page)
        .frame(height: 440)
    }
}

/// A Continue Watching card: the backdrop, how far in, and the title.
private struct WideCard: View {
    let card: MediaCard
    let session: NectarSession
    let play: () -> Void

    var body: some View {
        Button(action: play) {
            VStack(alignment: .leading, spacing: 6) {
                CachedImage(url: session.resolve(card.backdropPath ?? card.posterPath, pixelWidth: 800), maxPixelSize: 800,
                            blurHash: card.backdropBlurHash) { image in
                    image.resizable().scaledToFill()
                } placeholder: { Color.brhCard }
                .frame(width: 260, height: 146)
                .clipShape(.rect(cornerRadius: 12))
                .overlay(alignment: .bottom) {
                    if let progress = card.progress {
                        ProgressView(value: progress).tint(.brhGold).padding(10)
                    }
                }
                .cardStatus(CardStatus.of(card.pipeline, owned: true))
                Text(card.title ?? "Untitled").font(.subheadline).lineLimit(1)
            }
            .frame(width: 260, alignment: .leading)
        }
        .buttonStyle(Pressed())
    }
}

/// A poster with its title and year under it.
private struct Poster: View {
    static let width: Double = 120

    let title: String
    let subtitle: String?
    let url: URL?
    let blurHash: String?
    let status: CardStatus?
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            VStack(alignment: .leading, spacing: 4) {
                CachedImage(url: url, maxPixelSize: Int(Self.width * 3), blurHash: blurHash) { image in
                    image.resizable().scaledToFill()
                } placeholder: { Color.brhCard }
                .frame(width: Self.width, height: Self.width * 1.5)
                .clipShape(.rect(cornerRadius: 12))
                .cardStatus(status)
                Text(title).font(.caption).lineLimit(1)
                Text(subtitle ?? " ").font(.caption2).foregroundStyle(.secondary)
            }
            .frame(width: Self.width, alignment: .leading)
        }
        .buttonStyle(Pressed())
    }
}

/// The touch press: pressed into the page at 0.97 on the snappy spring (Capping's touch spec), never a hover lift.
private struct Pressed: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.snappy(duration: 0.2), value: configuration.isPressed)
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
