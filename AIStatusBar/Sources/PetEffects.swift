import Cocoa
import SwiftUI

// MARK: - 桌宠动效（Core Animation 层实现）
//
// 呼吸影子、打点、漂浮 Z、粒子、错误徽标等常驻动效原先用 SwiftUI
// `.animation(.repeatForever)`：NSHostingView 会跟着每个动画帧重跑整棵
// 布局树（实测主线程被持续占满，App ~46% CPU）。改为纯 CALayer 动画后
// 全部由渲染服务器合成，主线程零参与，动画参数与原 SwiftUI 版一一对应。
// 坐标以未缩放的 210×232 容器描述（与 PetSprite 的 frame 一致）；
// CALayer 原点在左下角、SwiftUI 在左上角，注意换算。

/// 形象后方的呼吸影子（error 心情不显示）。
struct PetEffectsBackdrop: NSViewRepresentable {
    let mood: PetMood
    let scale: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeNSView(context: Context) -> PetEffectsView {
        PetEffectsView(role: .backdrop, mood: mood, scale: scale,
                       reduceMotion: reduceMotion)
    }

    func updateNSView(_ view: PetEffectsView, context: Context) {
        view.update(mood: mood, scale: scale, reduceMotion: reduceMotion)
    }
}

/// 形象前方的状态动效：loading 打点 / sleeping 漂浮 Z / 粒子 / 错误徽标。
struct PetEffectsForeground: NSViewRepresentable {
    let mood: PetMood
    let scale: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeNSView(context: Context) -> PetEffectsView {
        PetEffectsView(role: .foreground, mood: mood, scale: scale,
                       reduceMotion: reduceMotion)
    }

    func updateNSView(_ view: PetEffectsView, context: Context) {
        view.update(mood: mood, scale: scale, reduceMotion: reduceMotion)
    }
}

/// 只做 CALayer 容器：不参与命中测试（点击穿透给 SwiftUI 手势），
/// 窗口遮挡恢复时重建一次子层（orderOut 会丢弃进行中的层动画）。
final class PetEffectsView: NSView {
    enum Role {
        case backdrop
        case foreground
    }

    private let role: Role
    private var mood: PetMood
    private var scale: CGFloat
    private var reduceMotion: Bool
    private var appliedMood: PetMood
    private var appliedScale: CGFloat
    private var appliedReduceMotion: Bool

    init(role: Role, mood: PetMood, scale: CGFloat, reduceMotion: Bool) {
        self.role = role
        self.mood = mood
        self.scale = scale
        self.reduceMotion = reduceMotion
        self.appliedMood = mood
        self.appliedScale = scale
        self.appliedReduceMotion = reduceMotion
        super.init(frame: .zero)
        wantsLayer = true
        layer = CALayer()
        NotificationCenter.default.addObserver(
            forName: NSWindow.didChangeOcclusionStateNotification,
            object: nil, queue: .main
        ) { [weak self] note in
            guard let self,
                  let window = note.object as? NSWindow,
                  window === self.window,
                  window.occlusionState.contains(.visible)
            else { return }
            self.rebuild()
        }
        rebuild()
    }

