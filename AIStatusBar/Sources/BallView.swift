import Cocoa
import SwiftUI

enum FloatingBallAppearance: String, CaseIterable {
    case blue, ink

    var title: String {
        switch self {
        case .blue: return "晴蓝"
        case .ink: return "水墨"
        }
    }

    var isMonochrome: Bool { self == .ink }

    static func migrateRemovedAppearance(in defaults: UserDefaults = .standard) {
        if defaults.string(forKey: "floatingBallAppearance") == "white-ink" {
            defaults.set(Self.ink.rawValue, forKey: "floatingBallAppearance")
        }
    }
}

// 桌面卡片收起态：圆球 + 胶囊眼睛，支持晴蓝与水墨外观。
// 点击/拖动/右键/自动收起仍由原有 HostingView 与 AppDelegate 管理。
struct FloatingBallView: View {
    @ObservedObject var store: StatusStore
    let onToggle: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage("floatingBallAppearance") private var appearance = "blue"
    @AppStorage("lowEnergyMode") private var lowEnergyMode = false
    @State private var hovered = false
    @State private var celebratingSerial = 0

    private var liveMood: PetMood {
        PetMood.current(data: store.data, error: store.collectorError)
    }

    private var mood: PetMood {
        // 部分任务完成时，仍显示剩余运行数量与光晕。
        if case .working = liveMood { return liveMood }
        return celebratingSerial > 0 ? .celebrating : liveMood
    }

    var body: some View {
        FloatingBallStatusArtwork(mood: mood, state: bubbleState,
                                  hovered: hovered, reduceMotion: reduceMotion,
                                  appearance: FloatingBallAppearance(rawValue: appearance) ?? .blue,
                                  lowEnergyMode: lowEnergyMode, tracksPointer: true)
            .contentShape(Rectangle())
            .onTapGesture(perform: onToggle)
            .onHover { inside in
                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.16)) {
                    hovered = inside
                }
                // 不压入全局 cursor 栈，避免拖动/隐藏时漏掉 mouseExited 导致光标不恢复。
            }
            .onChange(of: store.completedEventSerial) { serial in
                guard serial > 0 else { return }
                celebratingSerial = serial
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                    if celebratingSerial == serial {
                        celebratingSerial = 0
                    }
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text("灵眸，\(bubbleState.accessibilitySummary)"))
            .accessibilityHint(Text("点击展开或收起看板；可拖动位置"))
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { onToggle() }
    }

    private var bubbleState: StatusBubbleState {
        StatusBubbleState(mood: liveMood, attentionCount: store.attentionEvents.count,
                          urgentAttentionCount: store.attentionEvents.filter { $0.phase != "ended" }.count,
                          completedCount: celebratingSerial > 0
                            ? store.attentionEvents.filter { $0.phase == "ended" }.count : 0)
    }
}

/// 固定窗口留足胶囊空间，状态改变时不移动球体或调整窗口。
struct FloatingBallStatusArtwork: View {
    /// 原球体与单计数胶囊的坐标保持不变，窗口只向右留出消息展开的空间。
    static let anchorSize = NSSize(width: 108, height: 78)
    static let messageExtension: CGFloat = 60
    static let size = NSSize(width: anchorSize.width + messageExtension, height: anchorSize.height)
    let mood: PetMood
    let state: StatusBubbleState
    var gaze = CGSize.zero
    var hovered = false
    var reduceMotion = false
    var eyeOpenness: CGFloat = 1
    var appearance: FloatingBallAppearance = .blue
    var lowEnergyMode = false
    var tracksPointer = false

    private var anchorState: StatusBubbleState {
        state.runningCount > 0 ? StatusBubbleState(mood: .working(taskCount: state.runningCount)) : state
    }

