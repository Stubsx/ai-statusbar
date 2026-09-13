import Foundation
import XCTest

@testable import LingmouCollectorCore

final class KimiWebTests: XCTestCase {
    private let now: TimeInterval = 2_000_000_000
    private var home: URL!

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: home)
    }

    private func write(_ text: String, _ path: String, age: TimeInterval = 0) throws {
        let url = home.appendingPathComponent(".kimi-code/" + path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: now - age)],
                                              ofItemAtPath: url.path)
    }

    private func register(age: TimeInterval = 0, name: String = "server", pid: String = "42") throws {
        try write("""
            {"server_id":"test","pid":\(pid),"started_at":\((now - 600) * 1_000),"heartbeat_at":\((now - age) * 1_000)}
            """, "server/instances/\(name).json")
    }

    private func processes(title: String = "kimi-cod", executable: String = "/opt/kimi/bin/kimi",
                           startOffset: TimeInterval = 0, alive: Bool = true) -> ProcessSupport {
        let processes = ProcessSupport { _, args, _ in
            guard alive else { return "" }
            return args == ["-eo", "pid=,args="] ? "42 \(title)\n" : "\(title)\n"
        }
        processes.identityOverride = { [now] pid in
            alive && pid == 42 ? (executable, now - 600 + startOffset) : nil
        }
        return processes
    }

    private func collect(_ processes: ProcessSupport) -> RawToolState {
        LocalCollectors(environment: CollectorEnvironment(homeDirectory: home.path, now: now),
                        settings: CollectorSettings(), files: FileSupport(), processes: processes).kimi()
    }

    func testNewWebSessionTransitionsFromPromptToEndedAndOff() throws {
        try register()
        try write(#"{"id":"session-new","cwd":"/tmp/New Project","title":""}"#,
                  "sessions/wd_new/session-new/state.json")
        let wire = "sessions/wd_new/session-new/agents/main/wire.jsonl"
        let prompt = "{\"type\":\"turn.prompt\",\"time\":\(now * 1_000)}\n"
        try write(prompt, wire)
        let busy = collect(processes())
        XCTAssertTrue(busy.processOn)
        XCTAssertEqual(busy.busy, [BusyItem(id: "session-new", title: "New Project")])

        try write(prompt + """
            {"type":"context.append_loop_event","event":{"type":"step.begin","turnId":"0","uuid":"step"}}
            {"type":"context.append_loop_event","time":\(now * 1_000),"event":{"type":"step.end","turnId":"0","uuid":"step","finishReason":"end_turn"}}
            """ + "\n", wire)
        let idle = collect(processes())
        XCTAssertTrue(idle.processOn)
        XCTAssertTrue(idle.busy.isEmpty)
        XCTAssertEqual(idle.activities.first?.phase, "ended")

        // Fresh logs/registry must not keep the service online after its process exits.
        try write(prompt, wire)
        let off = collect(processes(alive: false))
        XCTAssertFalse(off.processOn)
        XCTAssertTrue(off.busy.isEmpty)
    }

    func testRestoredWebSessionTracksActiveChildDespiteOldMainAndMetadata() throws {
        try register()
        try write(#"{"title":"Existing project","workDir":"/tmp/old"}"#,
                  "sessions/wd_old/session-old/state.json", age: 86_400)
        let begin = #"{"type":"context.append_loop_event","event":{"type":"step.begin","turnId":"2","uuid":"step"}}"# + "\n"
        try write(begin, "sessions/wd_old/session-old/agents/main/wire.jsonl", age: 3_600)
        let child = "sessions/wd_old/session-old/agents/agent-0/wire.jsonl"
        try write(begin, child)
        XCTAssertEqual(collect(processes()).busy.map(\.id), ["session-old"])
        try write(begin, child, age: 3_600)
        XCTAssertTrue(collect(processes()).busy.isEmpty)
    }

    func testRegistryRejectsStaleFutureMalformedOrReusedProcesses() throws {
        // A truncated name alone is insufficient evidence.
        XCTAssertFalse(collect(processes()).processOn)
        for age: TimeInterval in [31, -60] {
            try register(age: age)
            XCTAssertFalse(collect(processes()).processOn)
        }
        for pid in ["-1", "42.5", "1e100", "null"] {
            try register(pid: pid)
            XCTAssertFalse(collect(processes()).processOn)
        }
        try register()
        XCTAssertFalse(collect(processes(executable: "/usr/bin/unrelated")).processOn)
        XCTAssertFalse(collect(processes(startOffset: 120)).processOn)
        XCTAssertFalse(collect(processes(alive: false)).processOn)
        try write("invalid json", "server/instances/server.json")
        XCTAssertFalse(collect(processes()).processOn)
    }

    func testWebProcessCountDoesNotDuplicateNormalTitlesOrRegistryEntries() throws {
        try register()
        try register(name: "duplicate")
        for title in ["kimi-cod", "/opt/kimi/bin/kimi", "kimi-code", "node /opt/bin/kimi-code"] {
            let state = collect(processes(title: title))
            XCTAssertTrue(state.processOn, title)
            XCTAssertEqual(state.detail, "1 个进程", title)
            // A live web service with no running wire must remain idle.
            XCTAssertTrue(state.busy.isEmpty, title)
        }
    }
}
