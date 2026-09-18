import Foundation
import XCTest

@testable import LingmouCollectorCore

final class KimiDesktopStatusTests: XCTestCase {
    private let now: TimeInterval = 2_000_000_000
    private var home: URL!

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: home)
    }

    private func writeWire(_ text: String, age: TimeInterval = 0) throws {
        let session = home.appendingPathComponent(".kimi-code/sessions/workspace/session")
        let agent = session.appendingPathComponent("agents/main")
        try FileManager.default.createDirectory(at: agent, withIntermediateDirectories: true)
        try #"{"title":"Desktop thinking fixture"}"#.write(
            to: session.appendingPathComponent("state.json"), atomically: true, encoding: .utf8)
        let wire = agent.appendingPathComponent("wire.jsonl")
        try text.write(to: wire, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: now - age)],
                                              ofItemAtPath: wire.path)
    }

    private var thinking: String {
        """
        {"type":"turn.prompt","time":1999999400000,"turnId":"turn"}
        {"type":"context.append_loop_event","time":1999999400001,"event":{"type":"step.begin","uuid":"step","turnId":"turn"}}
        {"type":"llm.request","time":1999999400002,"thinkingEffort":"high"}
        """
    }

    private func collect(executables: [String]) -> RawToolState {
        let processes = ProcessSupport { _, arguments, _ in
            switch arguments {
            case ["-eo", "args="], ["-eo", "comm="]:
                return executables.joined(separator: "\n")
            default: return ""
            }
        }
        return LocalCollectors(environment: CollectorEnvironment(homeDirectory: home.path, now: now),
                               settings: CollectorSettings(), files: FileSupport(), processes: processes).kimi()
    }

    func testDesktopThinkingWithoutOutputOrSeparateCLIProcessIsBusy() throws {
        // 一段时间没有文字/工具输出，只有未闭合的模型请求，仍是运行中。
        try writeWire(thinking, age: 600)
        for path in ["/Applications/Kimi Code.app/Contents/MacOS/Kimi Code",
                     "/Applications/AI Tools/Kimi Code.app/Contents/MacOS/Kimi Code"] {
            let state = collect(executables: [path])
            XCTAssertTrue(state.processOn)
            XCTAssertEqual(state.busy.map(\.id), ["session"])
            XCTAssertTrue(state.activities.isEmpty)
        }
    }

    func testDesktopPromptIsBusyBeforeFirstModelStep() throws {
        try writeWire(#"{"type":"turn.prompt","time":2000000000000}"#)
        XCTAssertEqual(collect(executables: ["/Applications/Kimi Code.app/Contents/MacOS/Kimi Code"])
            .busy.map(\.id), ["session"])
    }

    func testDesktopCompletionReturnsIdleAndNewPromptReopensWork() throws {
        let desktop = ["/Applications/Kimi Code.app/Contents/MacOS/Kimi Code"]
        let completed = thinking + "\n" + #"{"type":"context.append_loop_event","time":2000000000000,"event":{"type":"step.end","uuid":"step","turnId":"turn","finishReason":"end_turn"}}"#
        try writeWire(completed)
        let idle = collect(executables: desktop)
        XCTAssertTrue(idle.processOn)
        XCTAssertTrue(idle.busy.isEmpty)
        XCTAssertEqual(idle.activities.first?.phase, "ended")
        try writeWire(completed + "\n" + #"{"type":"turn.prompt","time":2000000000000}"#)
        let resumed = collect(executables: desktop)
        XCTAssertEqual(resumed.busy.count, 1)
        XCTAssertTrue(resumed.activities.isEmpty)
    }

    func testHelpersKimiWorkAndExitedDesktopCannotKeepThinkingBusy() throws {
        try writeWire(thinking)
        for executables in [[],
            ["/Applications/Kimi Code.app/Contents/Frameworks/Kimi Code Helper.app/Contents/MacOS/Kimi Code Helper"],
            ["/Applications/Kimi Code.app/Contents/Frameworks/Electron Framework.framework/Helpers/chrome_crashpad_handler"],
            ["/Applications/Kimi.app/Contents/MacOS/Kimi"]] {
            let state = collect(executables: executables)
            XCTAssertFalse(state.processOn)
            XCTAssertTrue(state.busy.isEmpty)
        }
    }

    func testDesktopPresenceAloneOrStaleStepDoesNotMeanBusy() throws {
        let desktop = ["/Applications/Kimi Code.app/Contents/MacOS/Kimi Code"]
        XCTAssertTrue(collect(executables: desktop).processOn)
        XCTAssertTrue(collect(executables: desktop).busy.isEmpty)
        try writeWire(thinking, age: 1_801)
        XCTAssertTrue(collect(executables: desktop).busy.isEmpty)
    }
}
