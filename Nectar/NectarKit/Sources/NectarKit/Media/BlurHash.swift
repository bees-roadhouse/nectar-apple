import CoreGraphics
import Foundation

/// A BlurHash, the few characters nectar computes per image (nectar#458), decoded to a tiny picture to show while the
/// artwork loads (nectar-apple #114, nectar#376 slice 2). It follows the format's reference decoder: an average colour
/// plus a grid of cosine terms, in linear light, back to sRGB.
public enum BlurHash {

    private static let digits: [Character: Int] = Dictionary(
        uniqueKeysWithValues: "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz#$%*+,-.:;=?@[]^_{|}~"
            .enumerated().map { ($1, $0) }
    )

    /// RGBA bytes, row by row, `width` × `height`; nil for a malformed hash or no size.
    public static func pixels(_ hash: String, width: Int, height: Int, punch: Double = 1) -> [UInt8]? {
        let chars = Array(hash)
        guard width > 0, height > 0, chars.count >= 6, let sizeFlag = decode83(chars[0 ..< 1]) else { return nil }
        let componentsX = sizeFlag % 9 + 1
        let componentsY = sizeFlag / 9 + 1
        guard chars.count == 4 + 2 * componentsX * componentsY,
              let quantisedMax = decode83(chars[1 ..< 2]),
              let average = decode83(chars[2 ..< 6])
        else { return nil }

        let maxValue = Double(quantisedMax + 1) / 166 * punch
        var colours = [[sRGBToLinear(average >> 16), sRGBToLinear((average >> 8) & 255), sRGBToLinear(average & 255)]]
        for i in 1 ..< componentsX * componentsY {
            guard let value = decode83(chars[(4 + i * 2) ..< (6 + i * 2)]) else { return nil }
            colours.append([value / (19 * 19), (value / 19) % 19, value % 19].map { signPow((Double($0) - 9) / 9, 2) * maxValue })
        }

        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0 ..< height {
            for x in 0 ..< width {
                var rgb = [0.0, 0.0, 0.0]
                for j in 0 ..< componentsY {
                    for i in 0 ..< componentsX {
                        let basis = cos(Double.pi * Double(x * i) / Double(width)) * cos(Double.pi * Double(y * j) / Double(height))
                        let colour = colours[i + j * componentsX]
                        for c in 0 ..< 3 { rgb[c] += colour[c] * basis }
                    }
                }
                let offset = (y * width + x) * 4
                for c in 0 ..< 3 { pixels[offset + c] = linearToSRGB(rgb[c]) }
            }
        }
        return pixels
    }

    /// The decoded picture, small (32 × 32 is plenty) and stretched by the view that shows it.
    public static func image(_ hash: String, width: Int, height: Int, punch: Double = 1) -> CGImage? {
        guard let pixels = pixels(hash, width: width, height: height, punch: punch),
              let provider = CGDataProvider(data: Data(pixels) as CFData)
        else { return nil }
        return CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent
        )
    }

    private static func decode83(_ chars: ArraySlice<Character>) -> Int? {
        var value = 0
        for char in chars {
            guard let digit = digits[char] else { return nil }
            value = value * 83 + digit
        }
        return value
    }

    private static func sRGBToLinear(_ value: Int) -> Double {
        let v = Double(value) / 255
        return v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
    }

    private static func linearToSRGB(_ value: Double) -> UInt8 {
        let v = max(0, min(1, value))
        let srgb = v <= 0.0031308 ? v * 12.92 : 1.055 * pow(v, 1 / 2.4) - 0.055
        return UInt8(min(255, max(0, (srgb * 255 + 0.5).rounded(.down))))
    }

    private static func signPow(_ value: Double, _ exponent: Double) -> Double {
        copysign(pow(abs(value), exponent), value)
    }
}

/// What to show while one image loads: its BlurHash, and the shape to decode it at, so a view that fills a frame
/// crops the preview the way it will crop the artwork.
public struct BlurPreview: Equatable, Sendable {
    public let hash: String
    /// Width over height. A hash doesn't carry the image's shape; nectar's posters are 2:3 and its backdrops 16:9.
    public let aspect: Double

    public static let poster = 2.0 / 3
    public static let backdrop = 16.0 / 9
    public static let still = 16.0 / 9

    public init(hash: String, aspect: Double) {
        self.hash = hash
        self.aspect = aspect
    }

    /// The decoded preview, at most `longSide` pixels on its longer side; nil for a malformed hash.
    public func image(longSide: Int = 32) -> CGImage? {
        let width = aspect >= 1 ? longSide : max(1, Int((Double(longSide) * aspect).rounded()))
        let height = aspect >= 1 ? max(1, Int((Double(longSide) / aspect).rounded())) : longSide
        return BlurHash.image(hash, width: width, height: height)
    }
}
