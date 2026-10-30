import Foundation
import XCTest

@testable import LingmouCollectorCore

final class UsageSpeedTests: XCTestCase {
    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func write(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    private func touch(_ url: URL, at timestamp: TimeInterval) throws {
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: timestamp)], ofItemAtPath: url.path)
    }

    func testWeightedModelSpeedUsesTotalTokensAndDurations() throws {
        let home = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        let database = try SQLiteDatabase(path: home.appendingPathComponent("speed.sqlite").path)
        try UsageSpeedStore.createSchema(database: database)
        try UsageSpeedStore.add(
            UsageRequest(
                id: "a", tool: "zcode", model: "GLM-5.3", startedAt: 100,
                firstTokenAt: 105, finishedAt: 115, outputTokens: 100), database: database)
        try UsageSpeedStore.add(
            UsageRequest(
                id: "b", tool: "zcode", model: "glm-5.3", startedAt: 200,
                finishedAt: 240, outputTokens: 200), database: database)
        try UsageSpeedStore.add(
            UsageRequest(
                id: "invalid", tool: "zcode", model: "glm-5.3", startedAt: 300,
                finishedAt: 300, outputTokens: 900), database: database)

        let speed = try UsageSpeedStore.load(database: database)
        let model = try XCTUnwrap(speed.models.first)
        XCTAssertEqual(model.generationTps, 10)
        XCTAssertEqual(try XCTUnwrap(model.averageTps), 300.0 / 55.0, accuracy: 0.0001)
        XCTAssertEqual(model.generationSamples, 1)
        XCTAssertEqual(model.averageSamples, 2)
        XCTAssertEqual(speed.recent.count, 2)
    }

    func testSessionAveragesUseAllRetainedRecordsAndSeparateTimingSamples() throws {
        let home = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        let database = try SQLiteDatabase(path: home.appendingPathComponent("speed.sqlite").path)
        try UsageSpeedStore.createSchema(database: database)
        let requests = [
            UsageRequest(id: "first", tool: "zcode", model: "glm", sessionId: "long",
                startedAt: 100, firstTokenAt: 101, finishedAt: 102, outputTokens: 100),
            UsageRequest(id: "second", tool: "zcode", model: "glm", sessionId: "long",
                startedAt: 200, firstTokenAt: 203, finishedAt: 212, outputTokens: 100),
            UsageRequest(id: "no-first-token", tool: "zcode", model: "glm", sessionId: "long",
                startedAt: 300, finishedAt: 310, outputTokens: 50),
            UsageRequest(id: "other-tool", tool: "kimi", model: "kimi", sessionId: "long",
                startedAt: 400, firstTokenAt: 401, finishedAt: 403, outputTokens: 200),
            UsageRequest(id: "legacy", tool: "codex", model: "gpt", sessionId: "codex-session",
                startedAt: 500, finishedAt: 600, outputTokens: 10000),
            UsageRequest(id: "effective", tool: "codex", model: "gpt", sessionId: "codex-session",
                startedAt: 500, firstTokenAt: 501, finishedAt: 505, outputTokens: 40,
                metricKind: "effective"),
        ]
        for request in requests { try UsageSpeedStore.add(request, database: database) }
        for index in 0..<1001 {
            try UsageSpeedStore.add(UsageRequest(id: "background-\(index)", tool: "zcode",
                model: "glm", sessionId: "background", startedAt: Double(1000 + index),
                finishedAt: Double(1001 + index), outputTokens: 1), database: database)
        }
        let speed = try UsageSpeedStore.load(database: database)
        XCTAssertEqual(speed.recent.count, 1000)
        XCTAssertFalse(speed.recent.contains { $0.sessionId == "long" })
        let sessions = try XCTUnwrap(speed.sessions)
        let long = try XCTUnwrap(sessions.first { $0.tool == "zcode" && $0.sessionId == "long" })
        XCTAssertEqual(long.tps, 20, "Weight by total tokens / duration, not by request TPS")
        XCTAssertEqual(long.metricKind, "generation")
        XCTAssertEqual(long.speedSamples, 2, "Do not mix whole-request fallback into generation TPS")
        XCTAssertEqual(long.firstTokenSeconds, 2)
        XCTAssertEqual(long.firstTokenSamples, 2, "Missing timing is not a zero-latency sample")
        XCTAssertEqual(long.requestCount, 3)
        XCTAssertEqual(long.latest.id, "no-first-token", "Latest request remains available beyond detail cap")
        let kimi = try XCTUnwrap(sessions.first { $0.tool == "kimi" })
        XCTAssertEqual(kimi.tps, 100, "Identical session IDs in different tools stay separate")
        let codex = try XCTUnwrap(sessions.first { $0.tool == "codex" })
        XCTAssertEqual(codex.requestCount, 1, "Exclude legacy Codex whole-turn averages")
        XCTAssertEqual(codex.tps, 10)
        XCTAssertEqual(codex.metricKind, "effective")
        let fallback = try XCTUnwrap(sessions.first { $0.sessionId == "background" })
        XCTAssertEqual(fallback.tps, 1)
        XCTAssertEqual(fallback.speedSamples, 1001)
        XCTAssertEqual(fallback.metricKind, "average")
        XCTAssertNil(fallback.firstTokenSeconds)
        XCTAssertEqual(fallback.firstTokenSamples, 0)
        try UsageSpeedStore.prune(database: database, retentionDays: 1, now: 90_000)
        XCTAssertEqual(try UsageSpeedStore.load(database: database).sessions?.count, 0)
    }

    func testZcodeReadsGenerationAndAverageSpeedWithoutDoubleCounting() throws {
        let home = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        let now = try XCTUnwrap(DateSupport.timestamp("2033-05-18T03:33:20Z"))
        let directory = home.appendingPathComponent(".zcode/cli/db")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let zcode = try SQLiteDatabase(path: directory.appendingPathComponent("db.sqlite").path)
        try zcode.execute(
            """
            CREATE TABLE model_usage(
                id TEXT PRIMARY KEY, session_id TEXT, model_id TEXT, status TEXT, started_at INTEGER,
                first_token_at INTEGER, completed_at INTEGER, input_tokens INTEGER,
                output_tokens INTEGER, cache_read_input_tokens INTEGER)
            """)
        func insert(_ id: String, started: TimeInterval, first: TimeInterval, finished: TimeInterval) throws {
            try zcode.execute(
                "INSERT INTO model_usage VALUES(?,'session-z','GLM-5.3','completed',?,?,?,100,40,0)",
                binds: [
                    .text(id), .integer(Int64(started * 1_000)),
                    .integer(Int64(first * 1_000)), .integer(Int64(finished * 1_000)),
                ])
        }
        try insert("current", started: now - 60, first: now - 50, finished: now - 40)
        try insert("expired", started: now - 100 * 86_400,
                   first: now - 100 * 86_400 + 1, finished: now - 100 * 86_400 + 2)

        let collector = UsageCollector(
            environment: CollectorEnvironment(homeDirectory: home.path, now: now),
            files: FileSupport())
        let first = try XCTUnwrap(collector.collect())
        let request = try XCTUnwrap(first.speed?.recent.first)
        XCTAssertEqual(request.generationTps, 4)
        XCTAssertEqual(request.averageTps, 2)
        XCTAssertEqual(request.timeToFirstToken, 10)
        XCTAssertEqual(request.sessionId, "session-z")
        XCTAssertEqual(first.speed?.recent.count, 1, "90 天前的请求明细应被清理")
        XCTAssertEqual(first.tools["zcode"]?.output, 40)
        let local = try SQLiteDatabase(
            path: home.appendingPathComponent(".ai-statusbar/usage.sqlite").path)
        try local.execute("DELETE FROM requests")
        let second = try XCTUnwrap(collector.collect())
        XCTAssertEqual(second.speed?.recent.count, 1, "已有用量快照也应补录速度，但不重复计数")
        XCTAssertEqual(second.tools["zcode"], first.tools["zcode"])
        try UsageSpeedMaintenance.clear(homeDirectory: home.path)
        let cleared = try XCTUnwrap(collector.collect())
        XCTAssertEqual(cleared.speed?.recent.count, 0, "清空后不得重新导入同一条旧请求")
        XCTAssertEqual(cleared.tools["zcode"], first.tools["zcode"])
    }

    func testCodexAndKimiProduceOnlyRequestAverageSpeed() throws {
        let home = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        let now = try XCTUnwrap(DateSupport.timestamp("2033-05-18T03:33:20Z"))
        let codex = home.appendingPathComponent(
            ".codex/sessions/2033/05/18/rollout-test-12345678-1234-1234-1234-123456789abc.jsonl")
        try write(
            """
            {"timestamp":"2033-05-18T03:33:00Z","type":"turn_context","payload":{"turn_id":"turn-1","model":"gpt-5.6"}}
            {"timestamp":"2033-05-18T03:33:20Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":10,"cached_input_tokens":0,"output_tokens":40}}}}
            {"timestamp":"2033-05-18T03:33:20Z","type":"event_msg","payload":{"type":"task_complete","turn_id":"turn-1","started_at":\(now - 20),"completed_at":\(now),"duration_ms":20000,"time_to_first_token_ms":5000}}
            """ + "\n", to: codex)
        try touch(codex, at: now)
        let kimi = home.appendingPathComponent(
            ".kimi-code/sessions/project/session/agents/main/wire.jsonl")
        try write(
            """
            {"type":"turn.prompt","time":\(Int64((now - 10) * 1_000))}
            {"type":"context.append_loop_event","event":{"type":"step.begin","uuid":"step-1","turnId":"1"},"time":\(Int64((now - 10) * 1_000))}
            {"type":"usage.record","time":\(Int64(now * 1_000)),"model":"k3","usage":{"inputOther":5,"output":10,"inputCacheRead":0}}
            {"type":"context.append_loop_event","event":{"type":"step.end","uuid":"step-1","turnId":"1","usage":{"inputOther":5,"output":10,"inputCacheRead":0},"llmStreamDurationMs":4000},"time":\(Int64(now * 1_000))}
            """ + "\n", to: kimi)
        try touch(kimi, at: now)

        let data = try XCTUnwrap(UsageCollector(
            environment: CollectorEnvironment(homeDirectory: home.path, now: now),
            files: FileSupport()).collect())
        let codexRequest = try XCTUnwrap(data.speed?.recent.first {
            $0.tool == "codex" && $0.metricKind == "effective"
        })
        XCTAssertEqual(codexRequest.averageTps, 2)
        XCTAssertEqual(codexRequest.timeToFirstToken, 5)
        XCTAssertEqual(try XCTUnwrap(codexRequest.generationTps), 40.0 / 15.0, accuracy: 0.0001)
        XCTAssertEqual(codexRequest.sessionId, "12345678-1234-1234-1234-123456789abc")
        let kimiRequest = try XCTUnwrap(data.speed?.recent.first { $0.tool == "kimi" })
        XCTAssertEqual(kimiRequest.averageTps, 1)
        XCTAssertEqual(kimiRequest.timeToFirstToken, 6)
        XCTAssertEqual(kimiRequest.generationTps, 2.5)
        XCTAssertEqual(kimiRequest.sessionId, "session")
        XCTAssertEqual(data.tools["kimi"]?.output, 10, "step.end 只补充速度，不得重复计入用量")
        XCTAssertEqual(data.tools["codex"]?.output, 40, "task_complete 不得重复计入用量")
    }

    func testCodexSpeedBackfillDoesNotDoubleCountDailyUsage() throws {
        let home = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        let now = try XCTUnwrap(DateSupport.timestamp("2033-05-18T03:33:20Z"))
        let log = home.appendingPathComponent(
            ".codex/sessions/2033/05/18/rollout-test-12345678-1234-1234-1234-123456789abc.jsonl")
        let text = """
            {"timestamp":"2033-05-18T03:33:00Z","type":"turn_context","payload":{"turn_id":"turn-1","model":"gpt"}}
            {"timestamp":"2033-05-18T03:33:20Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":10,"output_tokens":40}}}}
            {"timestamp":"2033-05-18T03:33:20Z","type":"event_msg","payload":{"type":"task_complete","turn_id":"turn-1","started_at":\(now - 20),"completed_at":\(now),"duration_ms":20000,"time_to_first_token_ms":5000}}
            """ + "\n"
        try write(text, to: log)
        try touch(log, at: now)
        let databasePath = home.appendingPathComponent(".ai-statusbar/usage.sqlite")
        try FileManager.default.createDirectory(
            at: databasePath.deletingLastPathComponent(), withIntermediateDirectories: true)
        let database = try SQLiteDatabase(path: databasePath.path)
        try database.execute(
            "CREATE TABLE daily(date TEXT, tool TEXT, model TEXT, input INT, output INT, cache INT)")
        try database.execute("INSERT INTO daily VALUES('2033-05-18','codex','gpt',10,40,0)")
        try database.execute(
            """
            CREATE TABLE offsets(path TEXT PRIMARY KEY, offset INT, mtime REAL, last_key TEXT,
                last_model TEXT, last_request_id TEXT, last_request_started REAL, last_request_output INT)
            """)
        try database.execute(
            "INSERT INTO offsets VALUES(?,?,?,NULL,'gpt','turn-1',?,40)",
            binds: [
                .text(log.path), .integer(Int64(Data(text.utf8).count)), .real(now), .real(now - 20),
            ])

        let collector = UsageCollector(
            environment: CollectorEnvironment(homeDirectory: home.path, now: now),
            files: FileSupport())
        let first = try XCTUnwrap(collector.collect())
        XCTAssertEqual(first.tools["codex"]?.output, 40)
        XCTAssertEqual(first.speed?.recent.filter { $0.metricKind == "effective" }.count, 1)
        let second = try XCTUnwrap(collector.collect())
        XCTAssertEqual(second.tools["codex"]?.output, 40)
        XCTAssertEqual(second.speed?.recent.filter { $0.metricKind == "effective" }.count, 1)
    }

    func testCodexTaskCompleteWithoutTTFTDoesNotProduceSpeed() throws {
        let state = UsageParseState()
        _ = UsageParsers.codex(
            #"{"timestamp":"1970-01-01T00:00:10Z","type":"turn_context","payload":{"turn_id":"turn-old","model":"gpt"}}"#,
            state)
        _ = UsageParsers.codex(
            #"{"timestamp":"1970-01-01T00:00:14Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":1,"output_tokens":8}}}}"#,
            state)
        let usage = try XCTUnwrap(UsageParsers.codex(
            #"{"type":"event_msg","payload":{"type":"task_complete","turn_id":"turn-old","started_at":10,"completed_at":14,"duration_ms":4000}}"#,
            state))
        XCTAssertEqual(usage.output, 8)
        XCTAssertNil(usage.requestStartedAt)
        XCTAssertNil(usage.firstTokenAt)
        XCTAssertNil(usage.metricKind)
        XCTAssertFalse(usage.countsTowardDaily)
    }

    func testKimiStepWithoutStreamDurationFallsBackToAverage() throws {
        let state = UsageParseState()
        _ = UsageParsers.kimi(
            #"{"type":"context.append_loop_event","event":{"type":"step.begin","uuid":"step-old"},"time":10000}"#,
            state)
        _ = UsageParsers.kimi(
            #"{"type":"usage.record","time":14000,"model":"k3","usage":{"inputOther":1,"output":10,"inputCacheRead":0}}"#,
            state)
        let usage = try XCTUnwrap(UsageParsers.kimi(
            #"{"type":"context.append_loop_event","event":{"type":"step.end","uuid":"step-old","usage":{"output":10}},"time":14000}"#,
            state))
        XCTAssertEqual(usage.timestamp, 14)
        XCTAssertEqual(usage.requestStartedAt, 10)
        XCTAssertNil(usage.firstTokenAt)
        XCTAssertFalse(usage.countsTowardDaily)
    }

    func testPermanentRetentionAndClearPreserveDailyUsage() throws {
        let home = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        let path = home.appendingPathComponent(".ai-statusbar/usage.sqlite")
        try FileManager.default.createDirectory(
            at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        let database = try SQLiteDatabase(path: path.path)
        try UsageSpeedStore.createSchema(database: database)
        try database.execute(
            "CREATE TABLE daily(date TEXT, tool TEXT, model TEXT, input INT, output INT, cache INT)")
        try database.execute("INSERT INTO daily VALUES('2033-01-01','codex','',1,2,3)")
        try UsageSpeedStore.add(
            UsageRequest(
                id: "old", tool: "codex", model: "gpt", startedAt: 10,
                finishedAt: 20, outputTokens: 10), database: database)
        try UsageSpeedStore.prune(database: database, retentionDays: 0, now: 10_000_000)
        XCTAssertEqual(try UsageSpeedStore.load(database: database).recent.count, 1)

        try UsageSpeedMaintenance.clear(homeDirectory: home.path)
        XCTAssertEqual(try UsageSpeedStore.load(database: database).recent.count, 0)
        XCTAssertEqual(try database.query("SELECT output FROM daily").first?["output"]?.int, 2)
        try UsageSpeedStore.add(
            UsageRequest(id: "old", tool: "codex", model: "gpt", startedAt: 30,
                         finishedAt: 40, outputTokens: 10), database: database)
        try UsageSpeedStore.add(
            UsageRequest(id: "new", tool: "codex", model: "gpt", startedAt: 40,
                         finishedAt: 50, outputTokens: 10), database: database)
        XCTAssertEqual(try UsageSpeedStore.load(database: database).recent.map(\.id), ["new"])
    }

    func testFirstTokenTimingRejectsMissingAndInconsistentClocks() {
        func latency(_ start: Double?, _ first: Double?, _ end: Double = 20) -> Double? {
            UsageRequest(id: "timing", tool: "zcode", model: "glm", startedAt: start,
                         firstTokenAt: first, finishedAt: end, outputTokens: 10).timeToFirstToken
        }
        XCTAssertEqual(latency(10, 10), 0)
        XCTAssertEqual(latency(10, 20), 10)
        XCTAssertNil(latency(nil, 15))
        XCTAssertNil(latency(10, nil))
        XCTAssertNil(latency(10, 9))
        XCTAssertNil(latency(10, 21))
        XCTAssertNil(latency(.nan, 15))
        XCTAssertNil(latency(10, .infinity))
        XCTAssertNil(latency(10, 15, .infinity))
    }

    func testDshSessionStatsProduceSessionSpeed() throws {
        let home = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        let now = try XCTUnwrap(DateSupport.timestamp("2033-05-18T03:33:20Z"))
        try write(
            """
            {"version":5,"record":{"identity":{"createdAt":2000000000000,"cwd":"/tmp/proj"},"rows":{
                "tokenUsage":{"val":{"totals":{"uncachedInputTokens":100,"outputTokens":20,"cacheReadTokens":40},
                    "last":{"turn":1,"step":2,"buckets":{"uncachedInputTokens":10,"outputTokens":20,"cacheReadTokens":5}}}},
                "sessionStats":{"val":{"turns":1,"steps":4,"llmMs":30000,"toolMs":5000,
                    "ttftMs":9000,"ttftSteps":3,"decodeMs":10000,"decodeTokens":2000}},
                "sessionListMetadata":{"val":{"lastPromptAt":2000000000000}}}}}
            """,
            to: home.appendingPathComponent(
                ".dsh/storages/session_projcache/sessions/session-speed.json"))
        let data = try XCTUnwrap(
            UsageCollector(
                environment: CollectorEnvironment(homeDirectory: home.path, now: now),
                files: FileSupport()
            ).collect())
        let session = try XCTUnwrap(
            data.speed?.sessions?.first { $0.tool == "dsh" && $0.sessionId == "session-speed" })
        XCTAssertEqual(try XCTUnwrap(session.tps), 200, accuracy: 0.0001)
        XCTAssertEqual(session.metricKind, "generation")
        XCTAssertEqual(session.speedSamples, 4)
        XCTAssertEqual(try XCTUnwrap(session.firstTokenSeconds), 3, accuracy: 0.0001)
        XCTAssertEqual(session.firstTokenSamples, 3)
        XCTAssertEqual(session.requestCount, 4)
        XCTAssertEqual(session.latest.outputTokens, 20)
        XCTAssertEqual(session.latest.finishedAt, 2_000_000_000)
        XCTAssertTrue(
            data.speed?.recent.allSatisfy { $0.tool != "dsh" } ?? true,
            "DSH 统计只进会话聚合，不进逐请求明细")
    }

    func testUsageDataDecodesWithoutSpeedField() throws {
        let json = """
            {"date":"今天","tools":{},"total":{"input":0,"output":0,"cache":0},
             "heatmap":[],"heatmax":0}
            """
        let data = try JSONDecoder().decode(UsageData.self, from: Data(json.utf8))
        XCTAssertNil(data.speed)
    }
}
