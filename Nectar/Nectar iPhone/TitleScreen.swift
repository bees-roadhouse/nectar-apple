import NectarKit
import SwiftUI

/// A title, native (#158), to Capping's feel for the phone (`native-title.md`): the TV app's `ItemDetailModel` in the
/// web's item page order. The hero under a transparent bar, the poster over its edge, the in-library line, one gold
/// capsule, the overview, cast, episodes for a series, details, and more like this.
struct TitleScreen: View {

    let model: ItemDetailModel
    let open: (MediaCard) -> Void
    let openPerson: (ItemDetail.CastMember) -> Void
    let back: () -> Void

    @State
    private var adding: PlaylistAdding.Target?
    @State
    private var overviewOpen = false

    var body: some View {
        GeometryReader { proxy in
            let margin: CGFloat = proxy.size.width >= 428 ? 20 : 16
            ScrollView {
                switch model.detail {
                case .loading:
                    Arriving(width: proxy.size.width, margin: margin)
                case .failed:
                    Missing(back: back).frame(minHeight: proxy.size.height * 0.8)
                case let .loaded(detail):
                    page(detail, width: proxy.size.width, margin: margin)
                }
            }
            .contentMargins(.bottom, 32, for: .scrollContent)
            .ignoresSafeArea(edges: .top)
        }
        .background(Color.brhNight)
        .task { if case .loading = model.detail { await model.load() } }
        .fullScreenCover(item: Binding(get: { model.playing }, set: { if $0 == nil { model.finishedPlaying() } })) { player in
            PlayerScreen(model: player) { model.finishedPlaying() }
        }
        .fullScreenCover(item: Binding(get: { model.queue }, set: { if $0 == nil { model.finishedQueue() } })) { queue in
            QueueScreen(queue: queue, session: model.session) { model.finishedQueue() }
        }
        .fullScreenCover(item: Binding(get: { model.trailer }, set: { _ in model.trailer = nil })) { trailer in
            SystemPlayer(player: trailer.player).ignoresSafeArea()
        }
        .sheet(item: $adding) { target in
            AddToPlaylist(target: target, model: model.playlistAdding).presentationDetents([.medium, .large])
        }
    }

