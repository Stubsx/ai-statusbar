import Cocoa

/// 两种外观共用简洁的静态色面，流光由原生层单独驱动。
enum BallInkDrawing {
    enum Palette {
        case ink, blue

        var still: CGImage? { self == .ink ? BallInkDrawing.dark : BallInkDrawing.blue }

        func flowDuration(working: Bool) -> TimeInterval {
            working ? 7 : 18
        }
    }

    static let dark = render()
    static let blue = render(palette: .blue)

    private static func smooth(_ low: Double, _ high: Double, _ value: Double) -> Double {
        let t = max(0, min(1, (value - low) / (high - low)))
        return t * t * (3 - 2 * t)
    }

    // 图标导出工具也使用此入口，以原生分辨率复用晴蓝静态色面。
    static func render(size: Int = 384, phase: Double = 0, palette: Palette = .ink) -> CGImage? {
        let edgeHalfWidth = 2.4 / Double(size) * 0.6
        var pixels = [UInt8](repeating: 0, count: size * size * 4)
        for row in 0..<size {
            for column in 0..<size {
                let x = (Double(column) + 0.5) / Double(size) * 2.4 - 1.2
                let y = (Double(row) + 0.5) / Double(size) * 2.4 - 1.2
                let radius = hypot(x, y)
                let alpha = 1 - smooth(0.985 - edgeHalfWidth, 0.985 + edgeHalfWidth, radius)
                guard alpha > 0 else { continue }

                let vertical = smooth(-0.95, 0.95, y)
                let diagonal = smooth(-0.85, 0.85, x * 0.55 - y * 0.35)
                let red: Double
                let green: Double
                let blue: Double
                if palette == .ink {
                    let shade = 0.055 + vertical * 0.255 + diagonal * 0.025
                    red = shade
                    green = shade
                    blue = shade
                } else {
                    red = 0.10 + vertical * 0.12 + diagonal * 0.025
                    green = 0.43 + vertical * 0.22 + diagonal * 0.05
                    blue = 0.94 + diagonal * 0.05
                }

                let index = (row * size + column) * 4
                pixels[index] = UInt8(max(0, min(255, (red * alpha * 255).rounded())))
                pixels[index + 1] = UInt8(max(0, min(255, (green * alpha * 255).rounded())))
                pixels[index + 2] = UInt8(max(0, min(255, (blue * alpha * 255).rounded())))
                pixels[index + 3] = UInt8(max(0, min(255, (alpha * 255).rounded())))
            }
        }
        guard let provider = CGDataProvider(data: Data(pixels) as CFData),
              let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        return CGImage(width: size, height: size, bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: size * 4, space: colorSpace,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }
}
