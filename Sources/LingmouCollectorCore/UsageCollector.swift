import Foundation

struct ParsedUsage: Equatable {
    let timestamp: TimeInterval
    let input: Int
    let output: Int
    let cache: Int
    var model: String = ""
    var requestID: String?
    var requestStartedAt: TimeInterval?
    var firstTokenAt: TimeInterval?
    var countsTowardDaily = true
    var metricKind: String?
}

/// 跨行解析状态同时保留模型与当前请求边界，供增量断点恢复后继续归属。
final class UsageParseState {
    var model: String?
    var requestID: String?
    var requestStartedAt: TimeInterval?
    var requestOutput = 0
}

typealias UsageParser = (String, UsageParseState) -> ParsedUsage?

struct UsageParsers {
    static func codex(_ line: String, _ state: UsageParseState) -> ParsedUsage? {
        // turn_context、token_count 与 task_complete 都要解析，其余大体积消息行直接跳过。
        guard line.contains("turn_context") || line.contains("token_count")
                || line.contains("task_complete"),
            let object = JSONValue.object(from: line)
        else { return nil }
        if JSONValue.string(object["type"]) == "turn_context",
            let payload = object["payload"] as? JSONObject
        {
            state.model = JSONValue.string(payload["model"]) ?? state.model
            state.requestID = JSONValue.string(payload["turn_id"])
            state.requestStartedAt = DateSupport.timestamp(object["timestamp"])
            state.requestOutput = 0
        }
        if JSONValue.string(object["type"]) == "event_msg",
            let payload = object["payload"] as? JSONObject,
            JSONValue.string(payload["type"]) == "task_complete",
            let completedAt = JSONValue.double(payload["completed_at"])
                ?? DateSupport.timestamp(object["timestamp"])
        {
            let startedAt = JSONValue.double(payload["started_at"]) ?? state.requestStartedAt
            let ttft = JSONValue.double(payload["time_to_first_token_ms"])
            let firstTokenAt = startedAt.flatMap { started in
                ttft.flatMap { value in
                    value >= 0 && completedAt > started + value / 1_000
                        ? started + value / 1_000 : nil
                }
            }
            return ParsedUsage(
                timestamp: completedAt, input: 0, output: state.requestOutput, cache: 0,
                model: state.model ?? "",
                requestID: JSONValue.string(payload["turn_id"]) ?? state.requestID,
                requestStartedAt: firstTokenAt == nil ? nil : startedAt, firstTokenAt: firstTokenAt,
                countsTowardDaily: false, metricKind: firstTokenAt == nil ? nil : "effective")
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
        let output = JSONValue.int(usage["output_tokens"]) ?? 0
        state.requestOutput += max(0, output)
        return ParsedUsage(
            timestamp: timestamp,
            input: max(0, input - cache),
            output: output,
            cache: cache,
            model: state.model ?? "",
            requestID: state.requestID
        )
    }

    static func kimi(_ line: String, _ state: UsageParseState) -> ParsedUsage? {
        guard line.contains("usage.record") || line.contains("turn.prompt")
                || line.contains("step.begin") || line.contains("step.end"),
            let object = JSONValue.object(from: line)
        else { return nil }
        let type = JSONValue.string(object["type"])
        if type == "turn.prompt" {
            state.requestID = nil
            state.requestStartedAt = nil
            return nil
        }
        if type == "context.append_loop_event",
            let event = object["event"] as? JSONObject,
            JSONValue.string(event["type"]) == "step.begin"
        {
            state.requestID = JSONValue.string(event["uuid"])
            state.requestStartedAt = JSONValue.double(object["time"]).map { $0 / 1_000 }
            return nil
        }
        if type == "context.append_loop_event",
            let event = object["event"] as? JSONObject,
            JSONValue.string(event["type"]) == "step.end",
            let milliseconds = JSONValue.double(object["time"]), milliseconds > 0,
            let usage = event["usage"] as? JSONObject
        {
            let finishedAt = milliseconds / 1_000
            let streamDuration = JSONValue.double(event["llmStreamDurationMs"]) ?? 0
            let uuid = JSONValue.string(event["uuid"])
            return ParsedUsage(
                timestamp: finishedAt, input: 0,
                output: JSONValue.int(usage["output"]) ?? 0, cache: 0,
                model: state.model ?? "", requestID: uuid,
                requestStartedAt: uuid == state.requestID ? state.requestStartedAt : nil,
                firstTokenAt: streamDuration > 0 ? finishedAt - streamDuration / 1_000 : nil,
                countsTowardDaily: false)
        }
        guard type == "usage.record",
            let milliseconds = JSONValue.double(object["time"]), milliseconds > 0,
            let usage = object["usage"] as? JSONObject
        else { return nil }
        state.model = JSONValue.string(object["model"])
        return ParsedUsage(
            timestamp: milliseconds / 1_000,
            input: JSONValue.int(usage["inputOther"]) ?? 0,
            output: JSONValue.int(usage["output"]) ?? 0,
            cache: JSONValue.int(usage["inputCacheRead"]) ?? 0,
            model: state.model ?? "",
            requestID: state.requestID
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
            collectDsh(database: database)
            try UsageSpeedStore.prune(
                database: database, retentionDays: settings.usageRequestRetentionDays,
                now: environment.now)
            let rows = try localDaily(database: database)
            let local = Self.usageData(
                from: UsageSync.mergedDaily([rows]), now: environment.now,
                speed: try UsageSpeedStore.load(database: database))
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
    static func usageData(
        from daily: MergedDaily, now: TimeInterval, speed: UsageSpeedData? = nil
    ) -> UsageData {
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
            monthly: rollingRange(days: 30, from: daily, now: now),
            dailyModels: daily.byModel,
            speed: speed
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
        // 除 main 外，swarm 子代理（agents/agent-N）在各自的 wire.jsonl 里独立计费，
        // 只扫 main 会大幅少算（子代理的输出常是 main 的数倍）；与 Kimi Code CLI 的
        // 口径一致。仍按 conv- 前缀排除 ctitle- 这类内部辅助会话。
        return files.files(under: root) { path, isDirectory in
            guard !isDirectory, path.hasSuffix("/wire.jsonl") else { return false }
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
        if !(try database.columns(in: "offsets")).contains("last_request_id") {
            try database.execute("ALTER TABLE offsets ADD COLUMN last_request_id TEXT")
        }
        if !(try database.columns(in: "offsets")).contains("last_request_started") {
            try database.execute("ALTER TABLE offsets ADD COLUMN last_request_started REAL")
        }
        if !(try database.columns(in: "offsets")).contains("last_request_output") {
            try database.execute("ALTER TABLE offsets ADD COLUMN last_request_output INT")
        }
        try UsageSpeedStore.createSchema(database: database)
        try database.execute(
            "CREATE TABLE IF NOT EXISTS speed_backfills(path TEXT PRIMARY KEY)")
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

    private func sessionID(tool: String, path: String) -> String? {
        switch tool {
        case "kimi", "kimi-work":
            let id = URL(fileURLWithPath: path)
                .deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent().lastPathComponent
            return id.isEmpty ? nil : id
        case "codex":
            let name = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
            let parts = name.split(separator: "-")
            guard parts.count >= 5 else { return nil }
            return parts.suffix(5).joined(separator: "-")
        default:
            return nil
        }
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
            """
            SELECT offset, mtime, last_key, last_model, last_request_id, last_request_started,
                last_request_output
            FROM offsets WHERE path=?
            """,
            binds: [.text(path)]
        ).first
        var offset = UInt64(max(0, previous?["offset"]?.int ?? 0))
        var lastKey = previous?["last_key"]?.string
        let state = UsageParseState()
        state.model = previous?["last_model"]?.string
        state.requestID = previous?["last_request_id"]?.string
        state.requestStartedAt = previous?["last_request_started"]?.double
        state.requestOutput = previous?["last_request_output"]?.int ?? 0
        var backfillOnly = false
        if tool == "codex", previous != nil {
            backfillOnly = try database.query(
                "SELECT path FROM speed_backfills WHERE path=?", binds: [.text(path)]).isEmpty
        }
        if backfillOnly {
            offset = 0
            lastKey = nil
            state.model = nil
            state.requestID = nil
            state.requestStartedAt = nil
            state.requestOutput = 0
        } else {
            if offset == size, previous?["mtime"]?.double == modified { return }
            if size < offset {
                offset = 0
                state.model = nil
                state.requestID = nil
                state.requestStartedAt = nil
                state.requestOutput = 0
            }
        }
        guard let handle = FileHandle(forReadingAtPath: path) else { return }
        defer { try? handle.closeFile() }
        try handle.seek(toOffset: offset)
        guard let raw = try handle.readToEnd(),
            let newline = raw.lastIndex(of: 0x0A)
        else { return }
        let complete = raw.prefix(upTo: newline)
        for line in String(decoding: complete, as: UTF8.self).split(whereSeparator: \.isNewline) {
            guard let usage = parser(String(line), state) else { continue }
            let key = "\(usage.requestID ?? ""):\(usage.model):\(usage.input):\(usage.output):\(usage.cache)"
            let isNewRequest = !usage.countsTowardDaily || key != lastKey
            if usage.countsTowardDaily, isNewRequest, !backfillOnly {
                try add(usage, tool: tool, database: database)
                lastKey = key
            }
            if isNewRequest {
                let source = "\(path):\(usage.requestID ?? ""):\(usage.timestamp):\(key)"
                try UsageSpeedStore.add(
                    UsageRequest(
                        id: UsageSpeedStore.identifier(tool: tool, source: source), tool: tool,
                        model: usage.model, sessionId: sessionID(tool: tool, path: path),
                        startedAt: usage.requestStartedAt,
                        firstTokenAt: usage.firstTokenAt, finishedAt: usage.timestamp,
                        outputTokens: usage.output, metricKind: usage.metricKind), database: database)
            }
        }
        if backfillOnly {
            try database.execute(
                "INSERT OR IGNORE INTO speed_backfills(path) VALUES(?)", binds: [.text(path)])
            return
        }
        let nextOffset = offset + UInt64(raw.distance(from: raw.startIndex, to: newline)) + 1
        try database.execute(
            """
            INSERT INTO offsets(
                path, offset, mtime, last_key, last_model, last_request_id, last_request_started,
                last_request_output)
            VALUES(?,?,?,?,?,?,?,?)
            ON CONFLICT(path) DO UPDATE SET
                offset=excluded.offset, mtime=excluded.mtime,
                last_key=excluded.last_key, last_model=excluded.last_model,
                last_request_id=excluded.last_request_id,
                last_request_started=excluded.last_request_started,
                last_request_output=excluded.last_request_output
            """,
            binds: [
                .text(path), .integer(Int64(nextOffset)), .real(modified),
                lastKey.map(SQLiteBind.text) ?? .null,
                state.model.map(SQLiteBind.text) ?? .null,
                state.requestID.map(SQLiteBind.text) ?? .null,
                state.requestStartedAt.map(SQLiteBind.real) ?? .null,
                .integer(Int64(state.requestOutput)),
            ])
        if tool == "codex" {
            try database.execute(
                "INSERT OR IGNORE INTO speed_backfills(path) VALUES(?)", binds: [.text(path)])
        }
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
            let usageColumns = try zcode.columns(in: "model_usage")
            let completedColumn = usageColumns.contains("completed_at")
                ? "completed_at" : "NULL AS completed_at"
            let firstTokenColumn = usageColumns.contains("first_token_at")
                ? "first_token_at" : "NULL AS first_token_at"
            let sessionColumn = usageColumns.contains("session_id")
                ? "session_id" : "NULL AS session_id"
            let window = Int64((environment.now - maximumAge) * 1000)
            let rows = try zcode.query(
                """
                SELECT id, model_id, input_tokens, output_tokens,
                    cache_read_input_tokens, started_at, \(completedColumn), \(firstTokenColumn),
                    \(sessionColumn)
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
            let knownSpeedIDs = Set(try database.query(
                """
                SELECT id FROM requests WHERE session_id IS NOT NULL
                UNION SELECT id FROM request_exclusions
                """
            ).compactMap { $0["id"]?.string })
            for row in rows {
                guard let id = row["id"]?.string, let startedMs = row["started_at"]?.double,
                    startedMs > 0
                else { continue }
                let cache = row["cache_read_input_tokens"]?.int ?? 0
                let input = max(0, (row["input_tokens"]?.int ?? 0) - cache)
                let output = row["output_tokens"]?.int ?? 0
                let previous = snapshot[id] ?? (input: 0, output: 0, cache: 0)
                if !knownSpeedIDs.contains("zcode:\(id)") {
                    try UsageSpeedStore.add(
                        UsageRequest(
                            id: "zcode:\(id)", tool: "zcode", model: row["model_id"]?.string ?? "",
                            sessionId: row["session_id"]?.string, startedAt: startedMs / 1_000,
                            firstTokenAt: row["first_token_at"]?.double.map { $0 / 1_000 },
                            finishedAt: (row["completed_at"]?.double ?? 0) / 1_000,
                            outputTokens: output), database: database)
                }
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
            let lastSeenColumn = try hermes.columns(in: "session_model_usage").contains("last_seen")
                ? "last_seen" : "NULL AS last_seen"
            let rows = try hermes.query(
                """
                SELECT session_id||'|'||model||'|'||billing_provider||'|'||
                    billing_base_url||'|'||billing_mode||'|'||task AS pk,
                    model, input_tokens, output_tokens, cache_read_tokens, first_seen, \(lastSeenColumn)
                FROM session_model_usage
                """)
            try repairHermesModelAttribution(rows: rows, database: database)
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

    /// 旧版 SELECT 漏掉 model，但快照主键保留了模型。仅当已入账快照全部发生在
    /// 同一天、且与该日未知桶逐项完全一致时回填；跨日累计值无法还原逐日归属。
    /// 使用采集前快照，避免把尚未入账的新增量混入修复；不重扫、不修改总量。
    private func repairHermesModelAttribution(
        rows: [[String: SQLiteValue]], database: SQLiteDatabase
    ) throws {
        let unknown = try database.query(
            "SELECT date, input, output, cache FROM daily WHERE tool='hermes' AND model=''")
        guard !unknown.isEmpty else { return }
        let snapshots = Dictionary(uniqueKeysWithValues: try database.query(
            "SELECT pk, input, output, cache FROM hermes_snap"
        ).compactMap { row -> (String, UsageEntry)? in
            guard let key = row["pk"]?.string else { return nil }
            return (key, UsageEntry(
                input: row["input"]?.int ?? 0, output: row["output"]?.int ?? 0,
                cache: row["cache"]?.int ?? 0))
        })
        for row in unknown {
            guard let day = row["date"]?.string else { continue }
            // 混合新旧归类的日期缺少逐条来源，保留原值，避免将已知模型重复入账。
            guard try database.query(
                "SELECT model FROM daily WHERE date=? AND tool='hermes' AND model<>''",
                binds: [.text(day)]).isEmpty else { continue }
            var byModel: [String: UsageEntry] = [:]
            var ambiguous = false
            for source in rows {
                guard let key = source["pk"]?.string, let usage = snapshots[key],
                    usage.input > 0 || usage.output > 0 || usage.cache > 0
                else { continue }
                guard let first = source["first_seen"]?.double,
                    let last = source["last_seen"]?.double, first > 0, last >= first
                else { ambiguous = true; break }
                let firstDay = DateSupport.localDay(first)
                let lastDay = DateSupport.localDay(last)
                guard firstDay <= day, day <= lastDay else { continue }
                let model = source["model"]?.string ?? ""
                guard firstDay == day, lastDay == day,
                    !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                else { ambiguous = true; break }
                byModel[model, default: UsageEntry()].add(usage)
            }
            var total = UsageEntry()
            for usage in byModel.values { total.add(usage) }
            let original = UsageEntry(
                input: row["input"]?.int ?? 0, output: row["output"]?.int ?? 0,
                cache: row["cache"]?.int ?? 0)
            guard !ambiguous, !byModel.isEmpty, total == original else { continue }
            try database.execute("BEGIN IMMEDIATE")
            do {
                for (model, usage) in byModel {
                    try database.execute(
                        "INSERT INTO daily(date,tool,model,input,output,cache) VALUES(?,'hermes',?,?,?,?)",
                        binds: [.text(day), .text(model), .integer(Int64(usage.input)),
                                .integer(Int64(usage.output)), .integer(Int64(usage.cache))])
                }
                try database.execute(
                    "DELETE FROM daily WHERE date=? AND tool='hermes' AND model=''",
                    binds: [.text(day)])
                try database.execute("COMMIT")
            } catch {
                try? database.execute("ROLLBACK")
                throw error
            }
        }
    }

    /// DSH 用量：读投影缓存里每会话的 tokenUsage.totals（会话级累计值），快照差分入账。
    /// 新版缓存按会话分文件存放在 session_projcache/sessions/session-*.json
    /// （record.rows），旧版是单一 session_projcache.json。
    /// projcache 无 per-session 模型，模型 id 从会话事件流（session.jsonl.zstd）
    /// 尾部的 finish 块解析，依赖外部 zstd 二进制；不可用时回退 settings.yaml 的
    /// agent-default-model。
    private func collectDsh(database: SQLiteDatabase) {
        do {
            try database.execute(
                """
                CREATE TABLE IF NOT EXISTS dsh_snap(
                    pk TEXT PRIMARY KEY, input INT, output INT, cache INT)
                """)
            var sessions: [(id: String, rows: JSONObject)] = []
            let cacheDirectory = environment.path(".dsh", "storages", "session_projcache", "sessions")
            let projectionFiles = files.files(atDepth: 1, under: cacheDirectory) {
                $0.hasSuffix(".json")
            }
            if !projectionFiles.isEmpty {
                for path in projectionFiles {
                    let id = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
                    guard let root = files.read(path).flatMap(JSONValue.object),
                        let record = root["record"] as? JSONObject,
                        let rows = record["rows"] as? JSONObject
                    else { continue }
                    sessions.append((id, rows))
                }
            } else {
                let cachePath = environment.path(".dsh", "storages", "session_projcache.json")
                guard let root = files.read(cachePath).flatMap(JSONValue.object),
                    let tables = root["tables"] as? JSONObject,
                    let table = tables["sessions"] as? JSONObject
                else { return }
                for (id, entry) in table {
                    guard let entry = entry as? JSONObject,
                        let rows = entry["rows"] as? JSONObject
                    else { continue }
                    sessions.append((id, rows))
                }
            }
            guard !sessions.isEmpty else { return }
            // 会话路径映射只有出现用量增量的会话才用得上；全量枚举 sessions 树
            // 每轮都做太贵，延迟到首个增量会话再扫一次（每轮最多一次）。
            var sessionPathsCache: [String]?
            func sessionPaths() -> [String] {
                if let sessionPathsCache { return sessionPathsCache }
                let paths = files.files(
                    atDepth: 3, under: environment.path(".dsh", "sessions"),
                    where: { $0.hasSuffix("/session.jsonl.zstd") })
                sessionPathsCache = paths
                return paths
            }
            // GUI 环境 PATH 不含 homebrew，按常见安装位置逐个探测
            let zstd = ["/opt/homebrew/bin/zstd", "/usr/local/bin/zstd", "/opt/anaconda3/bin/zstd"]
                .first { files.manager.fileExists(atPath: $0) }
            let calendar = Calendar.current
            let todayStart = calendar.startOfDay(for: Date(timeIntervalSince1970: environment.now))
                .timeIntervalSince1970
            for (id, rows) in sessions {
                guard let usage = (rows["tokenUsage"] as? JSONObject)?["val"] as? JSONObject,
                    let totals = usage["totals"] as? JSONObject
                else { continue }
                let input = JSONValue.int(totals["uncachedInputTokens"]) ?? 0
                let output = JSONValue.int(totals["outputTokens"]) ?? 0
                let cache = JSONValue.int(totals["cacheReadTokens"]) ?? 0
                let previous = try database.query(
                    "SELECT input, output, cache FROM dsh_snap WHERE pk=?", binds: [.text(id)]
                ).first
                try database.execute(
                    """
                    INSERT INTO dsh_snap(pk, input, output, cache) VALUES(?,?,?,?)
                    ON CONFLICT(pk) DO UPDATE SET
                        input=excluded.input, output=excluded.output, cache=excluded.cache
                    """,
                    binds: [
                        .text(id), .integer(Int64(input)), .integer(Int64(output)),
                        .integer(Int64(cache)),
                    ])
                let delta: UsageEntry
                if let previous {
                    delta = UsageEntry(
                        input: max(0, input - (previous["input"]?.int ?? 0)),
                        output: max(0, output - (previous["output"]?.int ?? 0)),
                        cache: max(0, cache - (previous["cache"]?.int ?? 0)))
                } else {
                    let metadata = (rows["sessionListMetadata"] as? JSONObject)?["val"]
                        as? JSONObject ?? [:]
                    let lastPromptAt = (JSONValue.double(metadata["lastPromptAt"]) ?? 0) / 1_000
                    guard lastPromptAt >= todayStart else { continue }
                    delta = UsageEntry(input: input, output: output, cache: cache)
                }
                if delta.input > 0 || delta.output > 0 || delta.cache > 0 {
                    let model =
                        dshSessionModel(id: id, sessionPaths: sessionPaths, zstd: zstd)
                        ?? dshModel()
                    try add(
                        ParsedUsage(
                            timestamp: environment.now, input: delta.input, output: delta.output,
                            cache: delta.cache, model: model), tool: "dsh", database: database)
                }
            }
        } catch {
            return
        }
    }

    /// 会话当前模型：解压该会话事件流尾部，取最后一个 finish 块的
    /// replayState.response.model；zstd 缺失或解析失败返回 nil。
    /// sessionPaths 是惰性闭包：仅存在用量增量的会话才需要路径映射。
    private func dshSessionModel(
        id: String, sessionPaths: () -> [String], zstd: String?
    ) -> String? {
        guard let zstd,
            let path = sessionPaths().first(where: {
                URL(fileURLWithPath: $0).deletingLastPathComponent().lastPathComponent == id
            })
        else { return nil }
        let tail = ProcessSupport().output(
            executable: "/bin/sh",
            arguments: ["-c", "\"$1\" -dc \"$2\" 2>/dev/null | tail -c 262144", "sh", zstd, path])
        var model: String?
        for object in files.jsonLines(tail) {
            guard JSONValue.string(object["type"]) == "assistant/chunk",
                let data = object["data"] as? JSONObject,
                let chunk = data["chunk"] as? JSONObject,
                JSONValue.string(chunk["type"]) == "finish",
                let replay = chunk["replayState"] as? JSONObject,
                let response = replay["response"] as? JSONObject,
                let value = JSONValue.string(response["model"])
            else { continue }
            model = value
        }
        return model
    }

    /// 从 ~/.dsh/settings.yaml 的 agent-default-model 段解析模型名（简单行匹配）。
    private func dshModel() -> String {
        guard let text = files.readText(environment.path(".dsh", "settings.yaml")) else {
            return "dsh"
        }
        let lines = text.split(whereSeparator: \.isNewline).map(String.init)
        guard let section = lines.firstIndex(where: {
            $0.trimmingCharacters(in: .whitespaces).hasPrefix("agent-default-model:")
        }) else { return "dsh" }
        for line in lines.dropFirst(section + 1) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if !line.hasPrefix(" ") && !line.hasPrefix("\t") && !trimmed.isEmpty { break }
            if trimmed.hasPrefix("model:") {
                let value = trimmed.dropFirst("model:".count)
                    .trimmingCharacters(in: .whitespaces)
                if !value.isEmpty { return value }
            }
        }
        return "dsh"
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
