import Cocoa
import SwiftUI

/// 用真正的 NSApplication 事件循环检查播放层；离线 ImageRenderer 不能验证动画是否启动。
@MainActor
private final class FloatingBallPlaybackDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        guard let screen = NSScreen.main else { fail("No display available for native playback check") }
        func artwork(_ appearance: FloatingBallAppearance, reduceMotion: Bool = false,
                     sleeping: Bool = false, hovered: Bool = false) -> FloatingBallStatusArtwork {
            let mood: PetMood = sleeping ? .sleeping : .working(taskCount: 2)
            return FloatingBallStatusArtwork(mood: mood,
                state: StatusBubbleState(mood: mood),
                hovered: hovered, reduceMotion: reduceMotion, appearance: appearance)
        }
        let hosted = NSHostingView(rootView: artwork(.blue))
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
        window.contentView = hosted
        window.orderFront(nil)

        var stage = 0
        var hashes = Set<UInt64>()
        var restingFrame: Data?
        let deadline = Date().addingTimeInterval(35)
        Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { timer in
            MainActor.assumeIsolated {
                guard Date() < deadline else { self.fail("Native playback timed out at stage \(stage)") }
                let native = self.flowView(in: hosted)
                let paint = native?.layer?.sublayers?.first
                let animation = paint?.animation(forKey: "ink-flow")
                let displayedWidth = paint?.contents.map { ($0 as! CGImage).width }
                switch stage {
                case 0, 2, 3, 5:
                    guard animation != nil,
                          let contents = paint?.presentation()?.contents else { return }
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
                    guard hashes.count >= 3 else { return }
                    hashes.removeAll()
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
                    } else {
                        print("PASS: appearance switch presents changing ink frames")
                        hosted.rootView = artwork(.ink, sleeping: true)
                        stage = 7
                    }
                case 1:
                    guard animation == nil else { self.fail("Hidden panel kept playing") }
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
                    hosted.rootView = artwork(.ink, reduceMotion: true)
                    stage = 4
                default:
                    guard native == nil else { self.fail("Reduce Motion kept the animated native view") }
                    timer.invalidate()
                    window.orderOut(nil)
                    window.close()
                    print("PASS: Reduce Motion uses the static drawing")
                    NSApplication.shared.terminate(nil)
                }
            }
        }
    }

    private func flowView(in view: NSView) -> BallInkFlowView? {
        if let view = view as? BallInkFlowView { return view }
        return view.subviews.lazy.compactMap { self.flowView(in: $0) }.first
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
