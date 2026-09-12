import Foundation
import XCTest
@testable import LingmouCollectorCore

final class LatencyTests: XCTestCase {
    private var home: URL!
    private let now: Double = 2_000_000_000

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: home) }

    private func write(_ text: String, _ path: String) throws {
        let url = home.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: now)], ofItemAtPath: url.path)
    }
    private func database(_ path: String) throws -> SQLiteDatabase {
        let url = home.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        return try SQLiteDatabase(path: url.path)
    }
    private func local(running: Bool = true) -> LocalCollectors {
        LocalCollectors(environment: CollectorEnvironment(homeDirectory: home.path, now: now),
                        settings: CollectorSettings(), files: FileSupport(),
                        processes: ProcessSupport { _, _, _ in
                            running ? "/bin/kimi\n/bin/Hermes\n/bin/ZCode\n" : ""
                        })
    }

    func testKimiCompletionSurvivesExitAndNewPromptClearsIt() throws {
        let root = ".kimi-code/sessions/work/session"
        let wire = root + "/agents/main/wire.jsonl"
        try write(#"{"title":"probe"}"#, root + "/state.json")
        let ended = #"{"type":"context.append_loop_event","time":1999999999000,"event":{"type":"step.end","uuid":"one","turnId":"0","finishReason":"end_turn"}}"#
        try write(ended, wire)
        XCTAssertEqual(local(running: false).kimi().activities.first?.phase, "ended")
        XCTAssertEqual(local().kimi().activities.first?.updatedAt, now - 1)
        try write(ended + "\n" + #"{"type":"turn.prompt","time":2000000000000}"#, wire)
        XCTAssertTrue(local().kimi().activities.isEmpty)
        XCTAssertEqual(local().kimi().busy.count, 1)
        XCTAssertTrue(local(running: false).kimi().busy.isEmpty)
    }

    func testKimiRenamedRuntimeProcessIsRecognized() throws {
        let root = ".kimi-code/sessions/work/session"
        try write(#"{"title":"probe"}"#, root + "/state.json")
        try write(#"{"type":"context.append_loop_event","time":2000000000000,"event":{"type":"step.begin","uuid":"one","turnId":"0"}}"#,
                  root + "/agents/main/wire.jsonl")
        let state = LocalCollectors(environment: CollectorEnvironment(homeDirectory: home.path, now: now),
            settings: CollectorSettings(), files: FileSupport(), processes: ProcessSupport { _, _, _ in "kimi-code\n" }).kimi()
        XCTAssertTrue(state.processOn)
        XCTAssertEqual(state.busy.count, 1)
    }

    func testKimiSubagentKeepsMainCompletionFromFiringEarly() throws {
        let root = ".kimi-code/sessions/work/session"
        try write(#"{"title":"probe"}"#, root + "/state.json")
        try write(#"{"type":"context.append_loop_event","time":1999999999000,"event":{"type":"step.end","uuid":"one","turnId":"0","finishReason":"end_turn"}}"#,
                  root + "/agents/main/wire.jsonl")
        try write(#"{"type":"context.append_loop_event","time":1999999998000,"event":{"type":"step.begin","uuid":"child","turnId":"0"}}"#,
                  root + "/agents/agent-1/wire.jsonl")
        XCTAssertEqual(local().kimi().busy.count, 1)
        XCTAssertTrue(local().kimi().activities.isEmpty)
    }

    private func hermesDB() throws -> SQLiteDatabase {
        let db = try database(".hermes/state.db")
        try db.execute("CREATE TABLE sessions(id TEXT, title TEXT, archived INT, started_at REAL, last_activity_at REAL)")
        try db.execute("CREATE TABLE messages(id INTEGER PRIMARY KEY, session_id TEXT, role TEXT, timestamp REAL, finish_reason TEXT, tool_calls TEXT)")
        try db.execute("CREATE TABLE session_turn_leases(conversation_id TEXT, expires_at REAL)")
        try db.execute("CREATE TABLE session_model_usage(session_id TEXT, last_seen REAL)")
        try db.execute("INSERT INTO sessions VALUES('s','probe',0,?,?)", binds: [.real(now - 60), .real(now)])
        try db.execute("INSERT INTO session_model_usage VALUES('s',?)", binds: [.real(now)])
        return db
    }

    func testHermesRecentUsageCannotKeepCompletedTaskBusy() throws {
        let db = try hermesDB()
        try db.execute("INSERT INTO messages VALUES(1,'s','assistant',?,'stop',NULL)", binds: [.real(now - 1)])
        let state = local().hermes()
        XCTAssertTrue(state.busy.isEmpty)
        XCTAssertEqual(state.activities.first?.phase, "ended")
        XCTAssertEqual(local(running: false).hermes().activities.first?.phase, "ended")
        try db.execute("INSERT INTO messages VALUES(2,'s','user',?,NULL,NULL)", binds: [.real(now)])
        XCTAssertTrue(local().hermes().activities.isEmpty)
        XCTAssertEqual(local().hermes().busy.count, 1)
        XCTAssertTrue(local(running: false).hermes().busy.isEmpty)
    }

    func testHermesActiveLeaseOverridesOldAssistantAndPendingToolsDoNotEnd() throws {
        let db = try hermesDB()
        try db.execute("INSERT INTO messages VALUES(1,'s','assistant',?,'stop',NULL)", binds: [.real(now - 1)])
        try db.execute("INSERT INTO session_turn_leases VALUES('s',?)", binds: [.real(now + 30)])
        XCTAssertEqual(local().hermes().busy.count, 1)
        XCTAssertTrue(local().hermes().activities.isEmpty)
        try db.execute("DELETE FROM session_turn_leases")
        try db.execute("UPDATE messages SET tool_calls='[{\"id\":\"tool\"}]', finish_reason='tool_calls'")
        XCTAssertTrue(local().hermes().activities.isEmpty)
        XCTAssertEqual(local().hermes().busy.count, 1)
    }

    func testHermesExplicitErrorIsInterrupted() throws {
        let db = try hermesDB()
        try db.execute("INSERT INTO messages VALUES(1,'s','assistant',?,'agent_error',NULL)", binds: [.real(now)])
        XCTAssertEqual(local().hermes().activities.first?.phase, "interrupted")
    }

    func testZcodeImmediateFollowupAndLateAssistantWrite() throws {
        let db = try database(".zcode/cli/db/db.sqlite")
        try db.execute("CREATE TABLE turn_usage(session_id TEXT, turn_id TEXT, status TEXT, started_at REAL, completed_at REAL)")
        try db.execute("CREATE TABLE message(session_id TEXT, time_created REAL, data TEXT)")
        try db.execute("INSERT INTO turn_usage VALUES('s','old','completed',?,?)", binds: [.real((now - 20) * 1000), .real((now - 1) * 1000)])
        try db.execute("INSERT INTO message VALUES('s',?,'{\"role\":\"assistant\"}')", binds: [.real(now * 1000)])
        XCTAssertTrue(local().zcode().busy.isEmpty, "Late assistant metadata must not reopen a finished turn")
        try db.execute("INSERT INTO message VALUES('s',?,'{\"role\":\"user\"}')", binds: [.real(now * 1000)])
        XCTAssertEqual(local().zcode().busy.count, 1, "A follow-up within one second must be detected")
        XCTAssertTrue(local().zcode().activities.isEmpty)
        try db.execute("INSERT INTO turn_usage VALUES('s','new','running',?,NULL)", binds: [.real(now * 1000)])
        XCTAssertEqual(local().zcode().busy.count, 1)
        try db.execute("UPDATE turn_usage SET status='cancelled',completed_at=? WHERE turn_id='new'", binds: [.real(now * 1000)])
        XCTAssertTrue(local().zcode().busy.isEmpty)
        XCTAssertEqual(local().zcode().activities.first?.phase, "interrupted")
    }

    func testCodexHeaderPreventsAppBeingClassifiedAsCLIFromIndex() throws {
        let id = "12345678-1234-1234-1234-123456789abc"
        try write("{\"id\":\"\(id)\",\"thread_name\":\"test\"}", ".codex/session_index.jsonl")
        let path = ".codex/sessions/2026/01/01/rollout-2026-01-01T00-00-00-\(id).jsonl"
        try write("""
            {"type":"session_meta","payload":{"source":"vscode"}}
            {"type":"event_msg","payload":{"type":"task_started"}}
            """, path)
        func collect(running: Bool) -> CodexResult {
            CodexCollector(environment: CollectorEnvironment(homeDirectory: home.path, now: now),
                settings: CollectorSettings(), files: FileSupport(), processes: ProcessSupport { _, _, _ in
                    running ? "/Applications/Codex.app/Contents/MacOS/Codex\n" : ""
                }).collect()
        }
        XCTAssertTrue(collect(running: true).cli.busy.isEmpty)
        XCTAssertEqual(collect(running: true).ide.busy.count, 1)
        XCTAssertTrue(collect(running: false).ide.busy.isEmpty, "Cached evidence must reevaluate process exit")
    }

    func testInterpretedProcessesAndPaddedPIDs() {
        let ps = ProcessSupport { _, args, _ in
            args.contains("pid=,args=") ? "  42 /bin/python3 /env/bin/hermes chat\n" :
                "/bin/python3 /env/bin/hermes chat\n/bin/node /env/bin/codex exec\n/bin/echo hermes\n"
        }
        XCTAssertEqual(ps.count(named: "hermes"), 1)
        XCTAssertEqual(ps.count(named: "codex"), 1)
        XCTAssertEqual(ps.pids(matching: "hermes"), [42])
    }

    func testStatusPathRetainsMetricsWithoutScanningUsage() throws {
        let quota = ToolQuota(plan: "test", windows: [], updatedAt: Int(now - 60))
        let metrics = CollectorMetrics(quotas: ["kimi": quota], usage: nil, usageMerged: nil, sync: nil, collectedAt: now - 60)
        metrics.save(home: home.path)
        let collector = LingmouCollector(environment: CollectorEnvironment(homeDirectory: home.path, now: now))
        let result = collector.collectStatus(metrics: CollectorMetrics.load(home: home.path))
        XCTAssertEqual(result.tools.first { $0.key == "kimi" }?.quota?.updatedAt, Int(now - 60))
        XCTAssertEqual(result.collectedAt, now)
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.appendingPathComponent(".ai-statusbar/usage.sqlite").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.appendingPathComponent(".ai-statusbar/quota-cache.json").path))
    }

    func testSourceCacheInvalidatesAtomicReplacementAndTruncation() throws {
        let path = home.appendingPathComponent("session.jsonl").path
        try write("abc", "session.jsonl")
        let cache = SourceStateCache(home: home.path)
        var parses = 0
        func read() -> String { parses += 1; return (try? String(contentsOfFile: path)) ?? "" }
        XCTAssertEqual(cache.value(at: path, parse: read), "abc")
        XCTAssertEqual(cache.value(at: path, parse: read), "abc")
        XCTAssertEqual(parses, 1)
        try write("def", "session.jsonl") // Same mtime/size, new inode.
        XCTAssertEqual(cache.value(at: path, parse: read), "def")
        try write("x", "session.jsonl")
        XCTAssertEqual(cache.value(at: path, parse: read), "x")
        XCTAssertEqual(parses, 3)
    }
}