    var body: some View {
        FloatingBallArtwork(mood: mood, gaze: gaze, hovered: hovered,
                            reduceMotion: reduceMotion, eyeOpenness: eyeOpenness, appearance: appearance,
                            lowEnergyMode: lowEnergyMode, tracksPointer: tracksPointer)
            .frame(width: Self.anchorSize.width, height: Self.anchorSize.height, alignment: .bottom)
            .overlay(alignment: .topTrailing) {
                if state.isVisible(expanded: false) {
                    // 隐藏的单计数只定义锚点；可见胶囊对齐其左端，增加内容时向右生长。
                    StatusBubble(state: anchorState, style: .ball, monochrome: appearance.isMonochrome)
                        .hidden()
                        .accessibilityHidden(true)
                        .overlay(alignment: .leading) {
                            StatusBubble(state: state, style: .ball, monochrome: appearance.isMonochrome)
                        }
                        .padding(.top, 3)
                        .padding(.trailing, 4)
                        .allowsHitTesting(false)
                        .transition(.opacity)
                }
            }
            .frame(width: Self.size.width, height: Self.size.height, alignment: .leading)
    }
}

/// 纯视觉部分，可在不启动采集器的情况下做状态/方向快照。
struct FloatingBallArtwork: View {
    let mood: PetMood
    let gaze: CGSize
    let hovered: Bool
    let reduceMotion: Bool
    var eyeOpenness: CGFloat = 1
    var appearance: FloatingBallAppearance = .blue
    var lowEnergyMode = false
    var tracksPointer = false
    /// 导出动效预览时指定一帧，常规显示由原生动画层播放。
    var washFrame: CGImage? = nil

    private var palette: BallInkDrawing.Palette { appearance == .ink ? .ink : .blue }
    private var staticEffects: Bool { reduceMotion || lowEnergyMode }

    private var working: Bool {
        if case .working = mood { return true }
        return false
    }

    private var accent: Color {
        switch mood {
        case .error: return Color(red: 1, green: 0.48, blue: 0.43)
        case .celebrating: return Color(red: 0.39, green: 0.92, blue: 0.82)
        default: return Color(red: 0.38, green: 0.82, blue: 1)
        }
    }

    var body: some View {
        ZStack {
            if working {
                if appearance.isMonochrome {
                    BallInkOrbit(reduceMotion: staticEffects)
                        .id(staticEffects)
                } else {
                    BallOrbitGlow(color: accent, reduceMotion: staticEffects)
                        .id(staticEffects)
                }
            }

            ZStack {
                Group {
                    if let washFrame {
                        BallWashBody(image: washFrame, palette: palette)
                    } else if staticEffects {
                        BallWashBody(image: palette.still, palette: palette)
                    } else {
                        BallInkFlow(working: working, palette: palette, resting: mood == .sleeping)
                            .id(appearance)
                    }
                }
                .frame(width: 56, height: 56)

                if tracksPointer {
                    BallTrackingFace(reduceMotion: reduceMotion)
                } else {
                    BallFaceArtwork(gaze: gaze, eyeOpenness: eyeOpenness)
                }
            }
            .frame(width: 48, height: 48)
            .opacity(mood == .sleeping && !hovered ? 0.78 : 1)


        }
        .frame(width: 64, height: 64)
        .scaleEffect(hovered && !reduceMotion ? 1.035 : 1)
        .animation(staticEffects ? nil : .easeInOut(duration: 0.22), value: mood)
    }

}

/// 视线与眨眼只更新脸部，避免每一帧重建球体纹理、工作环和状态胶囊。
private struct BallTrackingFace: View {
    let reduceMotion: Bool
    @State private var gaze = CGSize.zero
    @State private var eyeOpenness: CGFloat = 1

