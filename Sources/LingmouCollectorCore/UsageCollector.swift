import Foundation

struct ParsedUsage: Equatable {
    let timestamp: TimeInterval
    let input: Int
    let output: Int
    let cache: Int
    var model: String = ""
}

/// 跨行解析状态：Codex 的 token_count 事件不带模型名，需记住最近一次 turn_context
/// 声明的模型。状态随 offsets 断点持久化，增量恢复后才能继续正确归属。
final class UsageParseState {
    var model: String?
}

typealias UsageParser = (String, UsageParseState) -> ParsedUsage?

struct UsageParsers {
    static func codex(_ line: String, _ state: UsageParseState) -> ParsedUsage? {
        // turn_context 与 token_count 都要解析，其余行（含大体积消息行）不做 JSON 解析
        guard line.contains("turn_context") || line.contains("token_count"),
            let object = JSONValue.object(from: line)
        else { return nil }
        if JSONValue.string(object["type"]) == "turn_context",
            let payload = object["payload"] as? JSONObject,
            let model = JSONValue.string(payload["model"]), !model.isEmpty
        {
            state.model = model
        }
        guard JSONValue.string(object["type"]) == "event_msg",
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
            cache: cache,
            model: state.model ?? ""
        )
    }

    static func kimi(_ line: String, _ state: UsageParseState) -> ParsedUsage? {
        guard line.contains("usage.record"), let object = JSONValue.object(from: line),
            JSONValue.string(object["type"]) == "usage.record",
            let milliseconds = JSONValue.double(object["time"]), milliseconds > 0,
            let usage = object["usage"] as? JSONObject
        else { return nil }
        return ParsedUsage(
            timestamp: milliseconds / 1_000,
            input: JSONValue.int(usage["inputOther"]) ?? 0,
            output: JSONValue.int(usage["output"]) ?? 0,
            cache: JSONValue.int(usage["inputCacheRead"]) ?? 0,
            model: JSONValue.string(object["model"]) ?? ""
        )
    }

    static func claude(_ line: String, _ state: UsageParseState) -> ParsedUsage? {
        guard line.contains("\"usage\""), let object = JSONValue.object(from: line),
            let timestamp = DateSupport.timestamp(object["timestamp"]),
            let message = object["message"] as? JSONObject,
            let usage = message["usage"] as? JSONObject
        else { return nil }
        return ParsedUsage(
            timestamp: timestamp,
            input: JSONValue.int(usage["input_tokens"]) ?? 0,
            output: JSONValue.int(usage["output_tokens"]) ?? 0,
            cache: JSONValue.int(usage["cache_read_input_tokens"]) ?? 0,
            model: JSONValue.string(message["model"]) ?? ""
        )
    }

    static func zcode(_ line: String, _ state: UsageParseState) -> ParsedUsage? {
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
            cache: cache,
            model: JSONValue.string((object["model"] as? JSONObject)?["modelId"]) ?? ""
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
            let zcodeFromDatabase = collectZcode(database: database)
            // zcode 优先走 db.sqlite 的 model_usage 表（rollout 文件会被 ZCode 定期清理，
            // 30 日历史只有库里还在）；db 不可用时回退文件扫描
            var sources: [([String], String, UsageParser)] = [
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
            ]
            if !zcodeFromDatabase {
                sources.append(
                    (
                        files.files(
                            atDepth: 1, under: environment.path(".zcode", "cli", "rollout"),
                            where: {
                                URL(fileURLWithPath: $0).lastPathComponent.hasPrefix("model-io-")
                                    && $0.hasSuffix(".jsonl")
                            }), "zcode", UsageParsers.zcode
                    ))
            }
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
        try database.query("SELECT date, tool, model, input, output, cache FROM daily")
            .compactMap { row in
                guard let date = row["date"]?.string, let tool = row["tool"]?.string else {
                    return nil
                }
                return UsageSyncDay(
                    date: date, tool: tool, model: row["model"]?.string ?? "",
                    input: row["input"]?.int ?? 0,
                    output: row["output"]?.int ?? 0,
                    cache: row["cache"]?.int ?? 0)
            }
    }

    /// 由 date → 工具/模型 → 计数 构建 UsageData：今日分工具与分模型视图 + 滚动窗口聚合 + 热力图。
    /// 本机 sqlite 与多设备合并共用这一入口，保证两套视图的口径一致。
    static func usageData(from daily: MergedDaily, now: TimeInterval) -> UsageData {
        let today = DateSupport.localDay(now)
        var tools: [String: UsageEntry] = [:]
        var models: [String: UsageEntry] = [:]
        var total = UsageEntry()
        for (tool, entry) in daily.byTool[today] ?? [:] {
            tools[tool] = entry
            total.add(entry)
        }
        for (model, entry) in daily.byModel[today] ?? [:] {
            models[model] = entry
        }
        let totals = daily.byTool.mapValues { day in
            day.values.reduce(0) { $0 + $1.input + $1.output + $1.cache }
        }
        let heat = heatmap(totals: totals, now: now)
        return UsageData(
            date: DateSupport.displayDay(Date(timeIntervalSince1970: now)),
            tools: tools,
            total: total,
            heatmap: heat.days,
            heatmax: heat.maximum,
            models: models,
            weekly: rollingRange(days: 7, from: daily, now: now),
            monthly: rollingRange(days: 30, from: daily, now: now)
        )
    }

    /// 近 N 日（含今日）分工具与分模型聚合；窗口外的天数不参与。
    static func rollingRange(
        days: Int, from daily: MergedDaily, now: TimeInterval
    ) -> UsageRange {
        let calendar = Calendar.current
        let todayDate = calendar.startOfDay(for: Date(timeIntervalSince1970: now))
        var tools: [String: UsageEntry] = [:]
        var models: [String: UsageEntry] = [:]
        var total = UsageEntry()
        for offset in 0..<max(1, days) {
            guard let date = calendar.date(byAdding: .day, value: -offset, to: todayDate) else {
                continue
            }
            let key = DateSupport.localDay(date.timeIntervalSince1970)
            for (tool, entry) in daily.byTool[key] ?? [:] {
                tools[tool, default: UsageEntry()].add(entry)
                total.add(entry)
            }
            for (model, entry) in daily.byModel[key] ?? [:] {
                models[model, default: UsageEntry()].add(entry)
            }
        }
        return UsageRange(tools: tools, total: total, models: models)
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
        // 旧版按 (date, tool) 聚合的 daily 无法拆出模型维度：丢弃并清空断点，
        // 让最近 70 天（maximumAge 窗口内）的日志重扫一遍自然带上模型；更早的数据
        // 本就超出热力图与滚动窗口的展示范围
        let dailyColumns = try database.columns(in: "daily")
        if !dailyColumns.isEmpty, !dailyColumns.contains("model") {
            try database.execute("DROP TABLE daily")
            try database.execute("DELETE FROM offsets")
        }
        try database.execute(
            """
            CREATE TABLE IF NOT EXISTS daily(
                date TEXT, tool TEXT, model TEXT NOT NULL DEFAULT '',
                input INT, output INT, cache INT,
                PRIMARY KEY(date, tool, model))
            """)
        try database.execute(
            """
            CREATE TABLE IF NOT EXISTS offsets(
                path TEXT PRIMARY KEY, offset INT, mtime REAL, last_key TEXT)
            """)
        if !(try database.columns(in: "offsets")).contains("last_key") {
            try database.execute("ALTER TABLE offsets ADD COLUMN last_key TEXT")
        }
        if !(try database.columns(in: "offsets")).contains("last_model") {
            try database.execute("ALTER TABLE offsets ADD COLUMN last_model TEXT")
        }
        return database
    }

    private func add(_ usage: ParsedUsage, tool: String, database: SQLiteDatabase) throws {
        try database.execute(
            """
            INSERT INTO daily(date, tool, model, input, output, cache) VALUES(?,?,?,?,?,?)
            ON CONFLICT(date, tool, model) DO UPDATE SET
                input=input+excluded.input,
                output=output+excluded.output,
                cache=cache+excluded.cache
            """,
            binds: [
                .text(DateSupport.localDay(usage.timestamp)), .text(tool), .text(usage.model),
                .integer(Int64(usage.input)), .integer(Int64(usage.output)),
                .integer(Int64(usage.cache)),
            ])
    }

    private func scan(
        path: String,
        tool: String,
        parser: UsageParser,
        database: SQLiteDatabase
    ) throws {
        guard let size = files.fileSize(path), let modified = files.modificationTime(path),
            environment.now - modified <= maximumAge
        else { return }
        let previous = try database.query(
            "SELECT offset, mtime, last_key, last_model FROM offsets WHERE path=?",
            binds: [.text(path)]
        ).first
        var offset = UInt64(max(0, previous?["offset"]?.int ?? 0))
        var lastKey = previous?["last_key"]?.string
        // 恢复上次的"当前模型"状态：Codex 断点后的第一条 token_count 才能归属正确
        let state = UsageParseState()
        state.model = previous?["last_model"]?.string
        if offset == size, previous?["mtime"]?.double == modified { return }
        if size < offset { offset = 0 }
        guard let handle = FileHandle(forReadingAtPath: path) else { return }
        defer { try? handle.closeFile() }
        try handle.seek(toOffset: offset)
        guard let raw = try handle.readToEnd(),
            let newline = raw.lastIndex(of: 0x0A)
        else { return }
        let complete = raw.prefix(upTo: newline)
        for line in String(decoding: complete, as: UTF8.self).split(whereSeparator: \.isNewline) {
            guard let usage = parser(String(line), state) else { continue }
            let key = "\(usage.model):\(usage.input):\(usage.output):\(usage.cache)"
            if key != lastKey {
                try add(usage, tool: tool, database: database)
                lastKey = key
            }
        }
        let nextOffset = offset + UInt64(raw.distance(from: raw.startIndex, to: newline)) + 1
        try database.execute(
            """
            INSERT INTO offsets(path, offset, mtime, last_key, last_model) VALUES(?,?,?,?,?)
            ON CONFLICT(path) DO UPDATE SET
                offset=excluded.offset, mtime=excluded.mtime,
                last_key=excluded.last_key, last_model=excluded.last_model
            """,
            binds: [
                .text(path), .integer(Int64(nextOffset)), .real(modified),
                lastKey.map(SQLiteBind.text) ?? .null,
                state.model.map(SQLiteBind.text) ?? .null,
            ])
    }

    /// ZCode 用量：读 db.sqlite 的 model_usage 表（每次请求一行，completed 后数值不再变）。
    /// rollout 文件会被 ZCode 定期清理、只剩最近几个会话，30 日历史只有库里还有。
    /// 快照差分入账：新行按 started_at 归入对应日期；首次建快照时历史行全部回填
    /// （此前文件扫描可能已给 daily 记过数，先清掉 tool=zcode 的行防止双计）。
    /// db 不可用时返回 false，调用方回退 rollout 文件扫描。
    private func collectZcode(database: SQLiteDatabase) -> Bool {
        do {
            let snapExists = !(try database.query(
                "SELECT name FROM sqlite_master WHERE type='table' AND name='zcode_snap'"
            ).isEmpty)
            if !snapExists {
                try database.execute("DELETE FROM daily WHERE tool='zcode'")
                try database.execute(
                    """
                    CREATE TABLE zcode_snap(
                        pk TEXT PRIMARY KEY, input INT, output INT, cache INT)
                    """)
            }
            let zcode = try SQLiteDatabase(
                path: environment.path(".zcode", "cli", "db", "db.sqlite"), readOnly: true)
            let window = Int64((environment.now - maximumAge) * 1000)
            let rows = try zcode.query(
                """
                SELECT id, model_id, input_tokens, output_tokens,
                    cache_read_input_tokens, started_at
                FROM model_usage
                WHERE status='completed' AND started_at >= ?
                """,
                binds: [.integer(window)])
            guard !rows.isEmpty else { return true }
            // 快照整表读入内存做差分：万级行时省掉每行一次回查，常态采集只写有变化的行
            var snapshot: [String: (input: Int, output: Int, cache: Int)] = [:]
            for row in try database.query("SELECT pk, input, output, cache FROM zcode_snap") {
                if let pk = row["pk"]?.string {
                    snapshot[pk] = (
                        row["input"]?.int ?? 0, row["output"]?.int ?? 0, row["cache"]?.int ?? 0
                    )
                }
            }
            for row in rows {
                guard let id = row["id"]?.string, let startedMs = row["started_at"]?.double,
                    startedMs > 0
                else { continue }
                let cache = row["cache_read_input_tokens"]?.int ?? 0
                let input = max(0, (row["input_tokens"]?.int ?? 0) - cache)
                let output = row["output_tokens"]?.int ?? 0
                let previous = snapshot[id] ?? (input: 0, output: 0, cache: 0)
                guard input != previous.input || output != previous.output
                    || cache != previous.cache
                else { continue }
                try database.execute(
                    """
                    INSERT INTO zcode_snap(pk, input, output, cache) VALUES(?,?,?,?)
                    ON CONFLICT(pk) DO UPDATE SET
                        input=excluded.input, output=excluded.output, cache=excluded.cache
                    """,
                    binds: [
                        .text(id), .integer(Int64(input)), .integer(Int64(output)),
                        .integer(Int64(cache)),
                    ])
                let deltaInput = input - previous.input
                let deltaOutput = output - previous.output
                let deltaCache = cache - previous.cache
                if deltaInput > 0 || deltaOutput > 0 || deltaCache > 0 {
                    try add(
                        ParsedUsage(
                            timestamp: startedMs / 1000, input: deltaInput,
                            output: deltaOutput, cache: deltaCache,
                            model: row["model_id"]?.string ?? ""),
                        tool: "zcode", database: database)
                }
            }
            return true
        } catch {
            return false
        }
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
                            cache: delta.cache,
                            model: row["model"]?.string ?? ""), tool: "hermes", database: database)
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
