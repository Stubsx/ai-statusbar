import Foundation
import XCTest
@testable import LingmouCollectorCore

final class TaskActivityTests: XCTestCase {
    private let now: TimeInterval = 2_000_000_000
    private let sessionID = "12345678-1234-1234-1234-123456789abc"

    private func collect(_ lines: [String], running: Bool = true) throws -> RawToolState {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        let directory = home.appendingPathComponent(".codex/sessions/2026/01/01")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let session = directory.appendingPathComponent("rollout-2026-01-01T00-00-00-\(sessionID).jsonl")
        try (lines.joined(separator: "\n") + "\n").write(to: session, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: now)],
                                             ofItemAtPath: session.path)
        let index = home.appendingPathComponent(".codex/session_index.jsonl")
        try """
        {"id":"\(sessionID)","thread_name":"测试任务","updated_at":"2033-05-18T03:33:20Z"}
        """.write(to: index, atomically: true, encoding: .utf8)
        let processes = ProcessSupport { _, arguments, _ in
            arguments.contains("args=") && running ? "/usr/local/bin/codex\n" : ""
        }
        return CodexCollector(environment: CollectorEnvironment(homeDirectory: home.path, now: now),
                              settings: CollectorSettings(), files: FileSupport(), processes: processes).collect().cli
    }

    private func lifecycle(_ type: String, seconds: Int = 0) -> String {
        """
        {"timestamp":"2033-05-18T03:33:\(String(format: "%02d", 10 + seconds))Z","type":"event_msg","payload":{"type":"\(type)"}}
        """
    }

    func testExplicitEndClosesUnresolvedCallsAndRetainsTimestamp() throws {
        let result = try collect([
            lifecycle("task_started"),
            #"{"type":"response_item","payload":{"type":"function_call","name":"exec_command","call_id":"one"}}"#,
            lifecycle("task_complete", seconds: 5),
        ])
        XCTAssertTrue(result.busy.isEmpty)
        XCTAssertEqual(result.activities.first?.phase, "ended")
        XCTAssertEqual(result.activities.first?.updatedAt, now - 5)
        XCTAssertEqual(result.activities.first?.evidence, "explicit")
    }

    func testAbortIsNeverSuccessfulCompletionEvenAfterProcessExits() throws {
        let result = try collect([lifecycle("task_started"), lifecycle("turn_aborted", seconds: 5)], running: false)
        XCTAssertTrue(result.busy.isEmpty)
        XCTAssertEqual(result.activities.first?.phase, "interrupted")
    }

    func testInputRequestWaitsUntilMatchingResponse() throws {
        let call = #"{"timestamp":"2033-05-18T03:33:12Z","type":"response_item","payload":{"type":"function_call","name":"request_user_input","call_id":"question"}}"#
        let waiting = try collect([lifecycle("task_started"), call])
        XCTAssertTrue(waiting.busy.isEmpty)
        XCTAssertEqual(waiting.activities.first?.phase, "waiting_input")
        let resumed = try collect([
            lifecycle("task_started"), call,
            #"{"type":"response_item","payload":{"type":"function_call_output","call_id":"question","output":"回答"}}"#,
        ])
        XCTAssertEqual(resumed.busy.count, 1)
        XCTAssertEqual(resumed.activities.first?.phase, "working")
    }

    func testRegularPendingCallDoesNotImplyApproval() throws {
        let result = try collect([
            lifecycle("task_started"),
            #"{"type":"response_item","payload":{"type":"function_call","name":"exec_command","call_id":"one"}}"#,
        ])
        XCTAssertEqual(result.busy.count, 1)
        XCTAssertEqual(result.activities.first?.phase, "working")
    }

    func testNewTurnClearsPreviousInputRequest() throws {
        let result = try collect([
            lifecycle("task_started"),
            #"{"type":"response_item","payload":{"type":"function_call","name":"request_user_input","call_id":"old"}}"#,
            lifecycle("turn_aborted", seconds: 2), lifecycle("task_started", seconds: 3),
        ])
        XCTAssertEqual(result.activities.first?.phase, "working")
    }

    func testEndedEventIdentityDoesNotChangeOnRepeatedCollection() throws {
        let lines = [lifecycle("task_started"), lifecycle("task_complete", seconds: 2)]
        XCTAssertEqual(try collect(lines).activities.first?.id, try collect(lines).activities.first?.id)
    }

    func testMalformedCodexLogIsHealthFailure() throws {
        XCTAssertNotNil(try collect(["{invalid-json}"]).sourceError)
    }

    func testClaudeExplicitEndAndMalformedLog() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        let directory = home.appendingPathComponent(".claude/projects/sample")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let path = directory.appendingPathComponent("session.jsonl")
        try Data(#"{"timestamp":"2033-05-18T03:33:15Z","type":"assistant","message":{"stop_reason":"end_turn","content":[{"type":"text"}]}}"#.utf8).write(to: path)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: now)], ofItemAtPath: path.path)
        let collectors = LocalCollectors(environment: CollectorEnvironment(homeDirectory: home.path, now: now),
                                          settings: CollectorSettings(), files: FileSupport(),
                                          processes: ProcessSupport { _, _, _ in "" })
        let ended = collectors.claude()
        XCTAssertTrue(ended.busy.isEmpty)
        XCTAssertEqual(ended.activities.first?.phase, "ended")
        XCTAssertEqual(ended.activities.first?.updatedAt, now - 5)
        try Data("invalid".utf8).write(to: path)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: now)], ofItemAtPath: path.path)
        XCTAssertNotNil(collectors.claude().sourceError)
        XCTAssertTrue(collectors.claude().activities.isEmpty)
    }

    func testFullActiveListAndOldContractCoexist() throws {
        let items = (1...9).map { BusyItem(id: String($0), title: "任务") }
        let value = ToolStatus(key: "test", letter: "T", name: "测试", state: "busy", busyItems: items,
                               detail: "", latestTitle: nil, latestAge: nil, quota: nil, activeItems: items)
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: encoder.encode(value)) as? [String: Any])
        XCTAssertEqual(json["busy_count"] as? Int, 9)
        XCTAssertEqual((json["busy_items"] as? [Any])?.count, 5)
        XCTAssertEqual((json["active_items"] as? [Any])?.count, 9)
        let old = Data(#"{"key":"test","letter":"T","name":"测试","state":"idle","busy_count":0,"busy_items":[],"detail":""}"#.utf8)
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let decoded = try decoder.decode(ToolStatus.self, from: old)
        XCTAssertNil(decoded.activities)
        XCTAssertNil(decoded.activeItems)
    }

    func testHealthDoesNotConfuseMissingQuotaWithLoggedOut() {
        let environment = CollectorEnvironment(homeDirectory: "/nonexistent-lingmou-fixture", now: now)
        var settings = CollectorSettings()
        settings.onlineQuota = true
        let health = ToolSupport.health(for: "codex-ide", raw: RawToolState(), quota: nil,
                                        environment: environment, settings: settings)
        XCTAssertEqual(health.state, "not_detected")
        XCTAssertEqual(health.quotaState, "unavailable")
        let stale = ToolQuota(plan: nil, windows: [QuotaWindow(kind: "primary", label: "五小时",
                                                             usedPercent: 80, resetsAt: Int(now + 1_000))],
                              updatedAt: Int(now - 1_000))
        XCTAssertEqual(ToolSupport.health(for: "codex-ide", raw: RawToolState(), quota: stale,
                                          environment: environment, settings: settings).quotaState, "stale")
    }
}
