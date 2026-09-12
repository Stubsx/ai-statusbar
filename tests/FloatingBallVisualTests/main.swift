// Standalone AppKit/SwiftUI smoke test; does not start collectors or change settings.
import Cocoa
import SwiftUI

enum PetMood: Equatable {
    case loading, working(taskCount: Int), idle, sleeping, celebrating, error
    var summary: String { String(describing: self) }
    static func current(data: Int?, error: String?) -> PetMood { .idle }
}

final class StatusStore: ObservableObject {
    @Published var data: Int?
    @Published var collectorError: String?
    @Published var completedEventSerial = 0
    var attentionEvents: [Int] = []
}

@MainActor
func runChecks() throws {
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
                        FloatingBallArtwork(mood: sample.1, gaze: sample.2, hovered: false, reduceMotion: true,
                                            eyeOpenness: index == 4 ? 0.5 : index == 5 ? 0 : 1)
                        Text(sample.0).font(.system(size: 11))
                            .foregroundColor(row == 0 ? .black.opacity(0.65) : .white.opacity(0.75))
                    }
                    .frame(width: 76)
                }
            }
            .padding(28)
            .background(row == 0 ? Color(red: 0.95, green: 0.97, blue: 0.96) : Color(red: 0.08, green: 0.11, blue: 0.17))
        }
    }
    let renderer = ImageRenderer(content: sheet)
    renderer.scale = 2
    guard let image = renderer.cgImage else { fatalError("SwiftUI rendering failed") }
    let bitmap = NSBitmapImageRep(cgImage: image)
    guard let png = bitmap.representation(using: .png, properties: [:]) else { fatalError("PNG encoding failed") }
    try png.write(to: output.appendingPathComponent("floating-ball-preview.png"))
    print("PASS: 1681 direction/bounds samples, blink envelope, upper-right face projection, hit-test passthrough; rendered 12 state/background snapshots")
}

try MainActor.assumeIsolated { try runChecks() }
