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
    let settings: CollectorSettings
    let files: FileSupport

    init(
        environment: CollectorEnvironment,
        settings: CollectorSettings = CollectorSettings(),
        files: FileSupport
    ) {
        self.environment = environment
        self.settings = settings
        self.files = files
    }

    private let maximumAge: TimeInterval = 70 * 86_400

    func collect() -> UsageData? {
        collectWithSync().local
    }

    /// 采集本机用量；开启同步时同时导出本机数据并合并同步目录中其他设备的数据。
    /// 同步关闭时 merged/sync 为 nil，JSON 输出与旧版完全一致。
    func collectWithSync() -> (
        local: UsageData?, merged: UsageData?, sync: UsageSyncStatus?
    ) {
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
                    kimiWorkUsageFiles(), "kimi-work", UsageParsers.kimi
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
            let rows = try localDaily(database: database)
            let local = Self.usageData(
                from: UsageSync.mergedDaily([rows]), now: environment.now)
            guard settings.usageSyncEnabled else { return (local, nil, nil) }
            let synced = try syncUsage(localRows: rows)
            return (local, synced.merged, synced.status)
        } catch {
            return (nil, nil, nil)
        }
    }

    /// 导出本机数据到同步目录，并合并目录中所有设备的数据与来源状态
    private func syncUsage(localRows: [UsageSyncDay]) throws -> (
        merged: UsageData, status: UsageSyncStatus
    ) {
        let directory =
            settings.usageSyncDir ?? UsageSync.defaultDirectory(home: environment.homeDirectory)
        let device = UsageSync.deviceIdentity(home: environment.homeDirectory, files: files)
        let export = UsageSync.writeExport(
            directory: directory, device: device, daily: localRows, now: environment.now,
            statePath: environment.path(".ai-statusbar", "sync-state.json"), files: files)
        // 排除自己导出的文件：本机数据以 sqlite 为准并入一次，
        // 否则目录里自己的导出会被当远端再合并一遍（计数翻倍）
        let remotes = UsageSync.loadRemotes(directory: directory, files: files)
            .filter { $0.device != device.id }
        let merged = Self.usageData(
            from: UsageSync.mergedDaily([localRows] + remotes.map(\.daily)),
            now: environment.now)
        var sources = remotes.map { file in
            UsageSyncSource(
                device: file.device, name: file.name, updatedAt: file.updatedAt,
                days: Set(file.daily.map(\.date)).count)
        }
        sources.append(
            UsageSyncSource(
                device: device.id, name: device.name, updatedAt: export.lastWrite,
                days: Set(localRows.map(\.date)).count))
        let status = UsageSyncStatus(
            enabled: true, dir: directory, device: device.id, name: device.name,
            sources: sources.sorted { $0.name < $1.name })
        return (merged, status)
    }

    private func localDaily(database: SQLiteDatabase) throws -> [UsageSyncDay] {
        try database.query("SELECT date, tool, input, output, cache FROM daily")
            .compactMap { row in
                guard let date = row["date"]?.string, let tool = row["tool"]?.string else {
                    return nil
                }
                return UsageSyncDay(
                    date: date, tool: tool,
                    input: row["input"]?.int ?? 0,
                    output: row["output"]?.int ?? 0,
                    cache: row["cache"]?.int ?? 0)
            }
    }

    /// 由 date → tool → 计数 构建 UsageData：今日分工具视图 + 滚动窗口聚合 + 热力图。
    /// 本机 sqlite 与多设备合并共用这一入口，保证两套视图的口径一致。
    static func usageData(
        from daily: [String: [String: UsageEntry]], now: TimeInterval
    ) -> UsageData {
        let today = DateSupport.localDay(now)
        var tools: [String: UsageEntry] = [:]
        var total = UsageEntry()
        for (tool, entry) in daily[today] ?? [:] {
            tools[tool] = entry
            total.add(entry)
        }
        let totals = daily.mapValues { day in
            day.values.reduce(0) { $0 + $1.input + $1.output + $1.cache }
        }
        let heat = heatmap(totals: totals, now: now)
        return UsageData(
            date: DateSupport.displayDay(Date(timeIntervalSince1970: now)),
            tools: tools,
            total: total,
            heatmap: heat.days,
            heatmax: heat.maximum,
            weekly: rollingRange(days: 7, from: daily, now: now),
            monthly: rollingRange(days: 30, from: daily, now: now)
        )
    }

    /// 近 N 日（含今日）分工具聚合；窗口外的天数不参与。
    static func rollingRange(
        days: Int, from daily: [String: [String: UsageEntry]], now: TimeInterval
    ) -> UsageRange {
        let calendar = Calendar.current
        let todayDate = calendar.startOfDay(for: Date(timeIntervalSince1970: now))
        var tools: [String: UsageEntry] = [:]
        var total = UsageEntry()
        for offset in 0..<max(1, days) {
            guard let date = calendar.date(byAdding: .day, value: -offset, to: todayDate) else {
                continue
            }
            for (tool, entry) in daily[DateSupport.localDay(date.timeIntervalSince1970)] ?? [:] {
                tools[tool, default: UsageEntry()].add(entry)
                total.add(entry)
            }
        }
        return UsageRange(tools: tools, total: total)
    }

    private func kimiWorkUsageFiles() -> [String] {
        let root = environment.path(
            "Library", "Application Support", "kimi-desktop", "daimon-share", "daimon",
            "runtime", "kimi-code", "home", "sessions")
        return files.files(under: root) { path, isDirectory in
            guard !isDirectory, path.hasSuffix("/agents/main/wire.jsonl") else { return false }
            let session = URL(fileURLWithPath: path)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .lastPathComponent
            return session.hasPrefix("conv-")
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

    /// 热力图（GitHub 风格：列=周，行=周一~周日），按 date → 总量 构建。
    /// 本机 sqlite 与多设备合并数据共用，保持口径一致。
    static func heatmap(totals: [String: Int], now: TimeInterval) -> (days: [HeatDay], maximum: Int) {
        let calendar = Calendar.current
        let nowDate = Date(timeIntervalSince1970: now)
        var start = calendar.date(byAdding: .day, value: -69, to: nowDate) ?? nowDate
        let weekday = calendar.component(.weekday, from: start)
        let daysAfterMonday = (weekday + 5) % 7
        start = calendar.startOfDay(
            for: calendar.date(byAdding: .day, value: -daysAfterMonday, to: start) ?? start)
        var dates: [Date] = []
        var current = start
        while current <= nowDate {
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
        let today = calendar.startOfDay(for: nowDate)
        let days = dates.map { date -> HeatDay in
            let key = DateSupport.localDay(date.timeIntervalSince1970)
            let total = totals[key] ?? 0
            maximum = max(maximum, total)
            return HeatDay(date: key, total: total, future: date > today)
        }
        return (days, maximum)
    }
}
