// Standalone AppKit/SwiftUI smoke test; does not start collectors or change settings.
import Cocoa
import SwiftUI
import ImageIO

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
    // 帧率改变不能改变跟随速度，也不能越过目标位置。
    func followedGaze(fps: Int) -> CGSize {
        var gaze = CGSize.zero
        for _ in 0..<fps {
            gaze = BallGazeGeometry.follow(current: gaze, target: far, elapsed: 1 / Double(fps))
            assert(gaze.width <= far.width)
        }
        return gaze
    }
    assert(abs(followedGaze(fps: 30).width - followedGaze(fps: 60).width) < 0.000001)
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
    // 程序水墨必须可缓存、透明且使用合法的预乘颜色，防止深色桌面出现白框。
    let inkStarted = Date()
    for palette in [BallInkDrawing.Palette.ink, .blue] {
        let texture = palette.still
        guard let texture, let data = texture.dataProvider?.data,
              let bytes = CFDataGetBytePtr(data) else { fatalError("Ink drawing failed") }
        var transparent = 0
        var translucent = 0
        var darkest = 255
        var lightest = 0
        for row in 0..<texture.height {
            for column in 0..<texture.width {
                let index = row * texture.bytesPerRow + column * 4
                let alpha = Int(bytes[index + 3])
                if palette == .ink {
                    assert(bytes[index] == bytes[index + 1] && bytes[index] == bytes[index + 2])
                } else if alpha == 255 {
                    assert(bytes[index + 2] > bytes[index + 1] && bytes[index + 1] > bytes[index],
                           "Blue wash must keep its sky-blue hue")
                }
                for channel in 0..<3 {
                    assert(Int(bytes[index + channel]) <= alpha, "Premultiplied color must not create light fringes")
                }
                if row == 0 || column == 0 || row == texture.height - 1 || column == texture.width - 1 {
                    assert(alpha == 0, "The circle must fit in the transparent canvas")
                }
                let radius = hypot((Double(column) + 0.5) / Double(texture.width) * 2.4 - 1.2,
                                   (Double(row) + 0.5) / Double(texture.height) * 2.4 - 1.2)
                if radius < 0.97 { assert(alpha == 255, "Interior washes must not punch holes in the silhouette") }
                if radius > 1 { assert(alpha == 0, "Pigment must not bleed outside the circle") }
                if alpha == 0 { transparent += 1 }
                if alpha > 0 && alpha < 255 { translucent += 1 }
                if alpha == 255 {
                    darkest = min(darkest, Int(bytes[index]))
                    lightest = max(lightest, Int(bytes[index]))
                }
            }
        }
        assert(transparent > texture.width * texture.height / 5)
        assert(translucent > 0 && translucent < texture.width * texture.height / 40,
               "Only a narrow antialiased edge should be translucent")
        assert(lightest - darkest > 70, "Washes need visible concentration changes, not a flat tint")
        if palette == .blue { assert(darkest > 20, "Keep the blue face bright enough") }
    }
    assert(BallInkDrawing.dark === BallInkDrawing.dark)
    let appearanceSuite = "lingmou.ink-migration.\(UUID().uuidString)"
    let appearanceDefaults = UserDefaults(suiteName: appearanceSuite)!
    defer { appearanceDefaults.removePersistentDomain(forName: appearanceSuite) }
    appearanceDefaults.set("white-ink", forKey: "floatingBallAppearance")
    FloatingBallAppearance.migrateRemovedAppearance(in: appearanceDefaults)
    assert(appearanceDefaults.string(forKey: "floatingBallAppearance") == "ink")
    appearanceDefaults.set("blue", forKey: "floatingBallAppearance")
    FloatingBallAppearance.migrateRemovedAppearance(in: appearanceDefaults)
    assert(appearanceDefaults.string(forKey: "floatingBallAppearance") == "blue")
    print(String(format: "PASS: cached ink/blue washes, transparency, premultiplied color and tonal range (%.2fs)",
                 Date().timeIntervalSince(inkStarted)))
    let inkFrames = BallInkDrawing.flowFrames
    let blueFrames = BallInkDrawing.blueFlowFrames
    for palette in [BallInkDrawing.Palette.ink, .blue] {
        let frames = palette.frames
        assert(frames.count == BallInkDrawing.flowFrameCount)
        assert(frames.first === palette.frames.first)
        let frameBytes = frames.map { image -> Data in
            assert(image.width == 160 && image.height == 160)
            return image.dataProvider!.data! as Data
        }
        for bytes in frameBytes {
            for pixel in stride(from: 0, to: bytes.count, by: 4) {
                for channel in 0..<3 {
                    assert(bytes[pixel + channel] <= bytes[pixel + 3], "Animated washes must keep valid transparent edges")
                }
                assert(bytes[pixel + 3] == frameBytes[0][pixel + 3],
                       "Internal pigment flow must not move or roughen the outline")
                let row = pixel / 4 / 160, column = pixel / 4 % 160
                if row == 0 || column == 0 || row == 159 || column == 159 {
                    assert(bytes[pixel + 3] == 0, "Circle edges must not touch the frame")
                }
            }
        }
        func difference(_ lhs: Data, _ rhs: Data) -> Double {
            zip(lhs, rhs).reduce(0.0) { $0 + Double(abs(Int($1.0) - Int($1.1))) } / Double(lhs.count)
        }
        let largestStep = (1..<frameBytes.count).map { difference(frameBytes[$0 - 1], frameBytes[$0]) }.max()!
        let seam = difference(frameBytes.last!, frameBytes.first!)
        let excursion = difference(frameBytes[0], frameBytes[frameBytes.count / 2])
        assert(seam <= largestStep * 1.5 + 0.01, "The loop seam must be as smooth as neighboring frames")
        assert(largestStep < 2.5 && excursion > 1, "Washes should flow gradually without flickering or staying still")
        print(String(format: "PASS: %@ flow, %d cached frames, step %.3f / seam %.3f / motion %.3f",
                     String(describing: palette), frames.count, largestStep, seam, excursion))
    }
    var flowClock = BallInkFlowClock(duration: 14)
    flowClock.resume(at: 100)
    assert(abs(flowClock.phase(at: 103.5) - 0.25) < 0.00001)
    flowClock.setDuration(8, at: 103.5)
    assert(abs(flowClock.phase(at: 103.5) - 0.25) < 0.00001)
    flowClock.pause(at: 105.5)
    assert(abs(flowClock.phase(at: 1000) - 0.5) < 0.00001)
    flowClock.resume(at: 1000)
    assert(abs(flowClock.phase(at: 1004)) < 0.00001)
    let flowView = BallInkFlowView(working: true)
    assert(flowView.hitTest(.zero) == nil)
    assert(flowView.layer?.sublayers?.first?.animation(forKey: "ink-flow") == nil)
    flowView.stop()
    flowView.stop()
    print("PASS: continuous speed and pause; native animation hit-test passthrough")
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
    // 同一组原生视图对比外观；原大状态与放大笔触同时可检查。
    func renderAppearances(_ appearances: [FloatingBallAppearance], detailAppearance: FloatingBallAppearance,
                           filename: String) throws {
        let appearanceSheet = VStack(spacing: 0) {
            ForEach(0..<2) { row in
                VStack(alignment: .leading, spacing: 24) {
                    HStack(alignment: .center, spacing: 36) {
                        ForEach(appearances, id: \.rawValue) { appearance in
                            HStack(spacing: 14) {
                                FloatingBallArtwork(mood: .working(taskCount: 3), gaze: .zero,
                                                    hovered: false, reduceMotion: true, appearance: appearance)
                                    .scaleEffect(2).frame(width: 128, height: 128)
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(appearance.title).font(.system(size: 22, weight: .medium))
                                    Text(appearance == .ink ? "浓淡相生 · 一笔灵眸" : "天蓝叠染 · 水色流动")
                                        .font(.system(size: 11)).foregroundColor(.secondary)
                                }
                            }
                            .frame(width: 290, alignment: .leading)
                        }
                    }
                    HStack(spacing: 0) {
                        ForEach(0..<6) { index in
                            let mood: PetMood = index == 1 ? .working(taskCount: 3) :
                                index == 3 ? .sleeping : index == 4 ? .celebrating : index == 5 ? .error : .idle
                            let state = StatusBubbleState(mood: mood, completedCount: index == 4 ? 1 : 0)
                            VStack(spacing: 9) {
                                FloatingBallStatusArtwork(mood: mood, state: state,
                                    reduceMotion: true, eyeOpenness: index == 2 ? 0 : 1, appearance: detailAppearance)
                                    .frame(width: 100, alignment: .leading)
                                Text(["空闲", "工作", "眨眼", "休眠", "完成", "异常"][index])
                                    .font(.system(size: 11)).foregroundColor(.secondary)
                            }
                            .frame(width: 108)
                        }
                    }
                }
                .padding(28)
                .background(Color(white: row == 0 ? 0.97 : 0.10))
                .environment(\.colorScheme, row == 0 ? .light : .dark)
            }
        }
        let appearanceRenderer = ImageRenderer(content: appearanceSheet)
        appearanceRenderer.scale = 2
        guard let appearanceImage = appearanceRenderer.cgImage,
              let appearancePNG = NSBitmapImageRep(cgImage: appearanceImage).representation(using: .png, properties: [:])
        else { fatalError("Appearance preview failed") }
        try appearancePNG.write(to: output.appendingPathComponent(filename))
    }
    try renderAppearances([.blue, .ink], detailAppearance: .ink, filename: "ink-appearance-preview.png")
    for appearance in [FloatingBallAppearance.ink, .blue] {
        let frames = appearance == .ink ? inkFrames : blueFrames
        let duration = (appearance == .ink ? BallInkDrawing.Palette.ink : .blue).flowDuration(working: true)
        let prefix = appearance == .ink ? "ink" : "blue"
        let portraitContent = HStack(spacing: 0) {
            ForEach(0..<2) { row in
                VStack(spacing: 16) {
                    Text(appearance.title).font(.system(size: 21, weight: .medium))
                    FloatingBallArtwork(mood: .idle, gaze: .zero, hovered: false, reduceMotion: true, appearance: appearance)
                        .scaleEffect(2.5).frame(width: 160, height: 160)
                    HStack(spacing: 16) {
                        ForEach(0..<3) { index in
                            VStack(spacing: 8) {
                                FloatingBallArtwork(mood: index == 1 ? .working(taskCount: 1) : .idle,
                                    gaze: .zero, hovered: false, reduceMotion: true,
                                    eyeOpenness: index == 2 ? 0 : 1, appearance: appearance)
                                Text(["待命", "工作", "眨眼"][index])
                                    .font(.system(size: 11)).foregroundColor(.secondary)
                            }
                        }
                    }
                }
                .padding(28)
                .background(Color(white: row == 0 ? 0.97 : 0.10))
                .environment(\.colorScheme, row == 0 ? .light : .dark)
            }
        }
        let portraitRenderer = ImageRenderer(content: portraitContent)
        portraitRenderer.scale = 2
        guard let portrait = portraitRenderer.cgImage,
              let portraitPNG = NSBitmapImageRep(cgImage: portrait).representation(using: .png, properties: [:])
        else { fatalError("Ink portrait rendering failed") }
        try portraitPNG.write(to: output.appendingPathComponent("\(prefix)-polished-preview.png"))
        let gifURL = output.appendingPathComponent("\(prefix)-flow-preview.gif")
        guard let gif = CGImageDestinationCreateWithURL(gifURL as CFURL, "com.compuserve.gif" as CFString,
                                                        frames.count, nil) else { fatalError("GIF creation failed") }
        CGImageDestinationSetProperties(gif, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
        for (frameIndex, frame) in frames.enumerated() {
            let content = HStack(spacing: 0) {
                ForEach(0..<2) { row in
                    VStack(spacing: 16) {
                        Text("\(appearance.title) · 流动").font(.system(size: 17, weight: .medium))
                        FloatingBallArtwork(mood: .working(taskCount: 1), gaze: .zero, hovered: false,
                                            reduceMotion: true, appearance: appearance, washFrame: frame)
                            .scaleEffect(2.5).frame(width: 160, height: 160)
                        FloatingBallArtwork(mood: .idle, gaze: .zero, hovered: false,
                                            reduceMotion: true, appearance: appearance, washFrame: frame)
                    }
                    .padding(24)
                    .background(Color(white: row == 0 ? 0.97 : 0.10))
                    .environment(\.colorScheme, row == 0 ? .light : .dark)
                }
            }
            let renderer = ImageRenderer(content: content)
            renderer.scale = 2
            guard let image = renderer.cgImage else { fatalError("Flow frame rendering failed") }
            // GIF 只能存百分之一秒，分配余数以保持与原生层相同的循环时长。
            let delay = (floor(Double(frameIndex + 1) * duration * 100 / Double(frames.count))
                         - floor(Double(frameIndex) * duration * 100 / Double(frames.count))) / 100
            CGImageDestinationAddImage(gif, image, [kCGImagePropertyGIFDictionary: [
                kCGImagePropertyGIFDelayTime: delay,
                kCGImagePropertyGIFUnclampedDelayTime: delay
            ]] as CFDictionary)
        }
        assert(CGImageDestinationFinalize(gif))
    }
    print("PASS: 1681 direction/bounds samples, blink envelope, upper-right face projection, hit-test passthrough; rendered 12 state/background snapshots")
}

if CommandLine.arguments.contains("--playback") {
    MainActor.assumeIsolated { runFloatingBallPlaybackChecks() }
} else {
    try MainActor.assumeIsolated { try runChecks() }
}
