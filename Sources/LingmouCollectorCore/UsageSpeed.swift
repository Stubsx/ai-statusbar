import CryptoKit
import Foundation

public struct UsageRequest: Codable, Hashable, Sendable {
    public let id: String
    public let tool: String
    public let model: String
    public let sessionId: String?
    public let startedAt: TimeInterval?
    public let firstTokenAt: TimeInterval?
    public let finishedAt: TimeInterval
    public let outputTokens: Int
    public let metricKind: String?

    public init(
        id: String, tool: String, model: String, sessionId: String? = nil,
        startedAt: TimeInterval? = nil, firstTokenAt: TimeInterval? = nil,
        finishedAt: TimeInterval, outputTokens: Int, metricKind: String? = nil
    ) {
        self.id = id
        self.tool = tool
        self.model = model
        self.sessionId = sessionId
        self.startedAt = startedAt
        self.firstTokenAt = firstTokenAt
        self.finishedAt = finishedAt
        self.outputTokens = outputTokens
        self.metricKind = metricKind
    }

    /// Local request start to first token; unavailable or inconsistent clocks stay unknown.
    public var timeToFirstToken: TimeInterval? {
        guard let startedAt, let firstTokenAt,
            startedAt.isFinite, firstTokenAt.isFinite, finishedAt.isFinite,
            startedAt <= firstTokenAt, firstTokenAt <= finishedAt
        else { return nil }
        return firstTokenAt - startedAt
    }

    public var generationDuration: TimeInterval? {
        guard let firstTokenAt, finishedAt > firstTokenAt else { return nil }
        return finishedAt - firstTokenAt
    }

    public var averageDuration: TimeInterval? {
        guard let startedAt, finishedAt > startedAt else { return nil }
        return finishedAt - startedAt
    }

    public var generationTps: Double? {
        generationDuration.map { Double(outputTokens) / $0 }
    }

    public var averageTps: Double? {
        averageDuration.map { Double(outputTokens) / $0 }
    }
}

public struct ModelUsageSpeed: Codable, Hashable, Sendable {
    public let model: String
    public let generationTps: Double?
    public let averageTps: Double?
    public let generationSamples: Int
    public let averageSamples: Int

    public init(
        model: String, generationTps: Double?, averageTps: Double?,
        generationSamples: Int, averageSamples: Int
    ) {
        self.model = model
        self.generationTps = generationTps
        self.averageTps = averageTps
        self.generationSamples = generationSamples
        self.averageSamples = averageSamples
    }
}

public struct SessionUsageSpeed: Codable, Hashable, Sendable {
    public let tool: String
    public let sessionId: String
    public let tps: Double?
    public let metricKind: String
    public let speedSamples: Int
    public let firstTokenSeconds: Double?
    public let firstTokenSamples: Int
    public let requestCount: Int
    public let latest: UsageRequest
}

public struct UsageSpeedData: Codable, Hashable, Sendable {
    public let recent: [UsageRequest]
    public let models: [ModelUsageSpeed]
    public let sessions: [SessionUsageSpeed]?

    public init(recent: [UsageRequest], models: [ModelUsageSpeed], sessions: [SessionUsageSpeed]? = nil) {
        self.recent = recent
        self.models = models
        self.sessions = sessions
    }
}

struct UsageSpeedStore {
    static func createSchema(database: SQLiteDatabase) throws {
        try database.execute(
            """
            CREATE TABLE IF NOT EXISTS requests(
                id TEXT PRIMARY KEY, tool TEXT, model TEXT,
                started_at REAL, first_token_at REAL, finished_at REAL,
                output_tokens INT, created_at REAL)
            """)
        if !(try database.columns(in: "requests")).contains("session_id") {
            try database.execute("ALTER TABLE requests ADD COLUMN session_id TEXT")
        }
        if !(try database.columns(in: "requests")).contains("metric_kind") {
            try database.execute("ALTER TABLE requests ADD COLUMN metric_kind TEXT")
        }
        try database.execute(
            "CREATE INDEX IF NOT EXISTS requests_finished ON requests(finished_at DESC)")
        try database.execute(
            "CREATE INDEX IF NOT EXISTS requests_session ON requests(tool, session_id, finished_at DESC, id)")
        try database.execute(
            "CREATE TABLE IF NOT EXISTS request_exclusions(id TEXT PRIMARY KEY, finished_at REAL)")
    }

