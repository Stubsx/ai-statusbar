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

/// Keep the existing SwiftUI drawing static; only its native container rotates.
/// SwiftUI repeatForever otherwise keeps the hosting layout active on every frame.
struct BallOrbitRotation<Content: View>: View {
    let duration: TimeInterval
    let reduceMotion: Bool
    @ViewBuilder let content: () -> Content

    var body: some View {
        if reduceMotion {
            content()
        } else {
            BallOrbitHost(content: content(), duration: duration)
        }
    }
}

private struct BallOrbitHost<Content: View>: NSViewRepresentable {
    let content: Content
    let duration: TimeInterval

    func makeNSView(context: Context) -> BallOrbitView {
        let hosted = NSHostingView(rootView: content)
        if #available(macOS 13.0, *) { hosted.sizingOptions = [] }
        return BallOrbitView(content: hosted, duration: duration)
    }

    func updateNSView(_ view: BallOrbitView, context: Context) {
        (view.content as? NSHostingView<Content>)?.rootView = content
    }

    static func dismantleNSView(_ view: BallOrbitView, coordinator: ()) { view.stop() }
}

final class BallOrbitView: NSView {
    let content: NSView
    private let rotor = NSView()
    private var clock: BallInkFlowClock
    private var visibilityObserver: NSObjectProtocol?
    private var visibilityObservation: NSKeyValueObservation?
    private var animationSize = CGSize.zero
    private var attached = false
    let playbackMonitor = BallAnimationMonitor(effect: "orbit")

    init(content: NSView, duration: TimeInterval) {
        self.content = content
        clock = BallInkFlowClock(duration: duration)
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
        guard layer.animation(forKey: "ball-orbit") == nil || animationSize != bounds.size else { return }
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
        layer.add(animation, forKey: "ball-orbit")
        animationSize = bounds.size
    }

    private func rotation(phase: Double) -> CATransform3D {
        var transform = CATransform3DMakeTranslation(bounds.midX, bounds.midY, 0)
        transform = CATransform3DRotate(transform, phase * .pi * 2, 0, 0, 1)
        return CATransform3DTranslate(transform, -bounds.midX, -bounds.midY, 0)
    }

    private var canPlay: Bool {
        guard attached, let window else { return false }
        return window.isVisible && window.occlusionState.contains(.visible) && !isHiddenOrHasHiddenAncestor
    }

