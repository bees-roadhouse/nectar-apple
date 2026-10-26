import AVKit
import NectarKit
import SwiftUI

/// A library title, full screen: the backdrop, what it is, Play or Resume, and rows of chapters, cast and titles like it.
struct ItemDetailView: View {

    @State
    private var model: ItemDetailModel

    init(id: String, session: NectarSession, playlistAdding: PlaylistAdding) {
        _model = State(initialValue: ItemDetailModel(id: id, session: session, playlistAdding: playlistAdding))
    }

    var body: some View {
        Group {
            switch model.detail {
            case .loading:
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            case .failed:
                Text("Couldn't load this title.").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            case let .loaded(detail):
                page(detail)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.ignoresSafeArea())
        .task { await model.load() }
        .fullScreenCover(item: $model.playing, onDismiss: model.finishedPlaying) { player in
            PlayerView(model: player) { model.playing = nil }
        }
        .fullScreenCover(item: $model.queue, onDismiss: model.finishedQueue) { queue in
            QueuePlayer(queue: queue, session: model.session) { model.queue = nil }
        }
        .fullScreenCover(item: $model.trailer) { trailer in
            VideoPlayer(player: trailer.player)
                .ignoresSafeArea()
                .onAppear { trailer.player.play() }
                .onDisappear { trailer.player.pause() }
        }
        .fullScreenCover(item: Bindable(model.playlistAdding).target) { target in
            PlaylistPicker(target: target, model: model.playlistAdding)
        }
        .fullScreenCover(item: $model.opened) { card in
            ItemDetailView(id: card.id, session: model.session, playlistAdding: model.playlistAdding)
        }
        .fullScreenCover(item: $model.person) { person in
            PersonView(id: person.id, session: model.session, playlistAdding: model.playlistAdding)
        }
    }

    private func page(_ detail: ItemDetail) -> some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 60) {
                // A series leaves room for its seasons and the top of the episode row to show below.
                header(detail)
                    .frame(minHeight: detail.itemType == "series" ? 560 : 820, alignment: .bottomLeading)
                if !model.seasons.isEmpty {
                    seasons(detail)
                }
                if !detail.chapters.isEmpty {
                    Row(title: "Chapters") {
                        ForEach(detail.chapters) { chapter in
                            ChapterCard(chapter: chapter, thumbnail: model.chapterThumbnails[chapter.index]) {
                                model.play(detail, from: chapter.startSeconds)
                            }
                        }
                    }
                }
                if !detail.cast.isEmpty {
                    Row(title: "Cast") {
                        ForEach(detail.cast) { person in
                            CastCard(person: person) { model.person = person }
                        }
                    }
                }
                if !model.similar.isEmpty {
                    Row(title: "More like this") {
                        ForEach(model.similar) { card in
                            LibraryPoster(card: card, shape: .init(.movies), artwork: model.session.resolve(card.posterPath, pixelWidth: 480)) {
                                model.opened = card
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 80)
            .padding(.bottom, 80)
        }
        .background(alignment: .top) {
            CachedImage(
                url: model.session.resolve(detail.backdropPath ?? detail.posterPath, pixelWidth: 1920), maxPixelSize: 3840,
                blurHash: detail.artworkBlurHash
            ) { image in
                image.resizable().aspectRatio(contentMode: .fill)
            } placeholder: {
                Color.black
            }
            .frame(height: 1080)
            .clipped()
            .overlay(LinearGradient(colors: [.clear, .black.opacity(0.6), .black], startPoint: .top, endPoint: .bottom))
            .ignoresSafeArea()
        }
    }

    private func header(_ detail: ItemDetail) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(detail.title).font(.largeTitle.bold())
            Text(facts(detail)).foregroundStyle(.secondary)
            // Everything on a detail page is in the library: a waiting stage is the monitor at rest, in words (#142).
            if let status = CardStatus.of(detail.pipeline, owned: true) {
                DetailStatus(status: status)
            } else if let following = CardStatus.following(detail.pipeline, isSeries: detail.itemType == "series") {
                Text(following).font(.callout).foregroundStyle(.secondary)
            }
            if let tagline = detail.tagline, !tagline.isEmpty {
                Text(tagline).font(.headline).italic()
            }
            if let overview = detail.overview, !overview.isEmpty {
                Text(overview).frame(maxWidth: 1100, alignment: .leading).lineLimit(5)
            }
            if !detail.genres.isEmpty || !detail.directors.isEmpty {
                Text(credits(detail)).font(.callout).foregroundStyle(.secondary)
            }
            if let playlist = model.playlistAdding.addedTo[PlaylistAdding.Target.owned(id: detail.id, title: detail.title).id] {
                Text("Added to \(playlist)").font(.headline)
            }
            HStack(spacing: 30) {
                if detail.itemType == "series", let next = Season.nextUp(in: model.seasons) {
                    let code = next.episode.code ?? next.episode.title
                    if let resume = next.resume {
                        Button("Resume \(code) from \(Self.clock(resume))", systemImage: "play.fill") { model.play(next.episode, of: detail) }
                    } else {
                        Button("Play \(code)", systemImage: "play.fill") { model.play(next.episode, of: detail) }
                    }
                } else if detail.itemType == "series", let first = model.seasons.first?.episodes.first {
                    Button("Watch again from \(first.code ?? first.title)", systemImage: "arrow.counterclockwise") { model.play(first, of: detail) }
                }
                if detail.itemType == "series" {
                    PreloadNextButton(series: detail, seasons: model.seasons, session: model.session)
                }
                if detail.itemType == "movie" || detail.itemType == "episode" {
                    if let resume = detail.resumeSeconds {
                        Button("Resume from \(Self.clock(resume))", systemImage: "play.fill") { model.play(detail, from: resume) }
                        Button("Play from the start", systemImage: "arrow.counterclockwise") { model.play(detail, from: nil) }
                    } else {
                        Button("Play", systemImage: "play.fill") { model.play(detail, from: nil) }
                    }
                }
                if detail.trailerPath != nil {
                    Button("Trailer", systemImage: "film") { Task { await model.playTrailer(detail) } }
                }
                if detail.itemType == "movie" || detail.itemType == "episode" {
                    PreloadButton(detail: detail, session: model.session)
                }
                Button("Add to playlist", systemImage: "text.badge.plus") {
                    model.playlistAdding.target = .owned(id: detail.id, title: detail.title)
                }
            }
        }
    }

