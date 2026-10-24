import Cocoa
import SwiftUI

/// 低频确认原生动画实际前进；合成时钟停住时才启用有上限的逐帧兜底。
/// 停播/隐藏时撤销全部计时器。正常路径每秒检查一次，不逐帧触发 SwiftUI。
final class BallAnimationMonitor {
    private let effect: String
    private(set) var usesFallback = false
    private(set) var isRunning = false
    private var timer: Timer?
    private var lastSignature: UInt64?
    private var stalledSamples = 0

    init(effect: String) { self.effect = effect }

    func start(inspect: @escaping () -> UInt64?, draw: @escaping () -> Void) {
        guard timer == nil else { return }
        isRunning = true
        let timer = Timer(timeInterval: usesFallback ? 1 / 30 : 1, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            if self.usesFallback { draw(); return }
            let signature = inspect()
            // inspect 可能因隐藏/销毁而调用 stop，不能在同一回调里重新启动。
            guard self.timer === timer else { return }
            self.stalledSamples = signature == nil || signature == self.lastSignature
                ? self.stalledSamples + 1 : 0
            self.lastSignature = signature
            guard self.stalledSamples >= 2 else { return }
            self.stop()
            self.usesFallback = true
            NSLog("FloatingBall %@: native presentation stalled; using bounded playback", self.effect)
            draw()
            self.start(inspect: inspect, draw: draw)
        }
        timer.tolerance = usesFallback ? 0.004 : 0.1
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        isRunning = false
        lastSignature = nil
        stalledSamples = 0
    }

    deinit { stop() }
}

enum BallOrbitRole {
    case light, orbit
}

/// Keep the existing SwiftUI drawing static; only its native container rotates.
/// SwiftUI repeatForever otherwise keeps the hosting layout active on every frame.
struct BallOrbitRotation<Content: View>: View {
    let duration: TimeInterval
    let reduceMotion: Bool
    var resting = false
    var role: BallOrbitRole = .orbit
    @ViewBuilder let content: () -> Content

    var body: some View {
        if reduceMotion {
            content()
        } else {
            BallOrbitHost(content: content(), duration: duration, resting: resting, role: role)
        }
    }
}

private struct BallOrbitHost<Content: View>: NSViewRepresentable {
    let content: Content
    let duration: TimeInterval
    let resting: Bool
    let role: BallOrbitRole

    func makeNSView(context: Context) -> BallOrbitView {
        let hosted = NSHostingView(rootView: content)
        if #available(macOS 13.0, *) { hosted.sizingOptions = [] }
        return BallOrbitView(content: hosted, duration: duration, resting: resting, role: role)
    }

    func updateNSView(_ view: BallOrbitView, context: Context) {
        (view.content as? NSHostingView<Content>)?.rootView = content
        view.setDuration(duration)
        view.setResting(resting)
    }

    static func dismantleNSView(_ view: BallOrbitView, coordinator: ()) { view.stop() }
}

final class BallOrbitView: NSView {
    let content: NSView
    let role: BallOrbitRole
    private let rotor = NSView()
    private var clock: BallInkFlowClock
    private var resting: Bool
    private var visibilityObserver: NSObjectProtocol?
    private var visibilityObservation: NSKeyValueObservation?
    private var animationSize = CGSize.zero
    private var attached = false
    let playbackMonitor: BallAnimationMonitor

    var animationKey: String { role == .light ? "ball-light" : "ball-orbit" }

    init(content: NSView, duration: TimeInterval, resting: Bool = false, role: BallOrbitRole = .orbit) {
        self.content = content
        self.role = role
        self.resting = resting
        clock = BallInkFlowClock(duration: duration)
        playbackMonitor = BallAnimationMonitor(effect: role == .light ? "light" : "orbit")
        super.init(frame: .zero)
        wantsLayer = true
        rotor.wantsLayer = true
        rotor.layer = CALayer()
        addSubview(rotor)
        rotor.addSubview(content)
    }