    required init?(coder: NSCoder) {
        fatalError("PetEffectsView 不支持从 nib 构建")
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func update(mood: PetMood, scale: CGFloat, reduceMotion: Bool) {
        guard mood != appliedMood || scale != appliedScale
            || reduceMotion != appliedReduceMotion
        else { return }
        self.mood = mood
        self.scale = scale
        self.reduceMotion = reduceMotion
        rebuild()
    }

    private func rebuild() {
        guard let layer else { return }
        layer.sublayers?.forEach { $0.removeFromSuperlayer() }
        switch role {
        case .backdrop: buildBackdrop()
        case .foreground: buildForeground()
        }
        appliedMood = mood
        appliedScale = scale
        appliedReduceMotion = reduceMotion
    }

    private var s: CGFloat { scale }

    // MARK: 构建子层

    private func buildBackdrop() {
        guard mood != .error else { return }
        // SwiftUI：72×8 椭圆 offset(-69, 218)，topTrailing 对齐换算后左上角 (69, 218)
        let frame = CGRect(x: 69 * s, y: (232 - 218 - 8) * s,
                           width: 72 * s, height: 8 * s)
        let ellipse = CAShapeLayer()
        ellipse.frame = frame
        ellipse.path = CGPath(ellipseIn: CGRect(origin: .zero, size: frame.size),
                              transform: nil)
        ellipse.fillColor = NSColor.black.cgColor
        ellipse.opacity = 0.10
        let duration = shadowDuration
        if !reduceMotion {
            animate(ellipse, key: "breathe-opacity", keyPath: "opacity",
                    from: 0.10, to: 0.055, duration: duration)
            animate(ellipse, key: "breathe-width", keyPath: "transform.scale.x",
                    from: 1.0, to: shadowScale, duration: duration)
        }
        layer?.addSublayer(ellipse)
    }

    private var shadowScale: CGFloat {
        switch mood {
        case .celebrating: return 0.76
        case .working: return 0.88
        case .loading: return 0.92
        case .idle: return 0.96
        case .sleeping: return 0.98
        case .error: return 1
        }
    }

    private var shadowDuration: Double {
        switch mood {
        case .celebrating: return 0.46
        case .working: return 0.92
        case .loading: return 1.2
        case .idle: return 2.1
        case .sleeping: return 2.6
        case .error: return 1
        }
    }

    private func buildForeground() {
        switch mood {
        case .loading:
            buildLoadingDots()
        case .sleeping:
            buildDriftingZ("Z", size: 18, delay: 0, x: -9)
            buildDriftingZ("z", size: 14, delay: 0.7, x: -25)
            buildDriftingZ("z", size: 11, delay: 1.4, x: -39)
        case .celebrating:
            buildSparkle(size: 19, delay: 0, duration: 0.52, x: -12, y: 4, color: .yellow)
            buildSparkle(size: 14, delay: 0.18, duration: 0.52, x: -172, y: 35, color: .yellow)
            buildSparkle(size: 12, delay: 0.36, duration: 0.52, x: -155, y: 96, color: .orange)
        case .working:
            buildSparkle(size: 15, delay: 0, duration: 0.92, x: -137, y: 108, color: .cyan)
            buildSparkle(size: 11, delay: 0.46, duration: 0.92, x: -169, y: 132, color: .green)
        case .error:
            buildErrorBadge()
        case .idle:
            break
        }
    }

    /// loading 打点：42×18 半透明胶囊 + 三个 6pt 蓝点，左上角 (164, 8)。
    /// 原 SwiftUI 版背景是 ultraThinMaterial，层版本用半透明胶囊近似
    /// （loading 只在启动后首份数据到来前短暂出现）。
    private func buildLoadingDots() {
        let capsule = CALayer()
        capsule.frame = CGRect(x: 164 * s, y: (232 - 8 - 18) * s,
                               width: 42 * s, height: 18 * s)
        capsule.cornerRadius = 9 * s
        capsule.backgroundColor = NSColor.white.withAlphaComponent(0.55).cgColor
        capsule.borderColor = NSColor.black.withAlphaComponent(0.08).cgColor
        capsule.borderWidth = 0.5
        layer?.addSublayer(capsule)

        for index in 0..<3 {
            let dot = CALayer()
            let diameter = 6 * s
            let centerX = CGFloat(175 + index * 10) * s
            let centerY = (232 - 17) * s
            let radius = diameter / 2
            dot.frame = CGRect(x: centerX - radius, y: centerY - radius,
                               width: diameter, height: diameter)
            dot.cornerRadius = diameter / 2
            dot.backgroundColor = NSColor.blue.cgColor
            dot.opacity = 0.42
            if !reduceMotion {
                animate(dot, key: "pulse-opacity", keyPath: "opacity",
                        from: 0.42, to: 0.84, duration: 0.62,
                        delay: Double(index) * 0.20)
                animate(dot, key: "pulse-scale", keyPath: "transform.scale",
                        from: 0.75, to: 1.0, duration: 0.62,
                        delay: Double(index) * 0.20)
            }
            layer?.addSublayer(dot)
        }
    }

    /// sleeping 漂浮 Z：从下方浮起并淡出，循环不回弹（easeOut 1.45s）。
    private func buildDriftingZ(_ text: String, size: CGFloat, delay: Double, x: CGFloat) {
        let font = roundedFont(size: size, weight: .bold)
        let attributed = NSAttributedString(
            string: text,
            attributes: [.font: font, .foregroundColor: NSColor.blue])
        let textSize = attributed.size()
        let textWidth = textSize.width * s
        let textHeight = textSize.height * s
        // topTrailing 对齐：右缘在 210 + x，基态（原 active 态）顶缘在 -7
        let textLayer = CATextLayer()
        let frameX = (210 + x) * s - textWidth
        let frameY = (232 + 7) * s - textHeight
        textLayer.frame = CGRect(x: frameX, y: frameY,
                                 width: textWidth, height: textHeight)
        textLayer.string = text
        textLayer.font = font
        textLayer.fontSize = size * s
        textLayer.foregroundColor = NSColor.blue.cgColor
        textLayer.alignmentMode = .center
        textLayer.contentsScale = backingScale
        // 基态停在动画起点（下落 23pt、不透明），delay 期间与 SwiftUI 行为一致
        textLayer.opacity = 0.85
        let drift = -23.0 * Double(s)
        textLayer.transform = CATransform3DMakeTranslation(0, drift, 0)
        if !reduceMotion {
            animate(textLayer, key: "drift-y", keyPath: "transform.translation.y",
                    from: drift, to: 0.0, duration: 1.45, delay: delay,
                    autoreverses: false, easeOut: true)
            animate(textLayer, key: "drift-fade", keyPath: "opacity",
                    from: 0.85, to: 0.25, duration: 1.45, delay: delay,
                    autoreverses: false, easeOut: true)
        }
        layer?.addSublayer(textLayer)
    }

    /// 粒子：SF Symbol "sparkle" 上色 + 同色辉光，缩放/透明度往复。
    private func buildSparkle(
        size: CGFloat, delay: Double, duration: Double,
        x: CGFloat, y: CGFloat, color: NSColor
    ) {
        guard let sparkle = SparkleStore.image(pointSize: size, color: color) else { return }
        let spriteWidth = sparkle.pointSize.width * s
        let spriteHeight = sparkle.pointSize.height * s
        let sprite = CALayer()
        let frameX = (210 + x) * s - spriteWidth
        let frameY = (232 - y) * s - spriteHeight
        sprite.frame = CGRect(x: frameX, y: frameY, width: spriteWidth, height: spriteHeight)
        sprite.contents = sparkle.cgImage
        sprite.contentsScale = backingScale
        sprite.shadowColor = color.cgColor
        sprite.shadowOpacity = 0.30
        sprite.shadowRadius = 3 * s
        sprite.opacity = 0.30
        if !reduceMotion {
            animate(sprite, key: "twinkle-scale", keyPath: "transform.scale",
                    from: 0.62, to: 0.96, duration: duration, delay: delay)
            animate(sprite, key: "twinkle-opacity", keyPath: "opacity",
                    from: 0.30, to: 0.88, duration: duration, delay: delay)
        }
        layer?.addSublayer(sprite)
    }

    /// error 徽标：红色圆 + 白色描边 + "!"，整体 0.95↔1.0 往复脉动。
    private func buildErrorBadge() {
        let badge = CALayer()
        badge.frame = CGRect(x: 177 * s, y: (232 - 10 - 25) * s,
                             width: 25 * s, height: 25 * s)

        let circle = CAShapeLayer()
        circle.frame = CGRect(origin: .zero, size: badge.frame.size)
        circle.path = CGPath(ellipseIn: circle.frame, transform: nil)
        circle.fillColor = NSColor.red.cgColor
        circle.strokeColor = NSColor.white.withAlphaComponent(0.85).cgColor
        circle.lineWidth = 1.5 * s
        circle.shadowColor = NSColor.red.cgColor
        circle.shadowOpacity = 0.35
        circle.shadowRadius = 5 * s
        badge.addSublayer(circle)

        let mark = CATextLayer()
        mark.frame = badge.frame.insetBy(dx: 0, dy: badge.frame.height * 0.16)
        mark.string = "!"
        mark.font = NSFont.systemFont(ofSize: 13 * s, weight: .black)
        mark.fontSize = 13 * s
        mark.foregroundColor = NSColor.white.cgColor
        mark.alignmentMode = .center
        mark.contentsScale = backingScale
        badge.addSublayer(mark)

        badge.transform = CATransform3DMakeScale(0.95, 0.95, 1)
        if !reduceMotion {
            animate(badge, key: "badge-pulse", keyPath: "transform.scale",
                    from: 0.95, to: 1.0, duration: 0.75)
        }
        layer?.addSublayer(badge)
    }

    // MARK: 动画与工具

    private func animate(
        _ target: CALayer, key: String, keyPath: String,
        from: Any, to: Any, duration: Double, delay: Double = 0,
        autoreverses: Bool = true, easeOut: Bool = false
    ) {
        let animation = CABasicAnimation(keyPath: keyPath)
        animation.fromValue = from
        animation.toValue = to
        animation.duration = duration
        if delay > 0 { animation.beginTime = CACurrentMediaTime() + delay }
        animation.autoreverses = autoreverses
        animation.repeatCount = .infinity
        animation.timingFunction = CAMediaTimingFunction(
            name: easeOut ? .easeOut : .easeInEaseOut)
        target.add(animation, forKey: key)
    }

    private var backingScale: CGFloat {
        window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
    }

    private func roundedFont(size: CGFloat, weight: NSFont.Weight) -> NSFont {
        let base = NSFont.systemFont(ofSize: size, weight: weight)
        if let descriptor = base.fontDescriptor.withDesign(.rounded),
           let rounded = NSFont(descriptor: descriptor, size: size)
        {
            return rounded
        }
        return base
    }
}

/// 上色后的 SF Symbol 粒子图缓存（尺寸×颜色组合有限，进程内复用）。
private enum SparkleStore {
    fileprivate struct Sparkle {
        let cgImage: CGImage
        let pointSize: CGSize
    }