    var body: some View {
        BallFaceArtwork(gaze: gaze, eyeOpenness: eyeOpenness)
            .background {
                BallMouseTracker(reduceMotion: reduceMotion,
                                 onGaze: { gaze = $0 }, onBlink: { eyeOpenness = $0 })
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

private struct BallFaceArtwork: View {
    let gaze: CGSize
    let eyeOpenness: CGFloat

    var body: some View {
        ZStack {
            // 将眼睛贴在球面上投影：远侧眼睛变窄，斜看时连线随头部转动。
            ForEach([-1, 1], id: \.self) { side in
                let eye = BallFaceGeometry.eye(side: side, gaze: gaze)
                Capsule()
                    .fill(.white)
                    .frame(width: 5.8 * eye.widthScale, height: max(1.4, 10.8 * eyeOpenness * eye.heightScale))
                    .rotationEffect(.radians(eye.tilt))
                    .offset(x: eye.center.x, y: eye.center.y)
            }
        }
        .frame(width: 48, height: 48)
    }
}

/// 纹理由 Swift 在内存中绘制，晕染收在固定圆形轮廓内，画布保留透明余量。
private struct BallWashBody: View {
    let image: CGImage?
    let palette: BallInkDrawing.Palette

    var body: some View {
        if let image {
            Image(decorative: image, scale: 1)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
        } else {
            Circle().fill(palette == .ink ? Color(white: 0.16) : Color(red: 0.18, green: 0.56, blue: 0.99))
        }
    }
}

private struct BallInkOrbit: View {
    let reduceMotion: Bool
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        BallOrbitRotation(duration: 3.6, reduceMotion: reduceMotion) { artwork }
            .frame(width: 58, height: 58)
            .allowsHitTesting(false)
    }

    private var artwork: some View {
        ZStack {
            ForEach(0..<3) { band in
                BallInkArc(band: band)
                    .fill(LinearGradient(
                        colors: [Color(white: 0.55).opacity(0.25),
                                 Color(white: colorScheme == .dark ? 0.82 : 0.18).opacity(0.75),
                                 Color(white: 0.45).opacity(0.45)],
                        startPoint: .topLeading, endPoint: .bottomTrailing))
                    .opacity(band == 0 ? 1 : 0.48)
            }
        }
        .frame(width: 58, height: 58)
    }
}

/// 不规则笔锋和分叉枯笔共用固定噪声场，转动时整笔旋转。
private struct BallInkArc: Shape {
    var band = 0

    func path(in rect: CGRect) -> Path {
        let unit = Double(min(rect.width, rect.height))
        var outer: [CGPoint] = []
        var inner: [CGPoint] = []
        let start = [-51.0, 110.0, 126.0][band]
        let sweep = [222.0, 51.0, 35.0][band]
        for step in 0...160 {
            let t = Double(step) / 160
            let angle = (start + t * sweep) * .pi / 180
            let nx = cos(angle), ny = sin(angle)
            let flow = BallInkDrawing.field(nx * 4 + 13, ny * 4 - 9)
            let bristle = BallInkDrawing.noise(t * 11, Double(band) + 19)
            let radius = unit * (0.454 + Double(band) * 0.012 + flow * 0.009)
            let pressure = pow(max(0, sin(t * .pi)), 1.3)
            let halfWidth = unit * (0.001 + (band == 0 ? 0.018 : 0.004) * pressure)
                * (0.70 + bristle * 0.50)
            outer.append(CGPoint(x: Double(rect.midX) + nx * (radius + halfWidth),
                                 y: Double(rect.midY) + ny * (radius + halfWidth)))
            inner.append(CGPoint(x: Double(rect.midX) + nx * (radius - halfWidth),
                                 y: Double(rect.midY) + ny * (radius - halfWidth)))
        }
        var path = Path()
        path.addLines(outer + inner.reversed())
        path.closeSubpath()
        return path
    }
}

/// 正交球面投影，加少量深度缩放。球体轮廓不压扁，脸部在球面上转动。
enum BallFaceGeometry {
    struct Eye {
        let center: CGPoint
        let widthScale: CGFloat
        let heightScale: CGFloat
        let tilt: Double
    }

    static func eye(side: Int, gaze: CGSize) -> Eye {
        let yaw = max(-1, min(1, gaze.width / 5)) * 0.68
        let pitch = max(-1, min(1, -gaze.height / 5)) * 0.55
        func project(_ x: CGFloat, _ y: CGFloat) -> (CGPoint, CGFloat) {
            let z = sqrt(max(0, 20 * 20 - x * x - y * y))
            let turnedX = x * cos(yaw) + z * sin(yaw)
            let turnedZ = z * cos(yaw) - x * sin(yaw)
            let turnedY = y * cos(pitch) - turnedZ * sin(pitch)
            let depth = y * sin(pitch) + turnedZ * cos(pitch)
            return (CGPoint(x: turnedX, y: turnedY), depth)
        }
        let x = CGFloat(side) * 6
        let y: CGFloat = -3.8
        let (center, depth) = project(x, y)
        let (across, _) = project(x + 1, y)
        let slant: CGFloat = 9 * .pi / 180
        let (down, _) = project(x - sin(slant), y + cos(slant))
        let perspective = (70 + depth) / 90
        return Eye(
            center: center,
            widthScale: max(0.5, hypot(across.x - center.x, across.y - center.y) * perspective),
            heightScale: max(0.6, hypot(down.x - center.x, down.y - center.y) * perspective),
            tilt: Double(atan2(center.x - down.x, down.y - center.y))
        )
    }
}

enum BallBlinkTiming {
    static let duration: TimeInterval = 0.245

    static func openness(elapsed: TimeInterval) -> CGFloat {
        func smooth(_ t: Double) -> CGFloat {
            let t = max(0, min(1, t))
            return CGFloat(t * t * (3 - 2 * t))
        }
        if elapsed < 0.08 { return 1 - smooth(elapsed / 0.08) }
        if elapsed < 0.105 { return 0 }
        return smooth((elapsed - 0.105) / 0.14)
    }
}

private struct BallOrbitGlow: View {
    let color: Color
    let reduceMotion: Bool

    var body: some View {
        BallOrbitRotation(duration: 2.8, reduceMotion: reduceMotion) { artwork }
            .frame(width: 54, height: 54)
            .allowsHitTesting(false)
    }

    private var artwork: some View {
        ZStack {
            ring(lineWidth: 5.2)
                .blur(radius: 2.4)
                .opacity(0.7)
            ring(lineWidth: 1.8)
                .opacity(0.95)
        }
        .frame(width: 54, height: 54)
    }

    private func ring(lineWidth: CGFloat) -> some View {
        Circle()
            .stroke(
                AngularGradient(
                    stops: [
                        .init(color: .clear, location: 0),
                        .init(color: color.opacity(0.08), location: 0.18),
                        .init(color: color.opacity(0.5), location: 0.48),
                        .init(color: .white.opacity(0.95), location: 0.68),
                        .init(color: color, location: 0.77),
                        .init(color: .clear, location: 0.94)
                    ],
                    center: .center
                ),
                lineWidth: lineWidth
            )
    }
}

/// 鼠标向量 -> 最大 5pt 的眼睛位移。远距离平滑饱和，不会越出球面。
enum BallGazeGeometry {
    /// 按经过的时间平滑收敛，帧率变化时保持相同的跟随速度。
    static func follow(current: CGSize, target: CGSize, elapsed: TimeInterval) -> CGSize {
        let fraction = CGFloat(1 - exp(-max(0, elapsed) / 0.11))
        return CGSize(width: current.width + (target.width - current.width) * fraction,
                      height: current.height + (target.height - current.height) * fraction)
    }

    static func offset(cursor: CGPoint, center: CGPoint) -> CGSize {
        let dx = cursor.x - center.x
        let dy = cursor.y - center.y
        let distance = hypot(dx, dy)
        guard distance > 0.001 else { return .zero }
        let magnitude = 5 * tanh(distance / 130)
        return CGSize(width: dx / distance * magnitude, height: dy / distance * magnitude)
    }
}

private struct BallMouseTracker: NSViewRepresentable {
    let reduceMotion: Bool
    let onGaze: (CGSize) -> Void
    let onBlink: (CGFloat) -> Void

    func makeNSView(context: Context) -> BallMouseTrackingView {
        let view = BallMouseTrackingView()
        view.onGaze = onGaze
        view.onBlink = onBlink
        view.reduceMotion = reduceMotion
        return view
    }

    func updateNSView(_ nsView: BallMouseTrackingView, context: Context) {
        nsView.onGaze = onGaze
        nsView.onBlink = onBlink
        nsView.reduceMotion = reduceMotion
    }

    static func dismantleNSView(_ nsView: BallMouseTrackingView, coordinator: ()) {
        nsView.stop()
    }
}

/// 只读取鼠标位置，不创建全局事件钩子，不申请辅助功能/录屏权限。
/// 视图没有 hitTest，不会吞掉 HostingView 的点击、右键和拖动。
final class BallMouseTrackingView: NSView {
    var onGaze: ((CGSize) -> Void)?
    var onBlink: ((CGFloat) -> Void)?
    var mouseLocation: () -> NSPoint = { NSEvent.mouseLocation }
    var reduceMotion = false
    private var timer: Timer?
    private var visibilityObserver: NSObjectProtocol?
    private var visibilityObservation: NSKeyValueObservation?
    private var current = CGSize.zero
    private var nextBlink = TimeInterval.infinity
    private var blinkStart: TimeInterval?
    private var lastOpenness: CGFloat = 1
    private var lastSampleTime: TimeInterval?

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        stop()
        guard let window else { return }
        visibilityObservation = window.observe(\.isVisible) { [weak self] _, _ in self?.updatePolling() }
        visibilityObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didChangeOcclusionStateNotification,
            object: window, queue: .main
        ) { [weak self] _ in self?.updatePolling() }
        updatePolling()
    }

