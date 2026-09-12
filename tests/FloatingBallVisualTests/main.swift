// Standalone AppKit/SwiftUI smoke test; does not start collectors or change settings.
import Cocoa
import SwiftUI

enum PetMood: Equatable {
    case loading, working(taskCount: Int), idle, sleeping, celebrating, error
    var summary: String { String(describing: self) }
    static func current(data: Int?, error: String?) -> PetMood { .idle }
}

struct AttentionFixture { let phase: String }

final class StatusStore: ObservableObject {
    @Published var data: Int?
    @Published var collectorError: String?
    @Published var completedEventSerial = 0
    @Published var completedEventCount = 0
    var attentionEvents: [AttentionFixture] = []
}

@MainActor
func runChecks() throws {
    _ = NSApplication.shared
    let center = CGPoint(x: -900, y: 320)
    assert(BallGazeGeometry.offset(cursor: center, center: center) == .zero)
    for x in stride(from: -2000, through: 2000, by: 100) {
        for y in stride(from: -2000, through: 2000, by: 100) {
            let offset = BallGazeGeometry.offset(
                cursor: CGPoint(x: center.x + CGFloat(x), y: center.y + CGFloat(y)), center: center
            )
            assert(hypot(offset.width, offset.height) <= 5.000001)
            assert(x == 0 ? offset.width == 0 : offset.width * CGFloat(x) > 0)
            assert(y == 0 ? offset.height == 0 : offset.height * CGFloat(y) > 0)
        }
    }
    let near = BallGazeGeometry.offset(cursor: CGPoint(x: 10, y: 0), center: .zero)
    let far = BallGazeGeometry.offset(cursor: CGPoint(x: 1000, y: 0), center: .zero)
    assert(near.width < far.width)
    for t in stride(from: 0.0, through: 0.4, by: 0.001) {
        assert((0...1).contains(BallBlinkTiming.openness(elapsed: t)))
    }
    assert(BallBlinkTiming.openness(elapsed: 0) == 1)
    assert(BallBlinkTiming.openness(elapsed: 0.09) == 0)
    assert(abs(BallBlinkTiming.openness(elapsed: 0.245) - 1) < 0.001)
    let upperRight = CGSize(width: 3.5, height: -3.5)
    let farEye = BallFaceGeometry.eye(side: 1, gaze: upperRight)
    let nearEye = BallFaceGeometry.eye(side: -1, gaze: upperRight)
    assert(farEye.widthScale < nearEye.widthScale)
    assert(farEye.center.y < -3.8 && nearEye.center.y < -3.8)
    assert(farEye.center.x - nearEye.center.x < 12)
    assert(abs(farEye.center.y - nearEye.center.y) > 1)
    let tracker = BallMouseTrackingView(frame: NSRect(x: 0, y: 0, width: 64, height: 64))
    assert(tracker.hitTest(NSPoint(x: 32, y: 32)) == nil)
    assert(tracker.isFlipped)
    tracker.stop()
    tracker.stop()

    // 待处理优先；部分结束与剩余运行数必须同时存在，空闲不留数字 0。
    let mixed = StatusBubbleState(mood: .working(taskCount: 3), attentionCount: 1, urgentAttentionCount: 1, completedCount: 2)
    assert(mixed.kind == .attention && mixed.count == 1 && mixed.runningCount == 3)
    let completed = StatusBubbleState(mood: .working(taskCount: 2), attentionCount: 4, completedCount: 4)
    assert(completed.kind == .completed && completed.count == 4 && completed.runningCount == 2)
    assert(!StatusBubbleState(mood: .idle).isVisible(expanded: false))
    assert(StatusBubbleState.compactCount(128) == "99+")

    // 数字采用等宽排版：1 与 8 不应改变胶囊宽度，也不能挤掉前面的计数。
    let singleDigitWidths = (1...9).map { count in
        NSHostingView(rootView: StatusBubble(
            state: StatusBubbleState(mood: .working(taskCount: count), attentionCount: count), style: .ball
        )).fittingSize.width
    }
    assert(singleDigitWidths.max()! - singleDigitWidths.min()! < 0.5)
    for pending in [1, 11, 99, 128] {
        for running in [1, 11, 99, 128] {
            let hosted = NSHostingView(rootView: StatusBubble(
                state: StatusBubbleState(mood: .working(taskCount: running), attentionCount: pending), style: .ball
            ))
            assert(hosted.fittingSize.width <= FloatingBallStatusArtwork.size.width - 8,
                   "Both numeric groups must fit inside the actual ball window")
            let anchor = NSHostingView(rootView: StatusBubble(
                state: StatusBubbleState(mood: .working(taskCount: running)), style: .ball
            ))
            assert(hosted.fittingSize.width - anchor.fittingSize.width <= FloatingBallStatusArtwork.messageExtension,
                   "Appended messages must fit in the space to the right of the unchanged running bubble")
        }
    }

    let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
    let samples: [(String, PetMood, CGSize)] = [
        ("居中", .idle, .zero),
        ("运行 1 个", .working(taskCount: 1), CGSize(width: -3.5, height: -3.5)),
        ("运行 12 个", .working(taskCount: 12), upperRight),
        ("运行 128 个", .working(taskCount: 128), .zero),
        ("眨眼·半闭", .idle, upperRight),
        ("眨眼·闭合", .idle, upperRight)
    ]
    let sheet = VStack(spacing: 0) {
        ForEach(0..<2) { row in
            HStack(spacing: 24) {
                ForEach(0..<samples.count, id: \.self) { index in
                    let sample = samples[index]
                    VStack(spacing: 12) {
                        FloatingBallStatusArtwork(mood: sample.1, state: StatusBubbleState(mood: sample.1),
                                                  gaze: sample.2, reduceMotion: true,
                                                  eyeOpenness: index == 4 ? 0.5 : index == 5 ? 0 : 1)
                        Text(sample.0).font(.system(size: 11))
                            .foregroundColor(row == 0 ? .black.opacity(0.65) : .white.opacity(0.75))
                    }
                    .frame(width: FloatingBallStatusArtwork.size.width)
                }
            }
            .padding(28)
            .background(row == 0 ? Color(red: 0.95, green: 0.97, blue: 0.96) : Color(red: 0.08, green: 0.11, blue: 0.17))
            .environment(\.colorScheme, row == 0 ? .light : .dark)
        }
    }
    let renderer = ImageRenderer(content: sheet)
    renderer.scale = 2
    guard let image = renderer.cgImage else { fatalError("SwiftUI rendering failed") }
    let bitmap = NSBitmapImageRep(cgImage: image)
    guard let png = bitmap.representation(using: .png, properties: [:]) else { fatalError("PNG encoding failed") }
    try png.write(to: output.appendingPathComponent("floating-ball-preview.png"))
    let states: [(String, StatusBubbleState)] = [
        ("运行", StatusBubbleState(mood: .working(taskCount: 3))),
        ("待处理", StatusBubbleState(mood: .idle, attentionCount: 1)),
        ("1 + 1", StatusBubbleState(mood: .working(taskCount: 1), attentionCount: 1)),
        ("部分结束", completed),
        ("大数字", StatusBubbleState(mood: .working(taskCount: 128), attentionCount: 120)),
        ("采集异常", StatusBubbleState(mood: .error))
    ]
    let bubbleSheet = VStack(spacing: 0) {
        ForEach(0..<2) { row in
            HStack(spacing: 20) {
                ForEach(0..<states.count, id: \.self) { index in
                    VStack(spacing: 14) {
                        FloatingBallStatusArtwork(mood: states[index].1.mood, state: states[index].1, reduceMotion: true)
                        Text(states[index].0).font(.system(size: 11))
                    }
                    .frame(width: FloatingBallStatusArtwork.size.width)
                }
            }
            .padding(24)
            .background(row == 0 ? Color.white : Color(red: 0.08, green: 0.11, blue: 0.17))
            .environment(\.colorScheme, row == 0 ? .light : .dark)
        }
    }
    let bubbleRenderer = ImageRenderer(content: bubbleSheet)
    bubbleRenderer.scale = 3
    guard let bubbleImage = bubbleRenderer.cgImage,
          let bubblePNG = NSBitmapImageRep(cgImage: bubbleImage).representation(using: .png, properties: [:])
    else { fatalError("Status bubble rendering failed") }
    try bubblePNG.write(to: output.appendingPathComponent("unified-status-bubbles.png"))
    // 用真实 NSHostingView 再渲染用户报告的 1 + 1，覆盖原生窗口里的布局约束。
    let native = NSHostingView(rootView: FloatingBallStatusArtwork(
        mood: .working(taskCount: 1), state: StatusBubbleState(mood: .working(taskCount: 1), attentionCount: 1),
        reduceMotion: true
    ).padding(16).background(Color.white).environment(\.colorScheme, .light))
    let window = NSWindow(contentRect: NSRect(origin: CGPoint(x: -10000, y: -10000), size: native.fittingSize),
                          styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = native
    window.orderFront(nil)
    native.layoutSubtreeIfNeeded()
    RunLoop.current.run(until: Date().addingTimeInterval(0.25))
    guard let nativeBitmap = native.bitmapImageRepForCachingDisplay(in: native.bounds) else { fatalError("Native snapshot failed") }
    native.cacheDisplay(in: native.bounds, to: nativeBitmap)
    try nativeBitmap.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent("bubble-one-and-one.png"))
    window.orderOut(nil)
    window.close()
    let directionPreview = HStack(spacing: 16) {
        ForEach(0..<2) { index in
            VStack(spacing: 12) {
                FloatingBallStatusArtwork(mood: .working(taskCount: 1),
                    state: StatusBubbleState(mood: .working(taskCount: 1), attentionCount: index), reduceMotion: true)
                Text(index == 0 ? "只有运行数字" : "消息向右展开").font(.system(size: 11))
            }
        }
    }.padding(20).background(Color.white).environment(\.colorScheme, .light)
    let directionRenderer = ImageRenderer(content: directionPreview)
    directionRenderer.scale = 2
    guard let directionImage = directionRenderer.cgImage,
          let directionPNG = NSBitmapImageRep(cgImage: directionImage).representation(using: .png, properties: [:])
    else { fatalError("Direction preview failed") }
    try directionPNG.write(to: output.appendingPathComponent("bubble-expand-right.png"))
    print("PASS: 1681 direction/bounds samples, blink envelope, upper-right face projection, hit-test passthrough; rendered 12 state/background snapshots")
}

try MainActor.assumeIsolated { try runChecks() }
