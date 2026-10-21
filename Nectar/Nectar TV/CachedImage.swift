import NectarKit
import SwiftUI

/// `AsyncImage`, through nectar's image cache (#37): unchanged artwork comes from the device, not the server,
/// decoded at the size it's drawn. `maxPixelSize` is the longer side in pixels. With a `blurHash`, its blur fills the
/// frame at once and the artwork fades in over it (#114); without one, `placeholder` shows as before.
struct CachedImage<Content: View, Placeholder: View>: View {

    let url: URL?
    let maxPixelSize: Int
    var blurHash: String?
    @ViewBuilder
    let content: (Image) -> Content
    @ViewBuilder
    let placeholder: () -> Placeholder

    @State
    private var image: Image?

    var body: some View {
        ZStack {
            if let blur = blurHash.flatMap(BlurPreviews.image) {
                // Stretched, not filled: the hash doesn't know the image's shape, and the frame is what the eye compares.
                Image(decorative: blur, scale: 1).resizable()
            } else if image == nil {
                placeholder()
            }
            if let image {
                content(image).transition(.opacity)
            }
        }
        .task(id: url) {
            guard let url else {
                image = nil
                return
            }
            let asked = ContinuousClock.now
            let bitmap = try? await ImageCache.shared.image(for: url, maxPixelSize: maxPixelSize)
            let loaded = bitmap.map { Image(decorative: $0.cgImage, scale: 1) }
            // Artwork already on the device appears at once; artwork that had to wait fades in over its blur.
            if ContinuousClock.now - asked < .milliseconds(100) {
                image = loaded
            } else {
                withAnimation(.easeOut(duration: Motion.fade)) { image = loaded }
            }
        }
    }
}

/// Each hash decoded once: a row redraws its cards as focus moves.
private enum BlurPreviews {

    nonisolated(unsafe) private static let decoded = NSCache<NSString, CGImage>()

    static func image(_ hash: String) -> CGImage? {
        let key = hash as NSString
        if let image = decoded.object(forKey: key) { return image }
        guard let image = BlurHash.image(hash, width: 32, height: 32) else { return nil }
        decoded.setObject(image, forKey: key)
        return image
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
