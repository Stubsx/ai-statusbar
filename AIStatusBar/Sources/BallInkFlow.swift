import Cocoa
import SwiftUI

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
    private var animationSize = CGSize.zero

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
        visibilityObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main
        ) { [weak self] _ in self?.updatePlayback() }
        updatePlayback()
    }

    override func viewDidHide() { super.viewDidHide(); updatePlayback() }
    override func viewDidUnhide() { super.viewDidUnhide(); updatePlayback() }

    private func updatePlayback() {
        guard let window, window.isVisible, window.occlusionState.contains(.visible),
              !isHiddenOrHasHiddenAncestor else { pause(); return }
        guard bounds.width > 0, bounds.height > 0, let layer = rotor.layer else { return }
        guard layer.animation(forKey: "ball-orbit") == nil || animationSize != bounds.size else { return }
        let now = CACurrentMediaTime()
        clock.resume(at: now)
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

    private func pause() {
        clock.pause(at: CACurrentMediaTime())
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        rotor.layer?.transform = rotation(phase: clock.phase(at: CACurrentMediaTime()))
        rotor.layer?.removeAnimation(forKey: "ball-orbit")
        CATransaction.commit()
    }

    func stop() {
        pause()
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
    private var clock: BallInkFlowClock
    private var resting: Bool

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
        if clock.playing { installAnimation() }
    }

    func setResting(_ value: Bool) {
        guard resting != value else { return }
        resting = value
        updatePlayback()
    }

    private var canPlay: Bool {
        guard let window else { return false }
        return window.isVisible && window.occlusionState.contains(.visible) && !isHiddenOrHasHiddenAncestor
    }

    private func updatePlayback() {
        guard canPlay else {
            pause()
            return
        }
        if resting {
            clock.pause(at: CACurrentMediaTime())
            showBaseFrame()
            return
        }
        guard !frames.isEmpty else {
            prepareFrames()
            return
        }
        if !clock.playing { clock.resume(at: CACurrentMediaTime()) }
        if paint.animation(forKey: "ink-flow") == nil { installAnimation() }
    }

    private func prepareFrames() {
        guard !loading else { return }
        loading = true
        let palette = self.palette
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let frames = palette.frames
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.frames = frames
                if !frames.isEmpty { self.updatePlayback() }
            }
        }
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
        pause()
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