    /// The season picker, then the chosen season's episodes.
    private func seasons(_ detail: ItemDetail) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            if model.seasons.count > 1 {
                ScrollView(.horizontal) {
                    HStack(spacing: 20) {
                        ForEach(model.seasons) { season in
                            Button(season.title) { model.selectedSeason = season.id }
                                .buttonStyle(.bordered)
                                .tint(season.id == model.selectedSeason ? .white : nil)
                        }
                    }
                    .padding(.vertical, 10)
                }
                .scrollClipDisabled()
            }
            if let season = model.seasons.first(where: { $0.id == model.selectedSeason }) {
                Row(title: model.seasons.count > 1 ? "Episodes" : season.title) {
                    ForEach(season.episodes) { episode in
                        EpisodeCard(episode: episode, thumbnail: model.session.resolve(episode.thumbPath, pixelWidth: EpisodeCard.size.width * 2)) {
                            model.play(episode, of: detail)
                        }
                    }
                }
            }
        }
    }

    private func facts(_ detail: ItemDetail) -> String {
        var parts: [String] = []
        if let year = detail.year { parts.append(String(year)) }
        if detail.itemType == "series" {
            if let seasons = detail.seasonCount { parts.append(seasons == 1 ? "1 season" : "\(seasons) seasons") }
            if let episodes = detail.episodeCount { parts.append(episodes == 1 ? "1 episode" : "\(episodes) episodes") }
        } else if let runtime = detail.runtimeSeconds, runtime > 0 {
            parts.append(Self.duration(runtime))
        }
        if let rating = detail.contentRating, !rating.isEmpty { parts.append(rating) }
        if let stars = detail.communityRating, stars > 0 { parts.append(String(format: "★ %.1f", stars)) }
        return parts.joined(separator: " · ")
    }

    private func credits(_ detail: ItemDetail) -> String {
        var parts: [String] = []
        if !detail.genres.isEmpty { parts.append(detail.genres.joined(separator: ", ")) }
        if !detail.directors.isEmpty { parts.append("Directed by " + detail.directors.joined(separator: ", ")) }
        return parts.joined(separator: "  ·  ")
    }

    /// "1h 56m"
    static func duration(_ seconds: Double) -> String { Durations.duration(seconds) }

    /// "1:21:52" or "21:52"
    static func clock(_ seconds: Double) -> String { Durations.clock(seconds) }
}

