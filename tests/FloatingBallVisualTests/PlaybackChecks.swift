import Cocoa
import SwiftUI

/// 用真正的 NSApplication 事件循环检查播放层；离线 ImageRenderer 不能验证动画是否启动。
@MainActor
private final class FloatingBallPlaybackDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        guard let screen = NSScreen.main else { fail("No display available for native playback check") }
        func artwork(_ appearance: FloatingBallAppearance, reduceMotion: Bool = false,
                     sleeping: Bool = false, hovered: Bool = false,
                     lowEnergyMode: Bool = false) -> FloatingBallStatusArtwork {
            let mood: PetMood = sleeping ? .sleeping : .working(taskCount: 2)
            return FloatingBallStatusArtwork(mood: mood,
                state: StatusBubbleState(mood: mood),
                hovered: hovered, reduceMotion: reduceMotion, appearance: appearance,
                lowEnergyMode: lowEnergyMode, tracksPointer: true)
        }
        let hosted = NSHostingView(rootView: artwork(.blue, lowEnergyMode: true))
        hosted.wantsLayer = true
        hosted.layer?.backgroundColor = NSColor.clear.cgColor
        hosted.sizingOptions = []
        let size = FloatingBallStatusArtwork.size
        let window = NSPanel(contentRect: NSRect(
            x: screen.visibleFrame.maxX - size.width - 24,
            y: screen.visibleFrame.maxY - size.height - 24,
            width: size.width, height: size.height),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.level = .floating
        window.hidesOnDeactivate = false
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.contentView = hosted
        window.orderFront(nil)

        var stage = -1
        var hashes = Set<UInt64>()
        var angles = Set<Int>()
        var restingFrame: Data?
        var lowEnergyTracker: BallMouseTrackingView?
        let deadline = Date().addingTimeInterval(35)
        Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { timer in
            MainActor.assumeIsolated {
                let native = self.flowView(in: hosted)
                let paint = native?.layer?.sublayers?.first
                let animation = paint?.animation(forKey: "ink-flow")
                let displayedWidth = paint?.contents.map { ($0 as! CGImage).width }
                let orbit = self.orbitView(in: hosted)
                let rotor = orbit?.subviews.first?.layer
                guard Date() < deadline else {
                    self.fail("Native playback timed out at stage \(stage): flow=\(native != nil), "
                        + "animation=\(animation != nil), presentation=\(paint?.presentation()?.contents != nil), "
                        + "frames=\(hashes.count), angles=\(angles.count), visible=\(window.occlusionState.contains(.visible))")
                }
                switch stage {
                case -1:
                    guard native == nil, orbit == nil else { self.fail("Low-energy startup created animation views") }
                    print("PASS: low-energy startup skips flow and orbit playback")
                    hosted.rootView = artwork(.blue)
                    stage = 0
                case 0, 2, 3, 5, 11:
                    guard animation != nil,
                          let contents = paint?.presentation()?.contents else { return }
                    guard rotor?.animation(forKey: "ball-orbit") != nil,
                          let transform = rotor?.presentation()?.transform else {
                        self.fail("Working orbit must animate in its native layer")
                    }
                    angles.insert(Int(atan2(transform.m12, transform.m11) * 1_000))
                    guard orbit?.hitTest(.zero) == nil,
                          let bounds = rotor?.bounds,
                          abs(bounds.midX * transform.m11 + bounds.midY * transform.m21 + transform.m41 - bounds.midX) < 0.5,
                          abs(bounds.midX * transform.m12 + bounds.midY * transform.m22 + transform.m42 - bounds.midY) < 0.5 else {
                        self.fail("Orbit must rotate around its center and pass pointer input through")
                    }
                    let expectedDuration = (stage == 3 ? BallInkDrawing.Palette.ink : .blue).flowDuration(working: true)
                    guard animation?.duration == expectedDuration else { self.fail("Wrong palette playback speed") }
                    let image = contents as! CGImage
                    guard let data = image.dataProvider?.data else { self.fail("Missing presentation frame") }
                    let bytes = data as Data
                    let center = image.height / 2 * image.bytesPerRow + image.width / 2 * 4
                    if stage == 3 {
                        guard bytes[center] == bytes[center + 2] else { self.fail("Blue frames leaked into ink") }
                    } else {
                        guard bytes[center + 2] > bytes[center] else { self.fail("Blue playback used the wrong palette") }
                    }
                    var hash: UInt64 = 14695981039346656037
                    for byte in bytes { hash = (hash ^ UInt64(byte)) &* 1099511628211 }
                    hashes.insert(hash)
                    guard hashes.count >= 3, angles.count >= 3 else { return }
                    hashes.removeAll()
                    angles.removeAll()
                    if stage == 0 {
                        guard displayedWidth == 160 else { return }
                        print("PASS: transparent floating panel presents changing blue frames")
                        hosted.rootView = artwork(.blue, hovered: true)
                        stage = 5
                    } else if stage == 5 {
                        guard displayedWidth == 160, native?.hitTest(.zero) == nil else {
                            self.fail("Hover must preserve cached playback and pointer passthrough")
                        }
                        print("PASS: hover keeps the natural flow without pointer distortion")
                        window.orderOut(nil)
                        stage = 1
                    } else if stage == 2 {
                        print("PASS: hidden panel resumes changing frames")
                        hosted.rootView = artwork(.ink)
                        stage = 3
                    } else if stage == 3 {
                        print("PASS: appearance switch presents changing ink frames")
                        hosted.rootView = artwork(.ink, sleeping: true)
                        stage = 7
                    } else {
                        print("PASS: disabling low-energy mode restores native playback")
                        hosted.rootView = artwork(.ink, reduceMotion: true)
                        stage = 4
                    }
                case 1:
                    guard animation == nil else {
                        self.fail("Hidden panel kept playing: visible=\(window.isVisible), "
                            + "occluded=\(!window.occlusionState.contains(.visible)), attached=\(native?.window === window)")
                    }
                    guard rotor?.animation(forKey: "ball-orbit") == nil else { self.fail("Hidden orbit kept playing") }
                    guard displayedWidth == 160 else { self.fail("Hidden drawing lost its cached frame") }
                    window.orderFront(nil)
                    stage = 2
                case 7:
                    guard animation == nil, displayedWidth == 160, let contents = paint?.contents,
                          let data = (contents as! CGImage).dataProvider?.data else { return }
                    restingFrame = data as Data
                    hosted.rootView = artwork(.ink, sleeping: true, hovered: true)
                    stage = 8
                case 8:
                    guard animation == nil, displayedWidth == 160, let contents = paint?.contents,
                          let data = (contents as! CGImage).dataProvider?.data,
                          data as Data == restingFrame else { self.fail("Hover disturbed a resting wash") }
                    print("PASS: resting wash stays still when hovered")
                    hosted.rootView = artwork(.ink, lowEnergyMode: true)
                    stage = 9
                case 9, 10:
                    guard native == nil, orbit == nil else { self.fail("Low-energy mode kept an animation view") }
                    guard let tracker = self.pointerView(in: hosted), !tracker.reduceMotion else {
                        self.fail("Low-energy mode must retain pointer following and blinking")
                    }
                    if stage == 9 {
                        lowEnergyTracker = tracker
                        hosted.rootView = artwork(.blue, hovered: true, lowEnergyMode: true)
                        stage = 10
                    } else {
                        guard lowEnergyTracker === tracker else { self.fail("Style change reset live eye tracking") }
                        if let bitmap = hosted.bitmapImageRepForCachingDisplay(in: hosted.bounds) {
                            hosted.cacheDisplay(in: hosted.bounds, to: bitmap)
                            let output = URL(fileURLWithPath: CommandLine.arguments[1])
                            try? bitmap.representation(using: .png, properties: [:])?.write(
                                to: output.appendingPathComponent("low-energy-live-gaze.png"))
                        }
                        print("PASS: low-energy mode stops both palettes and orbits, preserving live eyes")
                        hosted.rootView = artwork(.blue)
                        stage = 11
                    }
                default:
                    guard native == nil else { self.fail("Reduce Motion kept the animated native view") }
                    guard orbit == nil else { self.fail("Reduce Motion kept the animated orbit") }
                    timer.invalidate()
                    window.orderOut(nil)
                    window.close()
                    print("PASS: Reduce Motion uses the static drawing")
                    self.checkInterruptedPlayback()
                }
            }
        }
    }

    private func flowView(in view: NSView) -> BallInkFlowView? {
        if let view = view as? BallInkFlowView { return view }
        return view.subviews.lazy.compactMap { self.flowView(in: $0) }.first
    }

    private func orbitView(in view: NSView) -> BallOrbitView? {
        if let view = view as? BallOrbitView { return view }
        return view.subviews.lazy.compactMap { self.orbitView(in: $0) }.first
    }

    private func pointerView(in view: NSView) -> BallMouseTrackingView? {
        if let view = view as? BallMouseTrackingView { return view }
        return view.subviews.lazy.compactMap { self.pointerView(in: $0) }.first
    }

    private func checkInterruptedPlayback() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 160, height: 80))
        let flow = BallInkFlowView(working: true, palette: .blue)
        flow.frame = NSRect(x: 8, y: 8, width: 56, height: 56)
        let content = NSView()
        content.wantsLayer = true
        content.layer?.backgroundColor = NSColor.systemBlue.cgColor
        let orbit = BallOrbitView(content: content, duration: 2.8)
        orbit.frame = NSRect(x: 88, y: 8, width: 54, height: 54)
        root.addSubview(flow)
        root.addSubview(orbit)
        let window = NSPanel(contentRect: root.frame, styleMask: [.borderless, .nonactivatingPanel],
                             backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.level = .floating
        window.hidesOnDeactivate = false
        window.contentView = root
        window.orderFront(nil)
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard let paint = flow.layer?.sublayers?.first,
                  let rotor = orbit.subviews.first?.layer,
                  paint.animation(forKey: "ink-flow") != nil,
                  rotor.animation(forKey: "ball-orbit") != nil else {
                self.fail("Recovery fixture did not start playing")
            }
            // 模拟窗口/图层重建移除动画：业务状态与可见性没有改变。
            paint.removeAllAnimations()
            rotor.removeAllAnimations()
            try? await Task.sleep(nanoseconds: 2_200_000_000)
            guard paint.animation(forKey: "ink-flow") != nil,
                  rotor.animation(forKey: "ball-orbit") != nil else {
                self.fail("Visible flow and orbit never recover after their animations are removed")
            }
            print("PASS: interrupted flow and orbit restart without status or visibility changes")
            guard !flow.playbackMonitor.usesFallback, !orbit.playbackMonitor.usesFallback else {
                self.fail("Healthy native playback should not switch to fallback")
            }
            // 动画对象仍在，但其图层时钟停止：仅判断 animation(forKey:) 不会发现故障。
            paint.speed = 0
            rotor.speed = 0
            try? await Task.sleep(nanoseconds: 3_500_000_000)
            guard flow.playbackMonitor.usesFallback, orbit.playbackMonitor.usesFallback else {
                self.fail("Frozen presentation did not activate bounded fallback playback")
            }
            var frames = Set<Data>()
            var angles = Set<Int>()
            for _ in 0..<5 {
                try? await Task.sleep(nanoseconds: 150_000_000)
                guard let contents = paint.presentation()?.contents,
                      let bytes = (contents as! CGImage).dataProvider?.data,
                      let transform = rotor.presentation()?.transform else {
                    self.fail("Fallback must produce actual presentation-layer output")
                }
                frames.insert(bytes as Data)
                angles.insert(Int(atan2(transform.m12, transform.m11) * 1_000))
            }
            guard frames.count >= 3, angles.count >= 3 else {
                self.fail("Fallback timers run but do not visibly change flow and orbit")
            }
            print("PASS: frozen native clocks recover with changing presented frames and orbit angles")
            flow.setResting(true)
            guard !flow.playbackMonitor.isRunning else { self.fail("Resting wash kept its fallback timer") }
            flow.setResting(false)
            window.orderOut(nil)
            guard !flow.playbackMonitor.isRunning, !orbit.playbackMonitor.isRunning else {
                self.fail("Hidden fallback retained animation timers")
            }
            window.orderFront(nil)
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard flow.playbackMonitor.isRunning, orbit.playbackMonitor.isRunning else {
                self.fail("Fallback did not resume when shown")
            }
            flow.stop()
            orbit.stop()
            try? await Task.sleep(nanoseconds: 150_000_000)
            guard !flow.playbackMonitor.isRunning, !orbit.playbackMonitor.isRunning else {
                self.fail("Dismantled fallback restarted itself")
            }
            print("PASS: fallback respects rest, hide/resume and teardown")
            let lateFlow = BallInkFlowView(working: true, palette: .ink)
            lateFlow.frame = flow.frame
            root.addSubview(lateFlow)
            // 即使窗口仍可见，dismantle 之后晚到的帧准备回调也不得启动播放。
            lateFlow.stop()
            try? await Task.sleep(nanoseconds: 200_000_000)
            guard !lateFlow.playbackMonitor.isRunning,
                  lateFlow.layer?.sublayers?.first?.animation(forKey: "ink-flow") == nil else {
                self.fail("A late frame callback restarted a dismantled flow view")
            }
            print("PASS: late frame preparation cannot restart a dismantled view")
            window.orderOut(nil)
            window.close()
            self.checkPointerPolling()
        }
    }

    private func checkPointerPolling() {
        let tracker = BallMouseTrackingView(frame: NSRect(x: 0, y: 0, width: 64, height: 64))
        let window = NSPanel(contentRect: NSRect(x: 100, y: 100, width: 64, height: 64),
                             styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.level = .floating
        window.hidesOnDeactivate = false
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.contentView = tracker
        tracker.watchesPointerEvents = false
        var reads = 0
        var gazeUpdates = 0
        var offset: CGFloat = 0
        var slowStart: TimeInterval?
        var sampleTimes: [TimeInterval] = []
        tracker.mouseLocation = {
            reads += 1
            let now = CACurrentMediaTime()
            let y = slowStart.map { now - $0 } ?? 0
            if slowStart != nil { sampleTimes.append(now) }
            let point = tracker.convert(NSPoint(x: 32 + offset, y: 32 + y), to: nil)
            return window.convertPoint(toScreen: point)
        }
        tracker.onGaze = { _ in gazeUpdates += 1 }
        window.orderFront(nil)
        Task { @MainActor in
            func wait(_ seconds: Double) async { try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) }
            await wait(1.2)
            assert((2...8).contains(reads), "Stationary gaze should poll around 4Hz: \(reads)")
            offset = 400
            let beforeWake = reads
            tracker.pointerDidMove()
            assert(reads == beforeWake + 1 && gazeUpdates > 0, "Motion must wake immediately, before the idle poll")
            for _ in 0..<1000 { tracker.pointerDidMove() }
            assert(reads == beforeWake + 1, "High-rate mouse events must not cause extra per-event renders")
            await wait(0.8)
            assert(gazeUpdates >= 12, "Active gaze must smoothly approach the target")

            // 远离球体、每秒只移动一个点：眼睛几乎已跟上，仍需维持连续采样。
            slowStart = CACurrentMediaTime()
            tracker.pointerDidMove()
            await wait(0.85)
            slowStart = nil
            let intervals = zip(sampleTimes.dropFirst(), sampleTimes).map { $0 - $1 }.sorted()
            assert(intervals.count >= 20, "Slow movement incorrectly fell back to idle polling")
            let p95 = intervals[Int(Double(intervals.count - 1) * 0.95)]
            assert(p95 < 0.08 && (intervals.last ?? 1) < 0.15,
                   "Slow tracking contains visible polling gaps: \(intervals)")
            print(String(format: "PASS: immediate wake, coalesced 1000-event burst, slow pointer %.0fHz / p95 %.1fms / max %.1fms",
                         Double(intervals.count) / (sampleTimes.last! - sampleTimes.first!), p95 * 1000, intervals.last! * 1000))

            tracker.reduceMotion = true
            await wait(0.7)
            let beforeReduced = reads
            await wait(1.2)
            assert(reads - beforeReduced <= 8, "Settled Reduce Motion must use low-frequency polling")
            window.orderOut(nil)
            let beforeHidden = reads
            tracker.pointerDidMove()
            await wait(0.5)
            assert(reads == beforeHidden, "Hidden tracking must ignore input and stop reading positions")
            window.orderFront(nil)
            await wait(0.5)
            assert(reads > beforeHidden, "Pointer tracking must resume on show")
            tracker.stop()
            let beforeStop = reads
            await wait(0.1)
            assert(reads == beforeStop, "A dismantled tracker must have no queued updates")
            tracker.mouseLocation = { .zero }
            window.orderOut(nil)
            window.close()
            print("PASS: idle 4Hz, Reduce Motion, hidden input suppression, hide/resume and teardown")
            await self.checkLegacyClock()
            NSApplication.shared.terminate(nil)
        }
    }

    private func checkLegacyClock() async {
        var ticks = 0
        guard let clock = BallLegacyFrameClock(screen: NSScreen.main, tick: { ticks += 1 }), clock.start() else {
            fail("Core Video fallback clock could not start")
        }
        try? await Task.sleep(nanoseconds: 250_000_000)
        assert(ticks >= 3, "Core Video fallback must deliver native display ticks")
        // 模拟主线程繁忙：显示线程不能把过时的眼睛更新排成一长串。
        let beforeStall = ticks
        usleep(120_000)
        assert(ticks == beforeStall)
        try? await Task.sleep(nanoseconds: 20_000_000)
        assert((1...3).contains(ticks - beforeStall), "Display ticks accumulated during a main-thread stall")
        clock.stop()
        let stopped = ticks
        try? await Task.sleep(nanoseconds: 80_000_000)
        assert(ticks == stopped, "Stopped clock must discard a queued callback")
        assert(clock.start())
        try? await Task.sleep(nanoseconds: 100_000_000)
        assert(ticks > stopped, "Fallback clock must restart without stale callbacks")
        clock.stop()
        print("PASS: macOS 12/13 display clock, stalled-main-thread coalescing, stop/restart")
    }

    private func fail(_ message: String) -> Never {
        fputs("FAIL: \(message)\n", stderr)
        exit(1)
    }
}

@MainActor
func runFloatingBallPlaybackChecks() {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let delegate = FloatingBallPlaybackDelegate()
    app.delegate = delegate
    app.run()
    withExtendedLifetime(delegate) {}
}
