import Cocoa
import CoreVideo
import SwiftUI

/// 高频状态留在原生脸部视图中，只更新两个眼睛图层，不触发 SwiftUI 布局。
struct BallTrackingFace: NSViewRepresentable {
    let reduceMotion: Bool

    func makeNSView(context: Context) -> BallMouseTrackingView {
        let view = BallMouseTrackingView()
        view.reduceMotion = reduceMotion
        return view
    }

    func updateNSView(_ view: BallMouseTrackingView, context: Context) {
        view.reduceMotion = reduceMotion
    }

    static func dismantleNSView(_ view: BallMouseTrackingView, coordinator: ()) { view.stop() }
}

/// 以真实指针活动延长跟随期，不能把“眼睛已接近目标”当作“鼠标已静止”。
struct BallPointerActivity {
    static let settlingTime: TimeInterval = 0.5
    private var position: CGPoint?
    private var activeUntil: TimeInterval = 0

    mutating func wake(at time: TimeInterval) { activeUntil = time + Self.settlingTime }

    mutating func observe(_ point: CGPoint, at time: TimeInterval) {
        if let position, hypot(point.x - position.x, point.y - position.y) > 0.001 { wake(at: time) }
        position = point
    }

    func isActive(at time: TimeInterval) -> Bool { time < activeUntil }
}

/// 只监听鼠标移动/拖动作为唤醒信号，再读取当前位置；不读取按键，不保存轨迹。
/// 鼠标事件监听无需辅助功能或录屏权限，隐藏时撤销；4Hz 位置探测仅作兜底。
final class BallMouseTrackingView: NSView {
    var onGaze: ((CGSize) -> Void)?
    var onBlink: ((CGFloat) -> Void)?
    var mouseLocation: () -> NSPoint = { NSEvent.mouseLocation }
    // 原生回归使用注入的位置与唤醒，不受用户在测试期间移动鼠标影响。
    var watchesPointerEvents = true
    var reduceMotion = false {
        didSet {
            guard reduceMotion != oldValue, canSample else { return }
            sample()
        }
    }

    private let eyes = [CALayer(), CALayer()]
    private var idleTimer: Timer?
    private var stopFrames: (() -> Void)?
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var visibilityObserver: NSObjectProtocol?
    private var screenObserver: NSObjectProtocol?
    private var visibilityObservation: NSKeyValueObservation?
    private var activity = BallPointerActivity()
    private var current = CGSize.zero
    private var nextBlink = TimeInterval.infinity
    private var blinkStart: TimeInterval?
    private var lastOpenness: CGFloat = 1
    private var lastSampleTime: TimeInterval?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        for eye in eyes {
            eye.backgroundColor = NSColor.white.cgColor
            layer?.addSublayer(eye)
        }
    }

    required init?(coder: NSCoder) { return nil }
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func layout() { super.layout(); drawEyes() }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        stop()
        guard let window else { return }
        visibilityObservation = window.observe(\.isVisible) { [weak self] _, _ in self?.updatePolling() }
        visibilityObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main
        ) { [weak self] _ in self?.updatePolling() }
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didChangeScreenNotification, object: window, queue: .main
        ) { [weak self] _ in
            self?.endFrames()
            self?.updatePolling()
        }
        updatePolling()
    }

    override func viewDidHide() { super.viewDidHide(); updatePolling() }
    override func viewDidUnhide() { super.viewDidUnhide(); updatePolling() }

    private var canSample: Bool {
        guard let window else { return false }
        return window.isVisible && window.occlusionState.contains(.visible) && !isHiddenOrHasHiddenAncestor
    }

    private func updatePolling() {
        guard canSample else { suspend(); return }
        guard idleTimer == nil, stopFrames == nil else { return }
        if !nextBlink.isFinite { nextBlink = CACurrentMediaTime() + Double.random(in: 2.5...5.5) }
        installPointerMonitors()
        sample()
    }

    private func installPointerMonitors() {
        guard watchesPointerEvents, localMonitor == nil else { return }
        let mask: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged]
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] _ in self?.pointerDidMove() }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            self?.pointerDidMove()
            return event
        }
    }

    /// 输入事件只唤醒一次；持续移动由显示时钟采样，不随鼠标报告率重复绘制。
    func pointerDidMove() {
        guard canSample else { return }
        activity.wake(at: CACurrentMediaTime())
        guard stopFrames == nil else { return }
        idleTimer?.invalidate()
        idleTimer = nil
        lastSampleTime = nil
        sample()
    }

    fileprivate func sample() {
        guard canSample else { suspend(); return }
        guard let window else { return }
        let now = CACurrentMediaTime()
        let cursor = mouseLocation()
        activity.observe(cursor, at: now)
        let local = convert(window.convertPoint(fromScreen: cursor), from: nil)
        let target = BallGazeGeometry.offset(cursor: local, center: CGPoint(x: bounds.midX, y: bounds.midY))
        // 静止唤醒采用一帧的步长；活动中的掉帧使用真实间隔追赶，不积压旧位置。
        let elapsed = stopFrames == nil ? 1 / 60 : max(0, now - (lastSampleTime ?? now))
        lastSampleTime = now
        let next = reduceMotion ? target : BallGazeGeometry.follow(current: current, target: target, elapsed: elapsed)
        let pending = hypot(target.width - next.width, target.height - next.height) > 0.01
        let gaze = pending ? next : target
        let openness = sampleBlink(at: now)
        let changed = gaze != current || openness != lastOpenness
        if gaze != current { current = gaze; onGaze?(gaze) }
        if openness != lastOpenness { lastOpenness = openness; onBlink?(openness) }
        if changed { drawEyes() }
        if pending || blinkStart != nil || activity.isActive(at: now) {
            startFrames()
        } else {
            endFrames()
            scheduleIdleSample(at: now)
        }
    }

    private func sampleBlink(at now: TimeInterval) -> CGFloat {
        if reduceMotion { blinkStart = nil; nextBlink = now + 3; return 1 }
        if blinkStart == nil, now >= nextBlink { blinkStart = now }
        guard let start = blinkStart else { return 1 }
        if now - start >= BallBlinkTiming.duration {
            blinkStart = nil
            nextBlink = now + Double.random(in: 3...6)
            return 1
        }
        return BallBlinkTiming.openness(elapsed: now - start)
    }

    private func drawEyes() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (index, eye) in eyes.enumerated() {
            let geometry = BallFaceGeometry.eye(side: index == 0 ? -1 : 1, gaze: current)
            let width = 5.8 * geometry.widthScale
            let height = max(1.4, 10.8 * lastOpenness * geometry.heightScale)
            eye.bounds = CGRect(x: 0, y: 0, width: width, height: height)
            eye.position = CGPoint(x: bounds.midX + geometry.center.x, y: bounds.midY + geometry.center.y)
            eye.cornerRadius = min(width, height) / 2
            eye.transform = CATransform3DMakeRotation(geometry.tilt, 0, 0, 1)
            eye.contentsScale = window?.backingScaleFactor ?? 2
        }
        CATransaction.commit()
    }

    private func startFrames() {
        guard stopFrames == nil else { return }
        idleTimer?.invalidate()
        idleTimer = nil
        if #available(macOS 14.0, *) {
            let target = BallDisplayLinkTarget(view: self)
            let link = displayLink(target: target, selector: #selector(BallDisplayLinkTarget.tick))
            link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)
            link.add(to: .main, forMode: .common)
            stopFrames = { link.invalidate() }
        } else if let clock = BallLegacyFrameClock(screen: window?.screen, tick: { [weak self] in self?.sample() }),
                  clock.start() {
            stopFrames = { clock.stop() }
        } else {
            // 显示时钟不可用时保留跟随；重复定时器避免逐次重新安排导致的时间漂移。
            let timer = Timer(timeInterval: 1 / 60, repeats: true) { [weak self] _ in self?.sample() }
            timer.tolerance = 0.001
            RunLoop.main.add(timer, forMode: .common)
            stopFrames = { timer.invalidate() }
        }
    }

    private func endFrames() {
        stopFrames?()
        stopFrames = nil
        lastSampleTime = nil
    }

    private func scheduleIdleSample(at now: TimeInterval) {
        idleTimer?.invalidate()
        let delay = min(0.25, max(1 / 60, nextBlink - now))
        let timer = Timer(timeInterval: delay, repeats: false) { [weak self] _ in
            self?.idleTimer = nil
            self?.sample()
        }
        timer.tolerance = 0.025
        idleTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func suspend() {
        idleTimer?.invalidate()
        idleTimer = nil
        endFrames()
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor); self.globalMonitor = nil }
        if let localMonitor { NSEvent.removeMonitor(localMonitor); self.localMonitor = nil }
        activity = BallPointerActivity()
        blinkStart = nil
        nextBlink = .infinity
    }

    func stop() {
        suspend()
        visibilityObservation = nil
        for observer in [visibilityObserver, screenObserver].compactMap({ $0 }) {
            NotificationCenter.default.removeObserver(observer)
        }
        visibilityObserver = nil
        screenObserver = nil
    }

    deinit { stop() }
}

