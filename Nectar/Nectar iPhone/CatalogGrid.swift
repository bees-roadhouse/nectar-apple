import NectarKit
import SwiftUI

/// The shared owned-title grid for person credits and genre browse; geometry matches Library.
struct CatalogGrid: View {
    let cards: [MediaCard]
    var roles: [String: String] = [:]
    let session: NectarSession
    let width: CGFloat
    var loading = false
    var appeared: (MediaCard) -> Void = { _ in }
    let open: (MediaCard) -> Void
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        let columns = typeSize.isAccessibilitySize ? 1 : max(3, Int((width + 12) / 132))
        let cell = max(1, (width - CGFloat(columns - 1) * 12) / CGFloat(columns))
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12, alignment: .top), count: columns), alignment: .leading, spacing: 18) {
            ForEach(cards) { card in
                Button { open(card) } label: {
                    VStack(alignment: .leading, spacing: 6) {
                        artwork(card, width: cell)
                        Text(card.title ?? "Untitled").font(.subheadline.weight(.medium)).foregroundStyle(.primary)
                            .fixedSize(horizontal: false, vertical: true)
                        if let role = roles[card.id] {
                            Text(role).font(.footnote).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        if let year = card.year {
                            Text(String(year)).font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                    .frame(width: cell, alignment: .leading)
                    .accessibilityElement(children: .combine)
                }
                .buttonStyle(Pressed())
                .task { appeared(card) }
            }
            if loading {
                ForEach(0..<6) { _ in
                    VStack(alignment: .leading, spacing: 6) {
                        RoundedRectangle(cornerRadius: 8).fill(Color.brhCard).frame(width: cell, height: cell * 1.5)
                        Text("Title in your libraries").font(.subheadline.weight(.medium))
                        Text("2026").font(.footnote).foregroundStyle(.secondary)
                    }
                    .frame(width: cell, alignment: .leading)
                    .redacted(reason: .placeholder).accessibilityHidden(true)
                }
            }
        }
    }

    private func artwork(_ card: MediaCard, width: CGFloat) -> some View {
        let square = ["album", "track", "song", "artist"].contains(card.itemType ?? "")
        let url = card.posterPath.flatMap { path in
            path.hasPrefix("http") ? URL(string: path) : session.resolve(path, pixelWidth: Double(width * 3))
        }
        return CachedImage(url: url, maxPixelSize: Int(width * 3), blurHash: card.posterBlurHash) { image in
            image.resizable().scaledToFill()
        } placeholder: {
            ZStack {
                Color.brhCard
                Image(systemName: "film").font(.system(size: 24)).foregroundStyle(.secondary)
            }
        }
        .frame(width: width, height: square ? width : width * 1.5)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .accessibilityHidden(true)
    }
}