    @ViewBuilder
    private func page(_ detail: ItemDetail, width: CGFloat, margin: CGFloat) -> some View {
        LazyVStack(alignment: .leading, spacing: 24, pinnedViews: [.sectionHeaders]) {
            VStack(alignment: .leading, spacing: 16) {
                hero(detail, width: width, margin: margin)
                status(detail).padding(.horizontal, margin)
                actions(detail).padding(.horizontal, margin)
            }
            if let overview = detail.overview, !overview.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text(overview).font(.body).lineLimit(overviewOpen ? nil : 3)
                    if !overviewOpen {
                        Button("more") { withAnimation(snappy) { overviewOpen = true } }
                            .font(.subheadline.weight(.semibold)).frame(minHeight: 44)
                    }
                }
                .padding(.horizontal, margin)
            }
            if !detail.cast.isEmpty {
                Shelf(title: "Cast", margin: margin) {
                    ForEach(detail.cast) { member in
                        Button { openPerson(member) } label: {
                            VStack(spacing: 6) {
                                CachedImage(url: member.photo, maxPixelSize: 216) { image in
                                    image.resizable().scaledToFill()
                                } placeholder: {
                                    Color.brhCard.overlay { Image(systemName: "person.fill").foregroundStyle(.secondary) }
                                }
                                .frame(width: 72, height: 72)
                                .clipShape(.circle)
                                Text(member.name).font(.footnote).lineLimit(2).multilineTextAlignment(.center)
                            }
                            .frame(width: 84)
                        }
                        .buttonStyle(Pressed())
                    }
                }
            }
            if detail.itemType == "series", !model.seasons.isEmpty {
                Section {
                    episodes(detail, margin: margin)
                } header: {
                    seasonChips(margin: margin)
                }
            }
            facts(detail).padding(.horizontal, margin)
            if !model.similar.isEmpty {
                Shelf(title: "More like this", margin: margin) {
                    ForEach(model.similar) { card in
                        Poster(title: card.title ?? "Untitled", year: card.year, reason: nil,
                               url: model.session.resolve(card.posterPath, pixelWidth: Poster.width * 3),
                               blurHash: card.posterBlurHash, status: CardStatus.of(card.pipeline, owned: true)) { open(card) }
                    }
                }
            }
        }
    }

    // MARK: - The hero

    private func hero(_ detail: ItemDetail, width: CGFloat, margin: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            CachedImage(url: model.session.resolve(detail.backdropPath, pixelWidth: 1600), maxPixelSize: 1600, blurHash: detail.artworkBlurHash) { image in
                image.resizable().scaledToFill()
            } placeholder: { Color.brhCard }
            .frame(width: width, height: width * 9 / 16)
            .clipped()
            .overlay {
                LinearGradient(stops: [.init(color: .clear, location: 0.4), .init(color: .brhNight, location: 1)], startPoint: .top, endPoint: .bottom)
            }
            HStack(alignment: .bottom, spacing: 14) {
                CachedImage(url: model.session.resolve(detail.posterPath, pixelWidth: 360), maxPixelSize: 360) { image in
                    image.resizable().scaledToFill()
                } placeholder: { Color.brhCard }
                .frame(width: 120, height: 180)
                .clipShape(.rect(cornerRadius: 8))
                .shadow(color: .black.opacity(0.35), radius: 8, y: 4)
                .contextMenu {
                    Button("Play", systemImage: "play.fill") { play(detail) }
                    Button("Add to playlist", systemImage: "text.badge.plus") { adding = .owned(id: detail.id, title: detail.title) }
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text(detail.title).font(.system(size: 28, weight: .bold)).lineLimit(3).minimumScaleFactor(0.8)
                    Text(meta(detail)).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
                    let marks = quality(detail)
                    if !marks.isEmpty {
                        HStack(spacing: 6) {
                            ForEach(marks, id: \.self) { mark in
                                Text(mark).font(.caption.weight(.semibold))
                                    .padding(.horizontal, 6).padding(.vertical, 2)
                                    .background(Color.brhCard, in: .rect(cornerRadius: 4))
                                    .overlay { RoundedRectangle(cornerRadius: 4).stroke(Color.brhLineDim) }
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, margin)
            .padding(.top, -64)
        }
    }

    /// rating · year · runtime · genre, as the web's item page has them.
    private func meta(_ detail: ItemDetail) -> String {
        let rating = detail.communityRating.flatMap { $0 > 0 ? "\(Int(($0 * 10).rounded()))%" : nil }
        let length = detail.itemType == "series" ? detail.seasonCount.map { "\($0) season\($0 == 1 ? "" : "s")" } : detail.runtimeSeconds.map(Durations.duration)
        return [rating, detail.year.map(String.init), length, detail.genres.first].compactMap(\.self).joined(separator: " · ")
    }

    /// 4K, HDR (or Dolby Vision), Atmos: what the file is, from nectar's probe.
    private func quality(_ detail: ItemDetail) -> [String] {
        var marks: [String] = []
        if let resolution = detail.source.resolution?.lowercased(), resolution.contains("2160") || resolution.contains("4k") { marks.append("4K") }
        if let hdr = detail.source.hdr, !hdr.isEmpty { marks.append(hdr.lowercased().contains("dolby") || hdr.lowercased().hasPrefix("dv") ? "Dolby Vision" : "HDR") }
        if detail.source.audioTracks.contains(where: { ($0.title ?? "").localizedCaseInsensitiveContains("atmos") }) { marks.append("Atmos") }
        return marks
    }

    // MARK: - Where it stands, and what to do

    /// #789's line, 8 pt under the meta: the pipeline's line while something moves, or the at-rest words. A slot of its
    /// own, so the capsule under it doesn't move when the words arrive.
    @ViewBuilder
    private func status(_ detail: ItemDetail) -> some View {
        Group {
            if let status = CardStatus.of(detail.pipeline, owned: true) {
                DetailStatus(status: status)
            } else if let following = CardStatus.following(detail.pipeline, isSeries: detail.itemType == "series") {
                Text(following).font(.subheadline).foregroundStyle(.secondary)
            }
        }
        .frame(minHeight: 20, alignment: .leading)
    }

    private func actions(_ detail: ItemDetail) -> some View {
        VStack(spacing: 14) {
            Button { play(detail) } label: {
                Label(verb(detail), systemImage: "play.fill").frame(maxWidth: .infinity)
            }
            .buttonStyle(Wide())
            HStack(spacing: 28) {
                Round(title: "Playlist", symbol: "text.badge.plus") { adding = .owned(id: detail.id, title: detail.title) }
                if detail.trailerPath != nil {
                    Round(title: "Trailer", symbol: "film") { Task { await model.playTrailer(detail) } }
                }
                ShareLink(item: PhoneModel.server.appending(path: "item/\(detail.id)")) {
                    RoundLabel(title: "Share", symbol: "square.and.arrow.up")
                }
                .buttonStyle(Pressed())
                Spacer(minLength: 0)
            }
        }
    }

    /// Play, or Resume with the time left; a series plays what's next.
    private func verb(_ detail: ItemDetail) -> String {
        if detail.itemType == "series", let next = Season.nextUp(in: model.seasons)?.episode {
            return next.isInProgress ? "Resume \(next.code ?? "")" : "Play \(next.code ?? "")"
        }
        guard let at = detail.resumeSeconds, at > 0 else { return "Play" }
        guard let runtime = detail.runtimeSeconds, runtime > at else { return "Resume" }
        return "Resume · \(Durations.duration(runtime - at)) left"
    }

    private func play(_ detail: ItemDetail) {
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        if detail.itemType == "series", let next = Season.nextUp(in: model.seasons)?.episode {
            model.play(next, of: detail)
        } else {
            model.play(detail, from: detail.resumeSeconds)
        }
    }

    // MARK: - Episodes

    private func seasonChips(margin: CGFloat) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(model.seasons) { season in
                    let current = season.id == model.selectedSeason
                    Button(season.title) { withAnimation(snappy) { model.selectedSeason = season.id } }
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(current ? Color.brhGoldInk : .primary)
                        .padding(.horizontal, 14)
                        .frame(minHeight: 36)
                        .background(current ? Color.brhGold : Color.brhCard, in: .capsule)
                        .overlay { if !current { Capsule().stroke(Color.brhLineDim) } }
                        .frame(minHeight: 44)
                }
            }
        }
        .contentMargins(.horizontal, margin, for: .scrollContent)
        .padding(.vertical, 4)
        .background(Color.brhNight)
    }

    @ViewBuilder
    private func episodes(_ detail: ItemDetail, margin: CGFloat) -> some View {
        let season = model.seasons.first { $0.id == model.selectedSeason } ?? model.seasons.first
        VStack(spacing: 12) {
            ForEach(season?.episodes ?? []) { episode in
                Button { model.play(episode, of: detail) } label: {
                    HStack(spacing: 12) {
                        CachedImage(url: model.session.resolve(episode.thumbPath, pixelWidth: 360), maxPixelSize: 360, blurHash: episode.thumbBlurHash) { image in
                            image.resizable().scaledToFill()
                        } placeholder: { Color.brhCard }
                        .frame(width: 120, height: 68)
                        .clipShape(.rect(cornerRadius: 8))
                        .overlay(alignment: .bottomLeading) {
                            if episode.isInProgress, let runtime = episode.runtimeSeconds, runtime > 0 {
                                GeometryReader { box in
                                    Rectangle().fill(Color.brhGold).frame(width: box.size.width * min(episode.progressSeconds / runtime, 1), height: 2)
                                        .frame(maxHeight: .infinity, alignment: .bottom)
                                }
                                .clipShape(.rect(cornerRadius: 8))
                            }
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            Text([episode.number.map { "\($0)." }, episode.title].compactMap(\.self).joined(separator: " "))
                                .font(.subheadline.weight(.medium)).lineLimit(2).multilineTextAlignment(.leading)
                            if let runtime = episode.runtimeSeconds {
                                Text(Durations.duration(runtime)).font(.footnote).foregroundStyle(.secondary)
                            }
                        }
                        Spacer(minLength: 0)
                        if episode.watched {
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(.secondary).accessibilityLabel("Watched")
                        }
                    }
                    .frame(minHeight: 44)
                    .contentShape(.rect)
                }
                .buttonStyle(Pressed())
            }
        }
        .padding(.horizontal, margin)
    }

    // MARK: - Details

    private func facts(_ detail: ItemDetail) -> some View {
        let rows: [(String, String?)] = [
            ("Director", detail.directors.isEmpty ? nil : detail.directors.joined(separator: ", ")),
            ("Rated", detail.contentRating),
            ("Video", [detail.source.resolution, detail.source.hdr, detail.source.videoCodec?.uppercased()].compactMap(\.self).joined(separator: " · ").nilIfEmpty),
            ("Audio", detail.source.audioTracks.first.map { [$0.codec?.uppercased(), $0.channelLayout, $0.language].compactMap(\.self).joined(separator: " · ") }?.nilIfEmpty),
            ("File", [detail.source.container?.uppercased(), detail.source.sizeBytes.map { String(format: "%.1f GB", $0 / 1_073_741_824) }].compactMap(\.self).joined(separator: " · ").nilIfEmpty),
        ]
        return VStack(alignment: .leading, spacing: 10) {
            Text("Details").font(.title3.weight(.semibold)).frame(minHeight: 44)
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 10) {
                ForEach(rows.filter { $0.1 != nil }, id: \.0) { label, value in
                    GridRow {
                        Text(label).foregroundStyle(.secondary)
                        Text(value ?? "")
                    }
                    .font(.subheadline)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.brhCard, in: .rect(cornerRadius: 12))
        }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

/// The one gold capsule, full width at 48 pt.
private struct Wide: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .foregroundStyle(Color.brhGoldInk)
            .frame(minHeight: 48)
            .background(Color.brhGold, in: .capsule)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(snappy, value: configuration.isPressed)
    }
}