    private func drawFallback() {
        guard canPlay else { pause(); return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        rotor.layer?.removeAnimation(forKey: "ball-orbit")
        rotor.layer?.transform = rotation(phase: clock.phase(at: CACurrentMediaTime()))
        CATransaction.commit()
    }

    private func pause() {
        playbackMonitor.stop()
        clock.pause(at: CACurrentMediaTime())
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        rotor.layer?.transform = rotation(phase: clock.phase(at: CACurrentMediaTime()))
        rotor.layer?.removeAnimation(forKey: "ball-orbit")
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

/// 原生层播放程序生成的墨层帧，不通过 SwiftUI 时间线逐帧触发布局。
struct BallInkFlow: NSViewRepresentable {
    let working: Bool
    var palette: BallInkDrawing.Palette = .ink
    var resting = false

    func makeNSView(context: Context) -> BallInkFlowView {
        BallInkFlowView(working: working, palette: palette, resting: resting)
    }

    func updateNSView(_ view: BallInkFlowView, context: Context) {
        view.setWorking(working)
        view.setResting(resting)
    }

    static func dismantleNSView(_ view: BallInkFlowView, coordinator: ()) {
        view.stop()
    }
}

/// 由系统合成缓存帧，色层自然流动，不响应指针扰动。
final class BallInkFlowView: NSView {
    private let palette: BallInkDrawing.Palette
    private let paint = CALayer()
    private var frames: [CGImage] = []
    private var loading = false
    private var visibilityObserver: NSObjectProtocol?
    private var visibilityObservation: NSKeyValueObservation?
    private var clock: BallInkFlowClock
    private var resting: Bool
    private var attached = false
    let playbackMonitor = BallAnimationMonitor(effect: "flow")

    init(working: Bool, palette: BallInkDrawing.Palette = .ink, resting: Bool = false) {
        self.palette = palette
        self.resting = resting
        clock = BallInkFlowClock(duration: palette.flowDuration(working: working))
        super.init(frame: .zero)
        wantsLayer = true
        layer = CALayer()
        paint.contents = palette.still
        paint.contentsGravity = .resizeAspect
        paint.minificationFilter = .linear
        paint.magnificationFilter = .linear
        layer?.addSublayer(paint)
    }

    required init?(coder: NSCoder) { return nil }
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        paint.frame = bounds
        CATransaction.commit()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        stop()
        guard let window else { return }
        attached = true
        visibilityObservation = window.observe(\.isVisible) { [weak self] _, _ in self?.updatePlayback() }
        visibilityObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didChangeOcclusionStateNotification,
            object: window, queue: .main
        ) { [weak self] _ in self?.updatePlayback() }
        updatePlayback()
    }

    override func viewDidHide() { super.viewDidHide(); updatePlayback() }
    override func viewDidUnhide() { super.viewDidUnhide(); updatePlayback() }

    func setWorking(_ working: Bool) {
        let duration = palette.flowDuration(working: working)
        guard duration != clock.duration else { return }
        clock.setDuration(duration, at: CACurrentMediaTime())
        if clock.playing {
            if playbackMonitor.usesFallback { drawFallback() } else { installAnimation() }
        }
    }

    func setResting(_ value: Bool) {
        guard resting != value else { return }
        resting = value
        updatePlayback()
    }

    private var canPlay: Bool {
        guard attached, let window else { return false }
        return window.isVisible && window.occlusionState.contains(.visible) && !isHiddenOrHasHiddenAncestor
    }

    private func updatePlayback() {
        guard canPlay else {
            pause()
            return
        }
        if resting {
            playbackMonitor.stop()
            clock.pause(at: CACurrentMediaTime())
            showBaseFrame()
            return
        }
        guard !frames.isEmpty else {
            prepareFrames()
            return
        }
        if !clock.playing { clock.resume(at: CACurrentMediaTime()) }
        playbackMonitor.start(inspect: { [weak self] in
            guard let self else { return nil }
            self.updatePlayback()
            return self.presentationSignature()
        }, draw: { [weak self] in self?.drawFallback() })
        if playbackMonitor.usesFallback { drawFallback(); return }
        if paint.animation(forKey: "ink-flow") == nil { installAnimation() }
    }

    private func prepareFrames() {
        guard !loading else { return }
        loading = true
        let palette = self.palette
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let startup = palette.startupFrames
            DispatchQueue.main.async { [weak self] in self?.acceptFrames(startup, final: false) }
            let frames = palette.frames
            DispatchQueue.main.async { [weak self] in self?.acceptFrames(frames, final: true) }
        }
    }

    private func acceptFrames(_ frames: [CGImage], final: Bool) {
        if final { loading = false }
        guard !frames.isEmpty else { return }
        self.frames = frames
        paint.removeAnimation(forKey: "ink-flow")
        // 替换缓存不重置相位；隐藏/销毁期间完成的后台任务不能重新开播。
        updatePlayback()
    }

    private func presentationSignature() -> UInt64? {
        guard let contents = paint.presentation()?.contents,
              let data = (contents as! CGImage).dataProvider?.data,
              let bytes = CFDataGetBytePtr(data) else { return nil }
        let count = CFDataGetLength(data)
        guard count > 0 else { return nil }
        var hash: UInt64 = 14695981039346656037
        // 分散取样内部颜色，无需复制/遍历整帧像素。
        for index in stride(from: 0, to: count, by: max(1, count / 257)) {
            hash = (hash ^ UInt64(bytes[index])) &* 1099511628211
        }
        return hash
    }

    private func drawFallback() {
        guard canPlay, !resting else { pause(); return }
        showBaseFrame()
    }

    private func installAnimation() {
        guard let first = frames.first else { return }
        let now = CACurrentMediaTime()
        let phase = clock.phase(at: now)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        paint.contents = frames[min(frames.count - 1, Int(phase * Double(frames.count)))]
        let animation = CAKeyframeAnimation(keyPath: "contents")
        animation.values = frames + [first]
        animation.keyTimes = (0...frames.count).map { NSNumber(value: Double($0) / Double(frames.count)) }
        animation.calculationMode = .discrete
        animation.duration = clock.duration
        animation.repeatCount = .infinity
        animation.beginTime = paint.convertTime(now, from: nil) - phase * clock.duration
        paint.add(animation, forKey: "ink-flow")
        CATransaction.commit()
    }

    private func pause() {
        playbackMonitor.stop()
        let now = CACurrentMediaTime()
        clock.pause(at: now)
        showBaseFrame()
    }

    private func currentFrame(at time: TimeInterval) -> CGImage? {
        guard !frames.isEmpty else { return palette.still }
        return frames[min(frames.count - 1, Int(clock.phase(at: time) * Double(frames.count)))]
    }

    private func showBaseFrame() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        paint.contents = currentFrame(at: CACurrentMediaTime())
        paint.removeAnimation(forKey: "ink-flow")
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
