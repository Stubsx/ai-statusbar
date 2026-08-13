import Foundation

struct ParsedUsage: Equatable {
    let timestamp: TimeInterval
    let input: Int
    let output: Int
    let cache: Int
}

struct UsageParsers {
    static func codex(_ line: String) -> ParsedUsage? {
        guard line.contains("token_count"), let object = JSONValue.object(from: line),
            JSONValue.string(object["type"]) == "event_msg",
            let payload = object["payload"] as? JSONObject,
            JSONValue.string(payload["type"]) == "token_count",
            let timestamp = DateSupport.timestamp(object["timestamp"]),
            let info = payload["info"] as? JSONObject,
            let usage = info["last_token_usage"] as? JSONObject
        else { return nil }
        let input = JSONValue.int(usage["input_tokens"]) ?? 0
        let cache = JSONValue.int(usage["cached_input_tokens"]) ?? 0
        return ParsedUsage(
            timestamp: timestamp,
            input: max(0, input - cache),
            output: JSONValue.int(usage["output_tokens"]) ?? 0,
            cache: cache
        )
    }

    static func kimi(_ line: String) -> ParsedUsage? {
        guard line.contains("usage.record"), let object = JSONValue.object(from: line),
            JSONValue.string(object["type"]) == "usage.record",
            let milliseconds = JSONValue.double(object["time"]), milliseconds > 0,
            let usage = object["usage"] as? JSONObject
        else { return nil }
        return ParsedUsage(
            timestamp: milliseconds / 1_000,
            input: JSONValue.int(usage["inputOther"]) ?? 0,
            output: JSONValue.int(usage["output"]) ?? 0,
            cache: JSONValue.int(usage["inputCacheRead"]) ?? 0
        )
    }

    static func claude(_ line: String) -> ParsedUsage? {
        guard line.contains("\"usage\""), let object = JSONValue.object(from: line),
            let timestamp = DateSupport.timestamp(object["timestamp"]),
            let message = object["message"] as? JSONObject,
            let usage = message["usage"] as? JSONObject
        else { return nil }
        return ParsedUsage(
            timestamp: timestamp,
            input: JSONValue.int(usage["input_tokens"]) ?? 0,
            output: JSONValue.int(usage["output_tokens"]) ?? 0,
            cache: JSONValue.int(usage["cache_read_input_tokens"]) ?? 0
        )
    }

    static func zcode(_ line: String) -> ParsedUsage? {
        guard line.contains("\"usage\""), let object = JSONValue.object(from: line),
            let timestamp = DateSupport.timestamp(object["completedAt"]),
            let response = object["response"] as? JSONObject,
            let usage = response["usage"] as? JSONObject
        else { return nil }
        let input = JSONValue.int(usage["inputTokens"]) ?? 0
        let cache = JSONValue.int(usage["cacheReadTokens"]) ?? 0
        return ParsedUsage(
            timestamp: timestamp,
            input: max(0, input - cache),
            output: JSONValue.int(usage["outputTokens"]) ?? 0,
            cache: cache
        )
    }
}

struct UsageCollector {
    let environment: CollectorEnvironment
    let files: FileSupport

    private let maximumAge: TimeInterval = 70 * 86_400