/// A titled horizontal row.
private struct Row<Content: View>: View {

    let title: String
    @ViewBuilder
    let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(title).font(.title3.bold())
            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: 40) { content() }
                    .padding(.vertical, 20)
            }
            .scrollClipDisabled()
        }
    }
}

private struct ChapterCard: View {

    static let size = CGSize(width: 400, height: 225)

    let chapter: ItemDetail.Chapter
    let thumbnail: URL?
    let select: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button(action: select) {
                CachedImage(url: thumbnail, maxPixelSize: Int(Self.size.width * 2)) { image in
                    image.resizable().aspectRatio(contentMode: .fill)
                } placeholder: {
                    Rectangle().fill(.quaternary)
                }
                .frame(width: Self.size.width, height: Self.size.height)
                .clipped()
            }
            .buttonStyle(.card)
            Text(chapter.title ?? "Chapter \(chapter.index + 1)").font(.caption).lineLimit(1).frame(width: Self.size.width, alignment: .leading)
            Text(ItemDetailView.clock(chapter.startSeconds)).font(.caption2).foregroundStyle(.secondary)
        }
    }
}

private struct CastCard: View {

    let person: ItemDetail.CastMember
    let select: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Button(action: select) {
                CachedImage(url: person.photo, maxPixelSize: 400) { image in
                    image.resizable().aspectRatio(contentMode: .fill)
                } placeholder: {
                    ZStack {
                        Rectangle().fill(.quaternary)
                        Text(initials).font(.title2.bold()).foregroundStyle(.secondary)
                    }
                }
                .frame(width: 180, height: 180)
                .clipShape(Circle())
            }
            .buttonStyle(.borderless)
            Text(person.name).font(.caption).lineLimit(1)
            if let character = person.character, !character.isEmpty {
                Text(character).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .frame(width: 200)
    }

    private var initials: String {
        person.name.split(separator: " ").prefix(2).compactMap(\.first).map(String.init).joined()
    }
}

/// An episode: its still, a watched mark or how far in, its number and title, and what happens in it.
private struct EpisodeCard: View {

    static let size = CGSize(width: 400, height: 225)

    let episode: Episode
    let thumbnail: URL?
    let select: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button(action: select) {
                CachedImage(url: thumbnail, maxPixelSize: Int(Self.size.width * 2), blurHash: episode.thumbBlurHash) { image in
                    image.resizable().aspectRatio(contentMode: .fill)
                } placeholder: {
                    ZStack {
                        Rectangle().fill(.quaternary)
                        Text(episode.label).font(.caption).multilineTextAlignment(.center).padding()
                    }
                }
                .frame(width: Self.size.width, height: Self.size.height)
                .clipped()
                .preloadBadge(episode.id)
                .overlay(alignment: .topTrailing) {
                    if episode.watched {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.title3)
                            .foregroundStyle(.white, .black.opacity(0.6))
                            .padding(10)
                    }
                }
                .overlay(alignment: .bottom) {
                    if episode.isInProgress, let runtime = episode.runtimeSeconds, runtime > 0 {
                        ProgressView(value: min(episode.progressSeconds / runtime, 1)).tint(.white).padding(10)
                    }
                }
            }
            .buttonStyle(.card)
            Text(episode.label).font(.caption).lineLimit(1).frame(width: Self.size.width, alignment: .leading)
            Text(details).font(.caption2).foregroundStyle(.secondary).lineLimit(2, reservesSpace: true)
                .frame(width: Self.size.width, alignment: .leading)
        }
    }

    private var details: String {
        var parts: [String] = []
        if let runtime = episode.runtimeSeconds, runtime > 0 { parts.append(ItemDetailView.duration(runtime)) }
        if let overview = episode.overview, !overview.isEmpty { parts.append(overview) }
        return parts.joined(separator: " · ")
    }
}