    override func viewDidHide() {
        super.viewDidHide()
        updatePolling()
    }

    override func viewDidUnhide() {
        super.viewDidUnhide()
        updatePolling()
    }

    private func updatePolling() {
        guard let window, window.isVisible,
              window.occlusionState.contains(.visible),
              !isHiddenOrHasHiddenAncestor else {
            timer?.invalidate()
            timer = nil
            return
        }
        guard timer == nil else { return }
        blinkStart = nil
        nextBlink = ProcessInfo.processInfo.systemUptime + Double.random(in: 2.5...5.5)
        scheduleSample(after: 0)
    }

    /// 静止时保持 4Hz 探测；仅脸部移动与眨眼期间用 60fps，仍无需全局事件权限。
    private func scheduleSample(after delay: TimeInterval) {
        let timer = Timer(timeInterval: delay, repeats: false) { [weak self] _ in
            self?.timer = nil
            self?.sample()
        }
        timer.tolerance = delay >= 0.2 ? 0.025 : 0.001
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func sample() {
        guard let window, window.isVisible, window.occlusionState.contains(.visible),
              !isHiddenOrHasHiddenAncestor else {
            updatePolling()
            return
        }
        // 屏幕 -> 窗口 -> flipped 视图坐标，支持负坐标和不同缩放的多显示器。
        sampleBlink()
        let local = convert(window.convertPoint(fromScreen: mouseLocation()), from: nil)
        let target = BallGazeGeometry.offset(cursor: local, center: CGPoint(x: bounds.midX, y: bounds.midY))
        let now = ProcessInfo.processInfo.systemUptime
        // 静止后的首次采样不跨过整个间隔，避免直接跳到指针方向。
        let elapsed = min(1 / 30, lastSampleTime.map { now - $0 } ?? 1 / 60)
        lastSampleTime = now
        let next = reduceMotion ? target : BallGazeGeometry.follow(current: current, target: target, elapsed: elapsed)
        let moving = hypot(target.width - current.width, target.height - current.height) > 0.03
        if moving {
            current = next
            onGaze?(next)
        }
        let untilBlink = reduceMotion ? TimeInterval.infinity
            : max(1 / 60, nextBlink - now)
        let delay = !reduceMotion && (moving || blinkStart != nil) ? 1 / 60 : min(0.25, untilBlink)
        scheduleSample(after: delay)
    }

    private func sampleBlink() {
        let now = ProcessInfo.processInfo.systemUptime
        var openness: CGFloat = 1
        if reduceMotion {
            blinkStart = nil
            nextBlink = now + Double.random(in: 3...6)
        } else {
            if blinkStart == nil, now >= nextBlink { blinkStart = now }
            if let start = blinkStart {
                openness = BallBlinkTiming.openness(elapsed: now - start)
                if now - start >= BallBlinkTiming.duration {
                    blinkStart = nil
                    nextBlink = now + Double.random(in: 3...6)
                }
            }
        }
        if abs(openness - lastOpenness) > 0.001 {
            lastOpenness = openness
            onBlink?(openness)
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        lastSampleTime = nil
        visibilityObservation = nil
        if let visibilityObserver {
            NotificationCenter.default.removeObserver(visibilityObserver)
            self.visibilityObserver = nil
        }
    }

    deinit { stop() }
}
