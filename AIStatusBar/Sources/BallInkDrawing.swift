import Cocoa

/// 水墨与晴蓝晕染由代码生成，不读取图片素材。各配色的静帧与循环帧按需缓存，
/// 流动帧由原生层播放，眼睛与工作环独立运动。
enum BallInkDrawing {
    enum Palette {
        case ink, blue

        var still: CGImage? { self == .ink ? BallInkDrawing.dark : BallInkDrawing.blue }
        var frames: [CGImage] { self == .ink ? BallInkDrawing.flowFrames : BallInkDrawing.blueFlowFrames }
        var startupFrames: [CGImage] {
            self == .ink ? BallInkDrawing.inkStartupFrames : BallInkDrawing.blueStartupFrames
        }

        func flowDuration(working: Bool) -> TimeInterval {
            self == .blue ? (working ? 6 : 10) : (working ? 8 : 14)
        }
    }

    static let dark = render()
    static let blue = render(palette: .blue)
    static let flowFrameCount = 96
    static let flowFrames: [CGImage] = (0..<flowFrameCount).compactMap {
        render(size: 160, phase: Double($0) / Double(flowFrameCount))
    }
    static let blueFlowFrames: [CGImage] = (0..<flowFrameCount).compactMap {
        render(size: 160, phase: Double($0) / Double(flowFrameCount), palette: .blue)
    }
    // 先生成一个完整但较轻的循环，慢机器不必等全部高精度帧才开始流动。
    private static let inkStartupFrames = startupFrames(palette: .ink)
    private static let blueStartupFrames = startupFrames(palette: .blue)

    private static func startupFrames(palette: Palette) -> [CGImage] {
        (0..<24).compactMap { render(size: 112, phase: Double($0) / 24, palette: palette) }
    }

    static func noise(_ x: Double, _ y: Double, seed: UInt32 = 17) -> Double {
        func hash(_ x: Int, _ y: Int) -> Double {
            var value = UInt32(truncatingIfNeeded: x) &* 374_761_393
            value &+= UInt32(truncatingIfNeeded: y) &* 668_265_263 &+ seed &* 144_269_507
            value = (value ^ (value >> 13)) &* 1_274_126_177
            value ^= value >> 16
            return Double(value) / Double(UInt32.max)
        }
        let ix = Int(floor(x)), iy = Int(floor(y))
        let fx = x - Double(ix), fy = y - Double(iy)
        let sx = fx * fx * (3 - 2 * fx), sy = fy * fy * (3 - 2 * fy)
        let a = hash(ix, iy), b = hash(ix + 1, iy)
        let c = hash(ix, iy + 1), d = hash(ix + 1, iy + 1)
        return (a + (b - a) * sx) * (1 - sy) + (c + (d - c) * sx) * sy
    }

    static func field(_ x: Double, _ y: Double, seed: UInt32 = 17) -> Double {
        // 大、中、小三个尺度：控制内部水洗、积墨皱褶与细微纸感。
        (noise(x, y, seed: seed) * 0.58
         + noise(x * 2.07 + 9, y * 2.07 - 3, seed: seed) * 0.28
         + noise(x * 4.13 - 7, y * 4.13 + 8, seed: seed) * 0.14) * 2 - 1
    }

    private static func smooth(_ low: Double, _ high: Double, _ value: Double) -> Double {
        let t = max(0, min(1, (value - low) / (high - low)))
        return t * t * (3 - 2 * t)
    }