    static func identifier(tool: String, source: String) -> String {
        let digest = SHA256.hash(data: Data("\(tool):\(source)".utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    static func add(_ request: UsageRequest, database: SQLiteDatabase) throws {
        guard request.outputTokens > 0,
            request.generationDuration != nil || request.averageDuration != nil
        else { return }
        try database.execute(
            """
            INSERT INTO requests(
                id, tool, model, session_id, started_at, first_token_at, finished_at,
                output_tokens, created_at, metric_kind)
            SELECT ?,?,?,?,?,?,?,?,?,?
            WHERE NOT EXISTS(SELECT 1 FROM request_exclusions WHERE id=?)
            ON CONFLICT(id) DO UPDATE SET
                session_id=COALESCE(requests.session_id, excluded.session_id),
                metric_kind=COALESCE(requests.metric_kind, excluded.metric_kind)
            """,
            binds: [
                .text(request.id), .text(request.tool), .text(request.model),
                request.sessionId.map(SQLiteBind.text) ?? .null,
                request.startedAt.map(SQLiteBind.real) ?? .null,
                request.firstTokenAt.map(SQLiteBind.real) ?? .null,
                .real(request.finishedAt), .integer(Int64(request.outputTokens)),
                .real(Date().timeIntervalSince1970),
                request.metricKind.map(SQLiteBind.text) ?? .null, .text(request.id),
            ])
    }

    static func prune(database: SQLiteDatabase, retentionDays: Int, now: TimeInterval) throws {
        guard retentionDays > 0 else { return }
        let cutoff = now - TimeInterval(retentionDays * 86_400)
        try database.execute(
            "DELETE FROM requests WHERE finished_at < ?", binds: [.real(cutoff)])
        try database.execute(
            "DELETE FROM request_exclusions WHERE finished_at < ?", binds: [.real(cutoff)])
    }

    static func load(database: SQLiteDatabase) throws -> UsageSpeedData {
        let rows = try database.query(
            """
            SELECT id, tool, model, session_id, started_at, first_token_at, finished_at,
                output_tokens, metric_kind
            FROM requests ORDER BY finished_at DESC LIMIT 1000
            """)
        let requests = rows.compactMap { row -> UsageRequest? in
            guard let id = row["id"]?.string, let tool = row["tool"]?.string,
                let finishedAt = row["finished_at"]?.double
            else { return nil }
            return UsageRequest(
                id: id, tool: tool, model: row["model"]?.string ?? "",
                sessionId: row["session_id"]?.string,
                startedAt: row["started_at"]?.double,
                firstTokenAt: row["first_token_at"]?.double,
                finishedAt: finishedAt, outputTokens: row["output_tokens"]?.int ?? 0,
                metricKind: row["metric_kind"]?.string)
        }
        return UsageSpeedData(recent: requests, models: summarize(requests),
                              sessions: try summarizeSessions(database: database))
    }

    private static func summarizeSessions(database: SQLiteDatabase) throws -> [SessionUsageSpeed] {
        // Aggregate all retained records in SQLite, independent of the 1,000-row detail cap.
        // Codex whole-turn legacy records are excluded just as they are in conversation rows.
        let generation = "first_token_at >= started_at AND finished_at > first_token_at"
            + " OR started_at IS NULL AND finished_at > first_token_at"
        let average = "finished_at > started_at"
        let firstToken = "first_token_at >= started_at AND finished_at >= first_token_at"
        let rows = try database.query(
            """
            WITH ranked AS (
                SELECT *, ROW_NUMBER() OVER (
                    PARTITION BY tool, session_id ORDER BY finished_at DESC, id) AS latest_rank
                FROM requests
                WHERE session_id IS NOT NULL AND session_id != '' AND output_tokens > 0
                    AND (tool != 'codex' OR metric_kind = 'effective')
            ), summary AS (
                SELECT tool, session_id, COUNT(*) AS request_count,
                    SUM(CASE WHEN (\(generation)) THEN output_tokens ELSE 0 END) AS generation_tokens,
                    SUM(CASE WHEN (\(generation)) THEN finished_at-first_token_at ELSE 0 END) AS generation_seconds,
                    SUM(CASE WHEN (\(generation)) THEN 1 ELSE 0 END) AS generation_samples,
                    SUM(CASE WHEN \(average) THEN output_tokens ELSE 0 END) AS average_tokens,
                    SUM(CASE WHEN \(average) THEN finished_at-started_at ELSE 0 END) AS average_seconds,
                    SUM(CASE WHEN \(average) THEN 1 ELSE 0 END) AS average_samples,
                    SUM(CASE WHEN \(firstToken) THEN first_token_at-started_at ELSE 0 END) AS first_token_seconds,
                    SUM(CASE WHEN \(firstToken) THEN 1 ELSE 0 END) AS first_token_samples,
                    MAX(CASE WHEN latest_rank=1 THEN id END) AS latest_id
                FROM ranked GROUP BY tool, session_id
            )
            SELECT s.*, r.id, r.model, r.started_at, r.first_token_at, r.finished_at,
                r.output_tokens, r.metric_kind
            FROM summary s JOIN requests r ON r.id=s.latest_id
            ORDER BY s.tool, s.session_id
            """)
        return rows.compactMap { row in
            guard let tool = row["tool"]?.string, let sessionId = row["session_id"]?.string,
                let id = row["id"]?.string, let finishedAt = row["finished_at"]?.double
            else { return nil }
            let generationSeconds = row["generation_seconds"]?.double ?? 0
            let averageSeconds = row["average_seconds"]?.double ?? 0
            let useGeneration = generationSeconds > 0
            let seconds = useGeneration ? generationSeconds : averageSeconds
            let tokens = row[useGeneration ? "generation_tokens" : "average_tokens"]?.double ?? 0
            let firstSamples = row["first_token_samples"]?.int ?? 0
            return SessionUsageSpeed(
                tool: tool, sessionId: sessionId, tps: seconds > 0 ? tokens / seconds : nil,
                metricKind: tool == "codex" ? "effective" : (useGeneration ? "generation" : "average"),
                speedSamples: row[useGeneration ? "generation_samples" : "average_samples"]?.int ?? 0,
                firstTokenSeconds: firstSamples > 0
                    ? (row["first_token_seconds"]?.double ?? 0) / Double(firstSamples) : nil,
                firstTokenSamples: firstSamples, requestCount: row["request_count"]?.int ?? 0,
                latest: UsageRequest(id: id, tool: tool, model: row["model"]?.string ?? "",
                    sessionId: sessionId, startedAt: row["started_at"]?.double,
                    firstTokenAt: row["first_token_at"]?.double, finishedAt: finishedAt,
                    outputTokens: row["output_tokens"]?.int ?? 0,
                    metricKind: row["metric_kind"]?.string))
        }
    }

    private static func summarize(_ requests: [UsageRequest]) -> [ModelUsageSpeed] {
        let grouped = Dictionary(grouping: requests, by: { UsageSync.normalizedModelKey($0.model) })
        return grouped.map { model, values in
            let recent = values.prefix(20)
            let generation = recent.filter { $0.generationDuration != nil }
            let average = recent.filter { $0.averageDuration != nil }
            let generationTps = weightedSpeed(generation, duration: \.generationDuration)
            let averageTps = weightedSpeed(average, duration: \.averageDuration)
            return ModelUsageSpeed(
                model: model, generationTps: generationTps, averageTps: averageTps,
                generationSamples: generation.count, averageSamples: average.count)
        }.sorted {
            ($0.generationTps ?? $0.averageTps ?? 0) > ($1.generationTps ?? $1.averageTps ?? 0)
        }
    }

    private static func weightedSpeed(
        _ requests: [UsageRequest], duration: KeyPath<UsageRequest, TimeInterval?>
    ) -> Double? {
        let seconds = requests.reduce(0.0) { $0 + ($1[keyPath: duration] ?? 0) }
        guard seconds > 0, !requests.isEmpty else { return nil }
        return Double(requests.reduce(0) { $0 + $1.outputTokens }) / seconds
    }
}

public enum UsageSpeedMaintenance {
    public static func clear(homeDirectory: String) throws {
        let directory = homeDirectory + "/.ai-statusbar"
        try FileManager.default.createDirectory(
            atPath: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        let path = directory + "/usage.sqlite"
        let database = try SQLiteDatabase(path: path)
        try UsageSpeedStore.createSchema(database: database)
        try database.execute(
            "CREATE TABLE IF NOT EXISTS speed_backfills(path TEXT PRIMARY KEY)")
        try database.execute("BEGIN IMMEDIATE")
        do {
            if !(try database.query(
                "SELECT name FROM sqlite_master WHERE type='table' AND name='offsets'"
            ).isEmpty) {
                try database.execute(
                    "INSERT OR IGNORE INTO speed_backfills(path) SELECT path FROM offsets")
            }
            try database.execute(
                "INSERT OR IGNORE INTO request_exclusions SELECT id, finished_at FROM requests")
            try database.execute("DELETE FROM requests")
            try database.execute("COMMIT")
        } catch {
            try? database.execute("ROLLBACK")
            throw error
        }
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
    }
}