    private static var cache: [String: Sparkle] = [:]

    fileprivate static func image(pointSize: CGFloat, color: NSColor) -> Sparkle? {
        let key = "\(pointSize)-\(color)"
        if let cached = cache[key] { return cached }
        guard let symbol = NSImage(
            systemSymbolName: "sparkle", accessibilityDescription: nil),
            let sized = symbol.withSymbolConfiguration(
                .init(pointSize: pointSize, weight: .semibold))
        else { return nil }
        let tinted = tint(sized, with: color)
        guard let cgImage = tinted else { return nil }
        let sparkle = Sparkle(cgImage: cgImage, pointSize: sized.size)
        cache[key] = sparkle
        return sparkle
    }

    /// 模板符号用 sourceAtop 上色，避免重新光栅化两层。
    private static func tint(_ image: NSImage, with color: NSColor) -> CGImage? {
        let size = image.size
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: max(1, Int(size.width * 2)),
            pixelsHigh: max(1, Int(size.height * 2)),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
            let cgImage = rep.cgImage
        else { return nil }
        rep.size = size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        let rect = NSRect(origin: .zero, size: size)
        image.draw(in: rect)
        color.set()
        rect.fill(using: .sourceAtop)
        NSGraphicsContext.restoreGraphicsState()
        return cgImage
    }
}
