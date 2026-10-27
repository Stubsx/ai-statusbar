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

public struct UsageSpeedData: Codable, Hashable, Sendable {
    public let recent: [UsageRequest]
    public let models: [ModelUsageSpeed]

    public init(recent: [UsageRequest], models: [ModelUsageSpeed]) {
        self.recent = recent
        self.models = models
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
        return UsageSpeedData(recent: requests, models: summarize(requests))
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
