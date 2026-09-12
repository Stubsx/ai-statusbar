import Cocoa
import SwiftUI

// 桌面卡片收起态：蓝色球体 + 白色胶囊眼睛 + 工作时旋转的柔光环。
// 点击/拖动/右键/自动收起仍由原有 HostingView 与 AppDelegate 管理。
struct FloatingBallView: View {
    @ObservedObject var store: StatusStore
    let onToggle: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovered = false
    @State private var gaze = CGSize.zero
    @State private var eyeOpenness: CGFloat = 1
    @State private var celebratingSerial = 0
    @State private var celebratingCount = 0

    private var liveMood: PetMood {
        PetMood.current(data: store.data, error: store.collectorError)
    }

    private var mood: PetMood {
        // 部分任务完成时，仍显示剩余运行数量与光晕。
        if case .working = liveMood { return liveMood }
        return celebratingSerial > 0 ? .celebrating : liveMood
    }

    var body: some View {
        FloatingBallStatusArtwork(mood: mood, state: bubbleState, gaze: gaze,
                                  hovered: hovered, reduceMotion: reduceMotion, eyeOpenness: eyeOpenness)
            .background(alignment: .bottomLeading) {
                BallMouseTracker(reduceMotion: reduceMotion, onGaze: { gaze = $0 }, onBlink: { eyeOpenness = $0 })
                    .frame(width: 64, height: 64)
                    .frame(width: FloatingBallStatusArtwork.anchorSize.width,
                           height: FloatingBallStatusArtwork.anchorSize.height, alignment: .bottom)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
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
                celebratingCount = store.completedEventCount
                celebratingSerial = serial
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                    if celebratingSerial == serial {
                        celebratingSerial = 0
                        celebratingCount = 0
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
                          completedCount: celebratingCount)
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

    private var anchorState: StatusBubbleState {
        state.runningCount > 0 ? StatusBubbleState(mood: .working(taskCount: state.runningCount)) : state
    }

    var body: some View {
        FloatingBallArtwork(mood: mood, gaze: gaze, hovered: hovered,
                            reduceMotion: reduceMotion, eyeOpenness: eyeOpenness)
            .frame(width: Self.anchorSize.width, height: Self.anchorSize.height, alignment: .bottom)
            .overlay(alignment: .topTrailing) {
                if state.isVisible(expanded: false) {
                    // 隐藏的单计数只定义锚点；可见胶囊对齐其左端，增加内容时向右生长。
                    StatusBubble(state: anchorState, style: .ball)
                        .hidden()
                        .accessibilityHidden(true)
                        .overlay(alignment: .leading) {
                            StatusBubble(state: state, style: .ball)
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
            // 透明的淡青外圈，而不是高对比硬边或黑色投影。
            Circle()
                .fill(accent.opacity(hovered ? 0.20 : 0.12))
                .frame(width: 55, height: 55)

            if working {
                BallOrbitGlow(color: accent, reduceMotion: reduceMotion)
                    .id(reduceMotion)
            }

            ZStack {
                Circle()
                    .fill(
                        RadialGradient(
                            stops: [
                                // 明亮天蓝主色 + 浅蓝边缘反光，避免深钴蓝阴影。
                                .init(color: Color(red: 0.32, green: 0.64, blue: 1), location: 0),
                                .init(color: Color(red: 0.18, green: 0.56, blue: 1), location: 0.45),
                                .init(color: Color(red: 0.17, green: 0.54, blue: 0.99), location: 0.72),
                                .init(color: Color(red: 0.44, green: 0.71, blue: 1), location: 1)
                            ],
                            center: UnitPoint(x: 0.35 + gaze.width * 0.018, y: 0.29 + gaze.height * 0.018),
                            startRadius: 0, endRadius: 37
                        )
                    )
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [.white.opacity(0.13), .clear],
                            center: UnitPoint(x: 0.28 + gaze.width * 0.025, y: 0.20 + gaze.height * 0.025),
                            startRadius: 0, endRadius: 30
                        )
                    )
                Circle()
                    .strokeBorder(.white.opacity(0.22), lineWidth: 0.8)

                // 将眼睛贴在球面上投影：远侧眼睛变窄、眼距压缩，斜看时连线随头部转动。
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
            .shadow(color: Color(red: 0.38, green: 0.68, blue: 1).opacity(0.08), radius: 2, y: 1)
            .opacity(mood == .sleeping && !hovered ? 0.78 : 1)


        }
        .frame(width: 64, height: 64)
        .scaleEffect(hovered && !reduceMotion ? 1.035 : 1)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.22), value: mood)
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
    @State private var turning = false

    var body: some View {
        ZStack {
            ring(lineWidth: 5.2)
                .blur(radius: 2.4)
                .opacity(0.7)
            ring(lineWidth: 1.8)
                .opacity(0.95)
        }
        .frame(width: 54, height: 54)
        .rotationEffect(.degrees(turning && !reduceMotion ? 360 : 0))
        .onAppear { turning = true }
        .animation(
            reduceMotion ? nil : .linear(duration: 2.8).repeatForever(autoreverses: false),
            value: turning
        )
        .allowsHitTesting(false)
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
    var reduceMotion = false
    private var timer: Timer?
    private var visibilityObserver: NSObjectProtocol?
    private var current = CGSize.zero
    private var nextBlink = TimeInterval.infinity
    private var blinkStart: TimeInterval?
    private var lastOpenness: CGFloat = 1

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        stop()
        guard let window else { return }
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
        let timer = Timer(timeInterval: 1 / 30, repeats: true) { [weak self] _ in self?.sample() }
        timer.tolerance = 0.008
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func sample() {
        guard let window, window.isVisible, !isHiddenOrHasHiddenAncestor else {
            updatePolling()
            return
        }
        // 屏幕 -> 窗口 -> flipped 视图坐标，支持负坐标和不同缩放的多显示器。
        sampleBlink()
        let local = convert(window.convertPoint(fromScreen: NSEvent.mouseLocation), from: nil)
        let target = BallGazeGeometry.offset(cursor: local, center: CGPoint(x: bounds.midX, y: bounds.midY))
        let follow: CGFloat = reduceMotion ? 1 : 0.26
        let next = CGSize(
            width: current.width + (target.width - current.width) * follow,
            height: current.height + (target.height - current.height) * follow
        )
        guard hypot(next.width - current.width, next.height - current.height) > 0.008 else { return }
        current = next
        onGaze?(next)
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
        if let visibilityObserver {
            NotificationCenter.default.removeObserver(visibilityObserver)
            self.visibilityObserver = nil
        }
    }

    deinit { stop() }
}