@available(macOS 14.0, *)
private final class BallDisplayLinkTarget: NSObject {
    weak var view: BallMouseTrackingView?
    init(view: BallMouseTrackingView) { self.view = view }
    @objc func tick(_ link: CADisplayLink) { view?.sample() }
}

/// macOS 12/13 使用 Core Video 时钟。主线程繁忙时只保留一个待执行回调。
final class BallLegacyFrameClock {
    private var link: CVDisplayLink?
    private let lock = NSLock()
    private var running = false
    private var pending = false
    private var generation = 0
    private var nextFrame: TimeInterval = 0
    private let tick: () -> Void

    init?(screen: NSScreen?, tick: @escaping () -> Void) {
        self.tick = tick
        let number = screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
        guard CVDisplayLinkCreateWithCGDisplay(number?.uint32Value ?? CGMainDisplayID(), &link) == kCVReturnSuccess,
              let link else { return nil }
        let result = CVDisplayLinkSetOutputCallback(link, { _, _, _, _, _, context in
            guard let context else { return kCVReturnSuccess }
            Unmanaged<BallLegacyFrameClock>.fromOpaque(context).takeUnretainedValue().enqueue()
            return kCVReturnSuccess
        }, Unmanaged.passUnretained(self).toOpaque())
        guard result == kCVReturnSuccess else { return nil }
    }

    func start() -> Bool {
        guard let link else { return false }
        lock.lock()
        running = true
        nextFrame = 0
        lock.unlock()
        if CVDisplayLinkStart(link) == kCVReturnSuccess { return true }
        stop()
        return false
    }

    private func enqueue() {
        let now = CACurrentMediaTime()
        lock.lock()
        guard running, !pending, now + 0.001 >= nextFrame else { lock.unlock(); return }
        pending = true
        nextFrame = max(nextFrame, now) + 1 / 60
        let token = generation
        lock.unlock()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let deliver = self.running && self.generation == token
            if self.generation == token { self.pending = false }
            self.lock.unlock()
            if deliver { self.tick() }
        }
    }

    func stop() {
        lock.lock()
        running = false
        generation += 1
        pending = false
        lock.unlock()
        if let link, CVDisplayLinkIsRunning(link) { CVDisplayLinkStop(link) }
    }

    deinit { stop() }
}