/// A 44 pt round secondary button with its label under it.
private struct Round: View {
    let title: String
    let symbol: String
    let action: () -> Void

    var body: some View {
        Button(action: action) { RoundLabel(title: title, symbol: symbol) }.buttonStyle(Pressed())
    }
}

private struct RoundLabel: View {
    let title: String
    let symbol: String

    var body: some View {
        VStack(spacing: 4) {
            Image(systemName: symbol)
                .font(.body.weight(.semibold))
                .frame(width: 44, height: 44)
                .background(Color.brhCard, in: .circle)
                .overlay { Circle().stroke(Color.brhLineDim) }
            Text(title).font(.caption).foregroundStyle(.secondary)
        }
        .foregroundStyle(.primary)
    }
}

/// The page arriving whole: the hero, the poster, the title block and the capsule at their final geometry.
private struct Arriving: View {
    let width: CGFloat
    let margin: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Color.brhCard.frame(width: width, height: width * 9 / 16)
            HStack(alignment: .bottom, spacing: 14) {
                RoundedRectangle(cornerRadius: 8).fill(Color.brhCard.opacity(0.8)).frame(width: 120, height: 180)
                VStack(alignment: .leading, spacing: 8) {
                    RoundedRectangle(cornerRadius: 4).fill(Color.brhCard).frame(width: 180, height: 28)
                    RoundedRectangle(cornerRadius: 4).fill(Color.brhCard).frame(width: 140, height: 14)
                }
            }
            .padding(.horizontal, margin)
            .padding(.top, -64 - 16)
            Color.clear.frame(height: 20)
            Capsule().fill(Color.brhCard).frame(height: 48).padding(.horizontal, margin)
        }
        .accessibilityLabel("Loading")
    }
}

/// A title nectar couldn't give us: one sentence, one way back.
private struct Missing: View {
    let back: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Text("This title isn't available.").font(.title3.weight(.semibold))
            Button("Back to Home", action: back).buttonStyle(CapsuleStyle(primary: true))
        }
        .frame(maxWidth: .infinity)
    }
}

/// A series from an episode on: one player after another, as the TV's queue (#158, until #157's native player).
struct QueueScreen: View {
    let queue: PlayQueue
    let session: NectarSession
    let done: () -> Void

    @State
    private var index = 0
    @State
    private var current: PlayerModel?

    var body: some View {
        Group {
            if let current {
                PlayerScreen(model: current, done: done).id(current.id + String(index))
            } else {
                Color.black.ignoresSafeArea()
            }
        }
        .task(id: index) { begin() }
    }

    private func begin() {
        guard queue.cards.indices.contains(index) else { return done() }
        let player = PlayerModel(card: queue.cards[index], session: session)
        player.finished = { index += 1 }
        current = player
    }
}