    // 图标导出工具也使用此入口，以原生分辨率复用晴蓝色层，避免放大运行时纹理。
    static func render(size: Int = 384, phase: Double = 0, palette: Palette = .ink) -> CGImage? {
        // 圆周参数在首尾完全相接，循环不重新播种噪声。
        let angle = phase * 2 * Double.pi
        let drift = sin(angle)
        let curl = cos(angle) - 1
        // 浅蓝的浓淡对比更低，需更大的色层位移，才能在实际 48pt 浮球中看清流动。
        let flowStrength = palette == .blue ? 2.2 : 1.0
        let edgeHalfWidth = 2.4 / Double(size) * 0.6
        var pixels = [UInt8](repeating: 0, count: size * size * 4)
        for row in 0..<size {
            for column in 0..<size {
                let x = (Double(column) + 0.5) / Double(size) * 2.4 - 1.2
                let y = (Double(row) + 0.5) / Double(size) * 2.4 - 1.2
                let r = hypot(x, y)
                // 外轮廓只按半径取抗锯齿覆盖率；噪声、相位和水洗不再改变透明度。
                let alpha = 1 - smooth(0.985 - edgeHalfWidth, 0.985 + edgeHalfWidth, r)
                guard alpha > 0 else { continue }
                let broad = field(x * 2.2 + 4, y * 2.2 - 6)

                // 浓墨收住上部神态，淡墨沿右下笔势叠染；不画球面亮斑或交叉裂纹。
                let wx = x + field(x * 1.8 + 15, y * 1.8 + 2, seed: 71) * 0.18
                    + flowStrength * (drift * 0.10 * cos(y * 2.4) + curl * 0.045 * sin(x * 2.0))
                let wy = y + broad * 0.15
                    + flowStrength * (drift * 0.10 * sin(x * 2.2 + 0.8) + curl * 0.07 * cos(x * 2.3))
                let folds = field(wx * 3.1 - 4, wy * 3.1 + 5, seed: 83)
                let flow = wy - wx * 0.15 + 0.18 * sin(wx * 3.0) + folds * 0.14
                    + flowStrength * 0.055 * (sin(angle + wx * 2.4) - sin(wx * 2.4))
                let washA = smooth(0.04, 0.25, flow)
                let washB = smooth(0.34, 0.53, flow + folds * 0.09)
                let washC = smooth(0.63, 0.78, flow - broad * 0.07)
                let sideWash = smooth(0.60, 0.95, -wx + wy * 0.20 + folds * 0.14)
                // 积墨只在部分湿边富集；两条淡线顺着同一笔势展开。
                let tideA = exp(-abs(flow - 0.23) / 0.022) * smooth(-0.40, 0.65, wx)
                let tideB = exp(-abs(flow + folds * 0.09 - 0.49) / 0.021)
                    * smooth(-0.3, 0.6, -wx)
                let face = exp(-pow(x / 0.57, 4) - pow((y + 0.17) / 0.39, 4))
                let dilution = (washA * 0.15 + washB * 0.23 + washC * 0.14 + sideWash * 0.14)
                    * (1 - face * 0.63)
                let grain = noise(x * 145 + 61, y * 145 - 37, seed: 113)
                var pigment = 0.94 - dilution + tideA * 0.11 + tideB * 0.09
                pigment += (grain - 0.5) * 0.025 * (1 - face * 0.9)
                pigment = max(0.12, min(0.98, pigment))

                let index = (row * size + column) * 4
                if palette == .ink {
                    let white = (1 - pigment) * alpha
                    let channel = UInt8(max(0, min(255, (white * 255).rounded())))
                    pixels[index] = channel
                    pixels[index + 1] = channel
                    pixels[index + 2] = channel
                } else {
                    // 晴蓝以天蓝稳住面部，浅蓝水洗从左上及下缘漫入，积色留在球体内部。
                    // 色面沿笔势叠染，细微纸感固定在原处，避免球面高光和颗粒翻滚。
                    let cloud = smooth(-0.70, 0.58, -wx * 0.72 - wy * 0.55 + folds * 0.25)
                        * (1 - face * 0.55)
                    let water = min(0.80, dilution * 0.95 + cloud * 0.30)
                    let pooling = tideA * 0.7 + tideB * 0.5
                    let tooth = (grain - 0.5) * 0.010 * (1 - face * 0.8)
                    let red = max(0, min(1, 0.14 + water * 0.69 - pooling * 0.055 + tooth))
                    let green = max(0, min(1, 0.53 + water * 0.41 + washC * 0.025 - pooling * 0.035 + tooth))
                    let blue = max(0, min(1, 0.98 + water * 0.015 + tooth))
                    pixels[index] = UInt8((red * alpha * 255).rounded())
                    pixels[index + 1] = UInt8((green * alpha * 255).rounded())
                    pixels[index + 2] = UInt8((blue * alpha * 255).rounded())
                }
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
