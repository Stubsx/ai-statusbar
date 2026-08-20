import Cocoa
import SwiftUI

// UI 辅助：图标规范（NSColor 语义色、SF Symbol 绘制）、卡片背景材质、可拖动 HostingView。

// MARK: - 图标规范（与 ZSpaceMonitor 对齐）
// 运行时图标一律用 SF Symbol 程序化绘制 + 语义状态色，
// 不用 emoji 或 ●/▶ 等文本字符（渲染随系统字体漂移、明暗外观下不可控）。
// App 图标资产（AppIcon.icns / iconset）的规范见 ../icons/README.md。

extension NSColor {
    /// 三态语义色：busy=绿 idle=黄 off=灰。
    /// 菜单栏徽标、下拉菜单、面板共用同一映射，避免各处硬编码 RGB 后失配。
    static func toolStatusColor(_ state: String) -> NSColor {
        switch state {
        case "busy": return .systemGreen
        case "idle": return .systemYellow
        default: return .systemGray
        }
    }
}

/// 生成带颜色的 SF Symbol 图标（用于菜单行 NSMenuItem.image）。
/// 先绘制符号作为 alpha 蒙版，再用 sourceAtop 着色，保持背景透明。
/// 所有图标画在固定 16×16pt 画布上并居中：菜单的图标列按图片实际尺寸排布，
/// 各符号画布宽窄不一会让图标左右参差、文字缩进不齐。
func symbol(_ name: String, color: NSColor = .secondaryLabelColor,
            size: CGFloat = 13, weight: NSFont.Weight = .regular) -> NSImage? {
    let cfg = NSImage.SymbolConfiguration(pointSize: size, weight: weight)
    guard let base = NSImage(systemSymbolName: name, accessibilityDescription: nil) else { return nil }
    let src = base.withSymbolConfiguration(cfg) ?? base

    // 创建位图，固定 2x retina 尺寸保证菜单渲染稳定
    let scale: CGFloat = 2
    let cell: CGFloat = 16
    let px = Int(cell * scale)
    guard let bmp = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
        isPlanar: false, colorSpaceName: .deviceRGB,
        bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
    // NSBitmapImageRep 默认以像素作为逻辑尺寸；显式设为 point 尺寸，
    // 否则 2x Retina 位图会把 SF Symbol 显示成正常大小的一半。
    bmp.size = NSSize(width: cell, height: cell)
    let out = NSImage(size: NSSize(width: cell, height: cell))
    out.addRepresentation(bmp)

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bmp)

    // 宽符号（如 rectangle.on.rectangle）按比例缩小到画布内，再居中绘制。
    var glyph = src.size
    let maxGlyph: CGFloat = 15
    if glyph.width > maxGlyph || glyph.height > maxGlyph {
        let ratio = min(maxGlyph / glyph.width, maxGlyph / glyph.height)
        glyph.width = floor(glyph.width * ratio)
        glyph.height = floor(glyph.height * ratio)
    }
    let glyphRect = NSRect(
        x: floor((cell - glyph.width) / 2),
        y: floor((cell - glyph.height) / 2),
        width: glyph.width,
        height: glyph.height)

    // 先画符号建立透明蒙版，再把颜色 sourceAtop 到符号区域。
    // 若先填整张位图，透明背景也会保留下来，菜单中就会显示成色块。
    src.draw(in: glyphRect, from: .zero, operation: .sourceOver, fraction: 1.0)
    color.set()
    NSRect(origin: .zero, size: NSSize(width: cell, height: cell)).fill(using: .sourceAtop)

    NSGraphicsContext.restoreGraphicsState()
    out.isTemplate = false
    return out
}

// MARK: - 卡片背景：非液态玻璃系统（macOS 15 及以下）的回退材质
// macOS 26+ 由 AppKit 的 NSGlassEffectView 提供官方液态玻璃，不走这里

struct GlassCard: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(.ultraThinMaterial)
                    .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(Color.primary.opacity(0.12)))
                    .shadow(color: .black.opacity(0.4), radius: 16, y: 8)
            )
    }
}

/// bare=true 时背景由外层 NSGlassEffectView 提供，SwiftUI 不再画任何背景
struct ConditionalGlass: ViewModifier {
    let bare: Bool
    func body(content: Content) -> some View {
        if bare {
            content
        } else {
            content.modifier(GlassCard())
        }
    }
}

// MARK: - 可拖动的 HostingView：让 isMovableByWindowBackground 生效（原生拖动，零抖动）

final class DraggableHostingView<Content: View>: NSHostingView<Content> {
    override var mouseDownCanMoveWindow: Bool { true }

    // 右键菜单构建回调：由 AppDelegate 注入，读运行时置顶状态构建菜单。
    var contextMenuBuilder: (() -> NSMenu)?

    // AppKit 在右键派发早期调用本方法，覆盖整个 hosting view 区域，
    // 不受 SwiftUI .contextMenu 命中测试限制——空白处也能弹菜单。
    override func menu(for event: NSEvent) -> NSMenu? {
        contextMenuBuilder?()
    }
}
