import Cocoa
import ImageIO
import UniformTypeIdentifiers

/// 独立导出工具：复用晴蓝静帧，并按悬浮球的正视比例绘制白色胶囊眼睛。
@main
enum AppIconRenderer {
    static func context(width: Int, height: Int) -> CGContext {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            fatalError("Cannot create icon canvas")
        }
        context.interpolationQuality = .high
        return context
    }

    static func write(_ image: CGImage, to url: URL) throws {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL,
                                                                UTType.png.identifier as CFString, 1, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
    }

    static func resize(_ image: CGImage, to size: Int) -> CGImage {
        if image.width == size && image.height == size { return image }
        let canvas = context(width: size, height: size)
        canvas.draw(image, in: CGRect(x: 0, y: 0, width: size, height: size))
        return canvas.makeImage()!
    }

    static func render() -> CGImage {
        let size = 1024
        guard let wash = BallInkDrawing.render(size: size, palette: .blue) else {
            fatalError("Cannot render blue wash")
        }
        let canvas = context(width: size, height: size)
        canvas.draw(wash, in: CGRect(x: 0, y: 0, width: size, height: size))

        // 对应 FloatingBallArtwork 的 56pt 纹理、±6pt 眼位和 -3.8pt 面部上移。
        let scale = CGFloat(size) / 56
        let perspective = (70 + sqrt(20 * 20 - 6 * 6 - 3.8 * 3.8)) / 90
        let eyeWidth = 5.8 * perspective * scale
        let eyeHeight = 10.8 * perspective * scale
        for side in [-1.0, 1.0] {
            canvas.saveGState()
            canvas.translateBy(x: CGFloat(size) / 2 + side * 6 * scale,
                               y: CGFloat(size) / 2 + 3.8 * scale)
            canvas.rotate(by: -9 * .pi / 180)
            let rect = CGRect(x: -eyeWidth / 2, y: -eyeHeight / 2,
                              width: eyeWidth, height: eyeHeight)
            canvas.addPath(CGPath(roundedRect: rect, cornerWidth: eyeWidth / 2,
                                  cornerHeight: eyeWidth / 2, transform: nil))
            canvas.setFillColor(CGColor(gray: 1, alpha: 1))
            canvas.fillPath()
            canvas.restoreGState()
        }
        return canvas.makeImage()!
    }

    static func preview(_ image: CGImage) -> CGImage {
        let canvas = context(width: 960, height: 580)
        for column in 0..<2 {
            let origin = CGFloat(column * 480)
            canvas.setFillColor(column == 0
                ? CGColor(red: 0.96, green: 0.97, blue: 0.99, alpha: 1)
                : CGColor(red: 0.07, green: 0.09, blue: 0.14, alpha: 1))
            canvas.fill(CGRect(x: origin, y: 0, width: 480, height: 580))
            canvas.draw(image, in: CGRect(x: origin + 60, y: 184, width: 360, height: 360))
            let sizes = [16, 32, 64, 128]
            let centers: [CGFloat] = [64, 150, 252, 380]
            for (index, size) in sizes.enumerated() {
                let x = origin + centers[index] - CGFloat(size) / 2
                let y = 104 - CGFloat(size) / 2
                canvas.draw(resize(image, to: size), in: CGRect(x: x, y: y, width: CGFloat(size), height: CGFloat(size)))
            }
        }
        return canvas.makeImage()!
    }

    static func main() throws {
        guard CommandLine.arguments.count == 2 else {
            fatalError("Usage: render-app-icon <output-directory>")
        }
        let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let iconset = output.appendingPathComponent("AppIcon.iconset", isDirectory: true)
        try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
        let master = render()
        try write(master, to: output.appendingPathComponent("AppIcon-1024.png"))
        for size in [16, 32, 64, 128, 256, 512] {
            for scale in [1, 2] {
                let suffix = scale == 1 ? "" : "@2x"
                try write(resize(master, to: size * scale),
                          to: iconset.appendingPathComponent("icon_\(size)x\(size)\(suffix).png"))
            }
        }
        try write(preview(master), to: output.appendingPathComponent("preview.png"))
        print("Rendered blue-wash app icon and 12 size variants")
    }
}
