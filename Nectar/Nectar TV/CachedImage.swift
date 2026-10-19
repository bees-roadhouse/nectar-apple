import NectarKit
import SwiftUI

/// `AsyncImage`, through nectar's image cache (#37): unchanged artwork comes from the device, not the server,
/// decoded at the size it's drawn. `maxPixelSize` is the longer side in pixels.
struct CachedImage<Content: View, Placeholder: View>: View {

    let url: URL?
    let maxPixelSize: Int
    @ViewBuilder
    let content: (Image) -> Content
    @ViewBuilder
    let placeholder: () -> Placeholder

    @State
    private var image: Image?

    var body: some View {
        Group {
            if let image {
                content(image)
            } else {
                placeholder()
            }
        }
        .task(id: url) {
            guard let url else {
                image = nil
                return
            }
            let bitmap = try? await ImageCache.shared.image(for: url, maxPixelSize: maxPixelSize)
            image = bitmap.map { Image(decorative: $0.cgImage, scale: 1) }
        }
    }
}

extension ImageCache {
    /// For a row about to show: fetch what isn't on the device yet, in the background.
    nonisolated func prefetch(_ urls: [URL?]) {
        let urls = urls.compactMap(\.self)
        guard !urls.isEmpty else { return }
        Task(priority: .utility) { await prefetch(urls) }
    }
}