    func collect() -> UsageData? {
        do {
            let database = try openDatabase()
            let sources: [([String], String, (String) -> ParsedUsage?)] = [
                (
                    files.files(
                        atDepth: 4, under: environment.path(".codex", "sessions"),
                        where: { $0.hasSuffix(".jsonl") }), "codex", UsageParsers.codex
                ),
                (
                    files.files(
                        atDepth: 5, under: environment.path(".kimi-code", "sessions"),
                        where: { $0.hasSuffix("/wire.jsonl") }), "kimi", UsageParsers.kimi
                ),
                (
                    files.files(
                        atDepth: 2, under: environment.path(".claude", "projects"),
                        where: { $0.hasSuffix(".jsonl") }), "claude", UsageParsers.claude
                ),
                (
                    files.files(
                        atDepth: 1, under: environment.path(".zcode", "cli", "rollout"),
                        where: {
                            URL(fileURLWithPath: $0).lastPathComponent.hasPrefix("model-io-")
                                && $0.hasSuffix(".jsonl")
                        }), "zcode", UsageParsers.zcode
                ),
            ]
            for (paths, tool, parser) in sources {
                for path in paths {
                    try? scan(path: path, tool: tool, parser: parser, database: database)
                }
            }
            collectHermes(database: database)
            let today = DateSupport.localDay(environment.now)
            let rows = try database.query(
                "SELECT tool, input, output, cache FROM daily WHERE date=?",
                binds: [.text(today)]
            )
            var tools: [String: UsageEntry] = [:]
            var total = UsageEntry()
            for row in rows {
                guard let tool = row["tool"]?.string else { continue }
                let entry = UsageEntry(
                    input: row["input"]?.int ?? 0,
                    output: row["output"]?.int ?? 0,
                    cache: row["cache"]?.int ?? 0
                )
                tools[tool] = entry
                total.add(entry)
            }
            let heat = try heatmap(database: database)
            return UsageData(
                date: DateSupport.displayDay(Date(timeIntervalSince1970: environment.now)),
                tools: tools,
                total: total,
                heatmap: heat.days,
                heatmax: heat.maximum
            )
        } catch {
            return nil
        }
    }

    private func openDatabase() throws -> SQLiteDatabase {
        let directory = environment.path(".ai-statusbar")
        try files.ensurePrivateDirectory(directory)
        let path = (directory as NSString).appendingPathComponent("usage.sqlite")
        let database = try SQLiteDatabase(path: path)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
        try database.execute(
            """
            CREATE TABLE IF NOT EXISTS daily(
                date TEXT, tool TEXT, input INT, output INT, cache INT,
                PRIMARY KEY(date, tool))
            """)
        try database.execute(
            """
            CREATE TABLE IF NOT EXISTS offsets(
                path TEXT PRIMARY KEY, offset INT, mtime REAL, last_key TEXT)
            """)
        if !(try database.columns(in: "offsets")).contains("last_key") {
            try database.execute("ALTER TABLE offsets ADD COLUMN last_key TEXT")
        }
        return database
    }

    private func add(_ usage: ParsedUsage, tool: String, database: SQLiteDatabase) throws {
        try database.execute(
            """
            INSERT INTO daily(date, tool, input, output, cache) VALUES(?,?,?,?,?)
            ON CONFLICT(date, tool) DO UPDATE SET
                input=input+excluded.input,
                output=output+excluded.output,
                cache=cache+excluded.cache
            """,
            binds: [
                .text(DateSupport.localDay(usage.timestamp)), .text(tool),
                .integer(Int64(usage.input)), .integer(Int64(usage.output)),
                .integer(Int64(usage.cache)),
            ])
    }

    private func scan(
        path: String,
        tool: String,
        parser: (String) -> ParsedUsage?,
        database: SQLiteDatabase
    ) throws {
        guard let size = files.fileSize(path), let modified = files.modificationTime(path),
            environment.now - modified <= maximumAge
        else { return }
        let previous = try database.query(
            "SELECT offset, mtime, last_key FROM offsets WHERE path=?",
            binds: [.text(path)]
        ).first
        var offset = UInt64(max(0, previous?["offset"]?.int ?? 0))
        var lastKey = previous?["last_key"]?.string
        if offset == size, previous?["mtime"]?.double == modified { return }
        if size < offset { offset = 0 }
        guard let handle = FileHandle(forReadingAtPath: path) else { return }
        defer { try? handle.close() }
        try handle.seek(toOffset: offset)
        guard let raw = try handle.readToEnd(),
            let newline = raw.lastIndex(of: 0x0A)
        else { return }
        let complete = raw.prefix(upTo: newline)
        for line in String(decoding: complete, as: UTF8.self).split(whereSeparator: \.isNewline) {
            guard let usage = parser(String(line)) else { continue }
            let key = "\(usage.input):\(usage.output):\(usage.cache)"
            if key != lastKey {
                try add(usage, tool: tool, database: database)
                lastKey = key
            }
        }
        let nextOffset = offset + UInt64(raw.distance(from: raw.startIndex, to: newline)) + 1
        try database.execute(
            """
            INSERT INTO offsets(path, offset, mtime, last_key) VALUES(?,?,?,?)
            ON CONFLICT(path) DO UPDATE SET
                offset=excluded.offset, mtime=excluded.mtime, last_key=excluded.last_key
            """,
            binds: [
                .text(path), .integer(Int64(nextOffset)), .real(modified),
                lastKey.map(SQLiteBind.text) ?? .null,
            ])
    }

