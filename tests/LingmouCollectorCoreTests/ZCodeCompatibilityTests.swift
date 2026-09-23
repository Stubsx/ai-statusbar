import Foundation
import XCTest
@testable import LingmouCollectorCore

final class ZCodeCompatibilityTests: XCTestCase {
    private var home: URL!
    private let now: Double = 2_000_000_000

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(
            at: home.appendingPathComponent(".zcode/cli/db"), withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: home)
    }

    private func database() throws -> SQLiteDatabase {
        let db = try SQLiteDatabase(path: home.appendingPathComponent(".zcode/cli/db/db.sqlite").path)
        try db.execute("""
            CREATE TABLE turn_usage(session_id TEXT, turn_id TEXT, status TEXT,
                started_at REAL, completed_at REAL)
            """)
        try db.execute("CREATE TABLE message(id TEXT, session_id TEXT, time_created REAL, data TEXT)")
        try db.execute("""
            INSERT INTO turn_usage VALUES('session', 'previous', 'completed', ?, ?)
            """, binds: [.real((now - 60) * 1_000), .real((now - 1) * 1_000)])
        return db
    }

    private func collect(running: Bool = true) -> RawToolState {
        LocalCollectors(environment: CollectorEnvironment(homeDirectory: home.path, now: now),
                        settings: CollectorSettings(), files: FileSupport(),
                        processes: ProcessSupport { _, _, _ in running ? "/bin/ZCode\n" : "" }).zcode()
    }

    private func message(_ data: String, in db: SQLiteDatabase, id: String = "input") throws {
        try db.execute("INSERT INTO message VALUES(?, 'session', ?, ?)",
                       binds: [.text(id), .real(now * 1_000), .text(data)])
    }

    func testRuntimeUserMessagesDoNotReopenCompletedTurn() throws {
        let db = try database()
        // Shapes observed in the 3.x database, with all content and identifiers replaced.
        let messages = [
            #"{"role":"user","synthetic":true,"source":"todo_reminder"}"#,
            #"{"role":"user","synthetic":true,"source":"background_task","visibility":"model-only"}"#,
            #"{"role":"user","semantics":{"origin":"agent_runtime","kind":"compact_summary"}}"#,
            #"{"role":"user","semantics":{"origin":"system","kind":"fork_notice"}}"#,
            #"{"role":"user","visibility":"model-only"}"#,
            #"{"role":"user","semantics":{"uiVisibility":"hidden"}}"#,
            #"{"role":"assistant","finish":"stop"}"#,
            #"{"role":"user","synthetic":"#,
        ]
        for (index, data) in messages.enumerated() {
            try message(data, in: db, id: "system-\(index)")
            let state = collect()
            XCTAssertTrue(state.busy.isEmpty, data)
            XCTAssertEqual(state.activities.first?.phase, "ended", data)
        }
        try message(#"{"role":"user","semantics":{"origin":"real_user","kind":"user_prompt"},"anchor":{"turnId":"next","origin":"realUser"}}"#, in: db)
        XCTAssertEqual(collect().busy.map(\.id), ["session"])
        XCTAssertTrue(collect().activities.isEmpty)
        XCTAssertTrue(collect(running: false).busy.isEmpty)
    }

    func testLateMessageAnchoredToFinishedTurnDoesNotRestartIt() throws {
        let db = try database()
        for status in ["completed", "error", "cancelled"] {
            try db.execute("UPDATE turn_usage SET status = ?", binds: [.text(status)])
            try db.execute("DELETE FROM message")
            try message(#"{"role":"user","semantics":{"origin":"real_user"},"anchor":{"turnId":"previous","origin":"realUser"}}"#, in: db)
            XCTAssertTrue(collect().busy.isEmpty, status)
            XCTAssertEqual(collect().activities.first?.phase, status == "completed" ? "ended" : "interrupted")
        }
        // A genuine follow-up still reopens immediately, without any timing tolerance.
        try message(#"{"role":"user","anchor":{"turnId":"next","origin":"realUser"}}"#, in: db, id: "next")
        XCTAssertEqual(collect().busy.count, 1)
        XCTAssertTrue(collect().activities.isEmpty)
    }

    private func inputTable(in db: SQLiteDatabase) throws {
        try db.execute("""
            CREATE TABLE session_input(session_id TEXT, delivery TEXT, status TEXT,
                time_created REAL, time_updated REAL, promoted_message_id TEXT)
            """)
    }

    private func input(delivery: String, status: String, in db: SQLiteDatabase,
                       created: Double? = nil, session: String = "session") throws {
        try db.execute("DELETE FROM session_input")
        try db.execute("INSERT INTO session_input VALUES(?, ?, ?, ?, ?, 'input')",
                       binds: [.text(session), .text(delivery), .text(status),
                               .real((created ?? now) * 1_000), .real(now * 1_000)])
    }

    func testInputAdmissionPromotionCancellationAndCompletion() throws {
        let db = try database()
        try inputTable(in: db)
        try input(delivery: "startNow", status: "admitted", in: db)
        XCTAssertEqual(collect().busy.map(\.id), ["session"])
        XCTAssertTrue(collect().activities.isEmpty)
        XCTAssertTrue(collect(running: false).busy.isEmpty)

        for delivery in ["queue", "guide"] {
            try input(delivery: delivery, status: "admitted", in: db)
            XCTAssertTrue(collect().busy.isEmpty, delivery)
            XCTAssertEqual(collect().activities.first?.phase, "ended")
        }
        // Promotion time matters when the user queued the input well before the previous turn ended.
        try input(delivery: "queue", status: "promoted", in: db, created: now - 600)
        XCTAssertEqual(collect().busy.count, 1)
        XCTAssertTrue(collect().activities.isEmpty)
        for status in ["cancelled", "discarded", "failed"] {
            try input(delivery: "startNow", status: status, in: db)
            XCTAssertTrue(collect().busy.isEmpty, status)
            XCTAssertEqual(collect().activities.first?.phase, "ended")
        }

        try input(delivery: "startNow", status: "promoted", in: db)
        try db.execute("INSERT INTO turn_usage VALUES('session', 'next', 'running', ?, NULL)",
                       binds: [.real(now * 1_000)])
        try message(#"{"role":"user","semantics":{"origin":"real_user"},"anchor":{"turnId":"next"}}"#, in: db)
        XCTAssertEqual(collect().busy.count, 1)
        XCTAssertTrue(collect().activities.isEmpty)
        try db.execute("UPDATE turn_usage SET status = 'completed', completed_at = ? WHERE turn_id = 'next'",
                       binds: [.real(now * 1_000)])
        XCTAssertTrue(collect().busy.isEmpty)
        XCTAssertEqual(collect().activities.first?.id, "session:ended:next")
        XCTAssertEqual(collect(running: false).activities.first?.phase, "ended")
    }

    func testInputDoesNotReviveExistingMessageOrStaleAdmission() throws {
        let db = try database()
        try inputTable(in: db)
        try input(delivery: "startNow", status: "admitted", in: db, created: now - 600)
        XCTAssertTrue(collect().busy.isEmpty)
        try input(delivery: "queue", status: "promoted", in: db)
        try message(#"{"role":"user","anchor":{"turnId":"previous"}}"#, in: db)
        XCTAssertTrue(collect().busy.isEmpty, "An input status update cannot reopen an already handled message")
        XCTAssertEqual(collect().activities.first?.phase, "ended")
        try input(delivery: "startNow", status: "admitted", in: db, session: "sess_subagent_child")
        XCTAssertTrue(collect().busy.isEmpty)
    }

    func testRunningTurnRemainsAuthoritativeWithOnlyRuntimeMessages() throws {
        let db = try database()
        try db.execute("UPDATE turn_usage SET status = 'running', completed_at = NULL")
        try message(#"{"role":"user","synthetic":true,"semantics":{"origin":"agent_runtime"}}"#, in: db)
        XCTAssertEqual(collect().busy.count, 1)
        XCTAssertTrue(collect().activities.isEmpty)
        XCTAssertTrue(collect(running: false).busy.isEmpty)
        try db.execute("UPDATE turn_usage SET started_at = ?", binds: [.real((now - 10_801) * 1_000)])
        XCTAssertTrue(collect().busy.isEmpty, "A stale running row is not renewed by a runtime reminder")
    }
}