    required init?(coder: NSCoder) { return nil }
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        rotor.frame = bounds
        content.frame = rotor.bounds
        CATransaction.commit()
        updatePlayback()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        stop()
        guard let window else { return }
        attached = true
        // 跨空间悬浮窗 orderOut 后遮挡标记可能暂时不变，直接跟踪可见性以立即停播。
        visibilityObservation = window.observe(\.isVisible) { [weak self] _, _ in self?.updatePlayback() }
        visibilityObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main
        ) { [weak self] _ in self?.updatePlayback() }
        updatePlayback()
    }

    override func viewDidHide() { super.viewDidHide(); updatePlayback() }
    override func viewDidUnhide() { super.viewDidUnhide(); updatePlayback() }

    func setDuration(_ value: TimeInterval) {
        guard value != clock.duration else { return }
        clock.setDuration(value, at: CACurrentMediaTime())
        animationSize = .zero
        updatePlayback()
    }

    func setResting(_ value: Bool) {
        guard resting != value else { return }
        resting = value
        updatePlayback()
    }

    private func updatePlayback() {
        guard canPlay else { pause(); return }
        guard bounds.width > 0, bounds.height > 0, let layer = rotor.layer else { return }
        let now = CACurrentMediaTime()
        clock.resume(at: now)
        playbackMonitor.start(inspect: { [weak self] in
            guard let self else { return nil }
            self.updatePlayback()
            guard let transform = self.rotor.layer?.presentation()?.transform else { return nil }
            return Double(transform.m11).bitPattern ^ Double(transform.m12).bitPattern
        }, draw: { [weak self] in self?.drawFallback() })
        if playbackMonitor.usesFallback { drawFallback(); return }
        guard layer.animation(forKey: animationKey) == nil || animationSize != bounds.size else { return }
        // AppKit owns backing-layer anchorPoint (0,0), so changing it is undone
        // on the next layout. Rotate around the center in the transform itself.
        let animation = CAKeyframeAnimation(keyPath: "transform")
        animation.values = (0...120).map { frame in
            NSValue(caTransform3D: rotation(phase: Double(frame) / 120))
        }
        animation.calculationMode = .linear
        animation.duration = clock.duration
        animation.repeatCount = .infinity
        animation.beginTime = layer.convertTime(now, from: nil) - clock.phase(at: now) * clock.duration
        layer.add(animation, forKey: animationKey)
        animationSize = bounds.size
    }

    private func rotation(phase: Double) -> CATransform3D {
        var transform = CATransform3DMakeTranslation(bounds.midX, bounds.midY, 0)
        transform = CATransform3DRotate(transform, phase * .pi * 2, 0, 0, 1)
        return CATransform3DTranslate(transform, -bounds.midX, -bounds.midY, 0)
    }

    private var canPlay: Bool {
        guard attached, let window, !resting else { return false }
        return window.isVisible && window.occlusionState.contains(.visible) && !isHiddenOrHasHiddenAncestor
    }

    private func drawFallback() {
        guard canPlay else { pause(); return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        rotor.layer?.removeAnimation(forKey: animationKey)
        rotor.layer?.transform = rotation(phase: clock.phase(at: CACurrentMediaTime()))
        CATransaction.commit()
    }

    private func pause() {
        playbackMonitor.stop()
        clock.pause(at: CACurrentMediaTime())
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        rotor.layer?.transform = rotation(phase: clock.phase(at: CACurrentMediaTime()))
        rotor.layer?.removeAnimation(forKey: animationKey)
        CATransaction.commit()
    }

    func stop() {
        attached = false
        pause()
        visibilityObservation = nil
        if let visibilityObserver {
            NotificationCenter.default.removeObserver(visibilityObserver)
            self.visibilityObserver = nil
        }
    }

    deinit { stop() }
}

/// 静态主体与柔光共用同一布局；预览相位只用于离线导出，不参与常规播放。
struct BallInkFlow: View {
    let working: Bool
    var palette: BallInkDrawing.Palette = .ink
    var resting = false
    var previewPhase: Double? = nil

    var body: some View {
        ZStack {
            if let image = palette.still {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
            } else {
                Circle().fill(palette == .ink ? Color(white: 0.16) : Color(red: 0.18, green: 0.56, blue: 0.99))
            }
            if let previewPhase {
                BallLightSweep(palette: palette)
                    .rotationEffect(.degrees(previewPhase * 360))
            } else {
                BallOrbitRotation(duration: palette.flowDuration(working: working),
                                  reduceMotion: false, resting: resting, role: .light) {
                    BallLightSweep(palette: palette)
                }
            }
        }
        .clipShape(Circle())
    }
}

private struct BallLightSweep: View {
    let palette: BallInkDrawing.Palette

    var body: some View {
        Circle()
            .stroke(
                AngularGradient(
                    stops: [
                        .init(color: .clear, location: 0),
                        .init(color: .clear, location: 0.46),
                        .init(color: .white.opacity(palette == .blue ? 0.08 : 0.04), location: 0.56),
                        .init(color: .white.opacity(palette == .blue ? 0.38 : 0.24), location: 0.70),
                        .init(color: .white.opacity(palette == .blue ? 0.08 : 0.04), location: 0.82),
                        .init(color: .clear, location: 0.92)
                    ],
                    center: .center
                ),
                lineWidth: 6
            )
            .blur(radius: 1.6)
            .padding(4)
            .frame(width: 56, height: 56)
            .clipShape(Circle())
    }
}

/// 用单调时钟保持首尾循环、速度变化与暂停恢复连续。
struct BallInkFlowClock {
    private(set) var duration: TimeInterval
    private(set) var playing = false
    private var anchorPhase = 0.0
    private var anchorTime: TimeInterval = 0

    init(duration: TimeInterval) { self.duration = max(1, duration) }

    func phase(at time: TimeInterval) -> Double {
        let phase = anchorPhase + (playing ? max(0, time - anchorTime) / duration : 0)
        return phase.truncatingRemainder(dividingBy: 1)
    }

    mutating func setDuration(_ value: TimeInterval, at time: TimeInterval) {
        anchorPhase = phase(at: time)
        anchorTime = time
        duration = max(1, value)
    }

    mutating func pause(at time: TimeInterval) {
        anchorPhase = phase(at: time)
        anchorTime = time
        playing = false
    }

    mutating func resume(at time: TimeInterval) {
        guard !playing else { return }
        anchorTime = time
        playing = true
    }
}