    private func collectHermes(database: SQLiteDatabase) {
        do {
            try database.execute(
                """
                CREATE TABLE IF NOT EXISTS hermes_snap(
                    pk TEXT PRIMARY KEY, input INT, output INT, cache INT)
                """)
            let hermes = try SQLiteDatabase(
                path: environment.path(".hermes", "state.db"), readOnly: true)
            let rows = try hermes.query(
                """
                SELECT session_id||'|'||model||'|'||billing_provider||'|'||
                    billing_base_url||'|'||billing_mode||'|'||task AS pk,
                    input_tokens, output_tokens, cache_read_tokens, first_seen
                FROM session_model_usage
                """)
            let calendar = Calendar.current
            let todayStart = calendar.startOfDay(for: Date(timeIntervalSince1970: environment.now))
                .timeIntervalSince1970
            for row in rows {
                guard let key = row["pk"]?.string else { continue }
                let input = row["input_tokens"]?.int ?? 0
                let output = row["output_tokens"]?.int ?? 0
                let cache = row["cache_read_tokens"]?.int ?? 0
                let previous = try database.query(
                    "SELECT input, output, cache FROM hermes_snap WHERE pk=?", binds: [.text(key)]
                ).first
                try database.execute(
                    """
                    INSERT INTO hermes_snap(pk, input, output, cache) VALUES(?,?,?,?)
                    ON CONFLICT(pk) DO UPDATE SET
                        input=excluded.input, output=excluded.output, cache=excluded.cache
                    """,
                    binds: [
                        .text(key), .integer(Int64(input)), .integer(Int64(output)),
                        .integer(Int64(cache)),
                    ])
                let delta: UsageEntry
                if let previous {
                    delta = UsageEntry(
                        input: max(0, input - (previous["input"]?.int ?? 0)),
                        output: max(0, output - (previous["output"]?.int ?? 0)),
                        cache: max(0, cache - (previous["cache"]?.int ?? 0))
                    )
                } else if (row["first_seen"]?.double ?? 0) >= todayStart {
                    delta = UsageEntry(input: input, output: output, cache: cache)
                } else {
                    continue
                }
                if delta.input > 0 || delta.output > 0 || delta.cache > 0 {
                    try add(
                        ParsedUsage(
                            timestamp: environment.now, input: delta.input, output: delta.output,
                            cache: delta.cache), tool: "hermes", database: database)
                }
            }
        } catch {
            return
        }
    }

    private func heatmap(database: SQLiteDatabase) throws -> (days: [HeatDay], maximum: Int) {
        let rows = try database.query(
            "SELECT date, SUM(input + output + cache) AS total FROM daily GROUP BY date")
        let totals = rows.reduce(into: [String: Int]()) {
            if let day = $1["date"]?.string { $0[day] = $1["total"]?.int ?? 0 }
        }
        let calendar = Calendar.current
        let now = Date(timeIntervalSince1970: environment.now)
        var start = calendar.date(byAdding: .day, value: -69, to: now) ?? now
        let weekday = calendar.component(.weekday, from: start)
        let daysAfterMonday = (weekday + 5) % 7
        start = calendar.startOfDay(
            for: calendar.date(byAdding: .day, value: -daysAfterMonday, to: start) ?? start)
        var dates: [Date] = []
        var current = start
        while current <= now {
            dates.append(current)
            guard let next = calendar.date(byAdding: .day, value: 1, to: current) else { break }
            current = next
        }
        while dates.count % 7 != 0, let last = dates.last,
            let next = calendar.date(byAdding: .day, value: 1, to: last)
        {
            dates.append(next)
        }
        var maximum = 0
        let today = calendar.startOfDay(for: now)
        let days = dates.map { date -> HeatDay in
            let key = DateSupport.localDay(date.timeIntervalSince1970)
            let total = totals[key] ?? 0
            maximum = max(maximum, total)
            return HeatDay(date: key, total: total, future: date > today)
        }
        return (days, maximum)
    }
}
