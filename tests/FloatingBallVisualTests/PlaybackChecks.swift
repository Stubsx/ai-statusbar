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
                    self.checkPointerPolling()
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

    private func checkPointerPolling() {
        let tracker = BallMouseTrackingView(frame: NSRect(x: 0, y: 0, width: 64, height: 64))
        let window = NSPanel(contentRect: NSRect(x: 100, y: 100, width: 64, height: 64),
                             styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.level = .floating
        window.hidesOnDeactivate = false
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.contentView = tracker
        var reads = 0
        var gazeUpdates = 0
        var offset: CGFloat = 0
        tracker.mouseLocation = {
            reads += 1
            let point = tracker.convert(NSPoint(x: 32 + offset, y: 32), to: nil)
            return window.convertPoint(toScreen: point)
        }
        tracker.onGaze = { _ in gazeUpdates += 1 }
        window.orderFront(nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            assert((2...8).contains(reads), "Stationary gaze should poll around 4Hz, not 30Hz: \(reads)")
            offset = 400
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                assert(gazeUpdates >= 12, "Active gaze must get enough updates for smooth following")
                tracker.reduceMotion = true
                let beforeReduced = reads
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                    assert(reads - beforeReduced <= 8, "Reduce Motion must use low-frequency polling")
                    window.orderOut(nil)
                    let beforeHidden = reads
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        assert(reads == beforeHidden, "Hidden pointer tracker must not wake")
                        window.orderFront(nil)
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                            assert(reads > beforeHidden, "Pointer tracking must resume on show")
                            tracker.stop()
                            // Break the fixture-only ownership cycle.
                            tracker.mouseLocation = { .zero }
                            window.orderOut(nil)
                            window.close()
                            print("PASS: idle pointer polls at 4Hz, moving gaze stays smooth; reduced motion and hide/resume")
                            NSApplication.shared.terminate(nil)
                        }
                    }
                }
            }
        }
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
