import Foundation

struct LocalCollectors {
    let environment: CollectorEnvironment
    let settings: CollectorSettings
    let files: FileSupport
    let processes: ProcessSupport

    func kimi() -> RawToolState {
        let count = processes.count(named: "kimi") + processes.count(named: "kimi-code")
            + additionalKimiWebProcesses()
        var result = RawToolState(processOn: count > 0, detail: "\(count) 个进程")
        let root = environment.path(".kimi-code", "sessions")
        let stateFiles = files.files(atDepth: 3, under: root) { $0.hasSuffix("/state.json") }
        let window = TimeInterval(max(settings.busySeconds(for: "kimi"), 1_800))
        for statePath in stateFiles {
            let directory = (statePath as NSString).deletingLastPathComponent
            guard let metadata = files.read(statePath).flatMap(JSONValue.object) else {
                result.sourceError = "部分会话元数据不可读或格式不兼容"
                continue
            }
            let workDirectory = JSONValue.string(metadata["cwd"])
                ?? JSONValue.string(metadata["workDir"]) ?? ""
            let title =
                JSONValue.string(metadata["title"]).flatMap { $0.isEmpty ? nil : $0 }
                ?? URL(fileURLWithPath: workDirectory).lastPathComponent.nonempty
                ?? "(未命名会话)"
            let wireFiles = files.files(
                atDepth: 2,
                under: (directory as NSString).appendingPathComponent("agents")
            ) { $0.hasSuffix("/wire.jsonl") }
            guard let modified = wireFiles.compactMap(files.modificationTime).max() else {
                continue
            }
            updateLatest(&result, title: title, timestamp: modified)
            guard environment.now - modified <= window else { continue }
            applyKimiSignals(wireFiles, id: URL(fileURLWithPath: directory).lastPathComponent,
                             title: title, processOn: count > 0, to: &result)
        }
        return result
    }

    /// Kimi Code Web can rewrite its process title to `kimi-cod`. Only accept a
    /// registered, heartbeating instance backed by the same real Kimi process.
    /// The registry proves service liveness, never that a particular session is busy.
    private func additionalKimiWebProcesses() -> Int {
        let root = environment.path(".kimi-code", "server", "instances")
        var pids = Set<Int32>()
        for path in files.files(atDepth: 1, under: root, where: { $0.hasSuffix(".json") }) {
            guard let instance = files.read(path).flatMap(JSONValue.object),
                  let rawPID = JSONValue.double(instance["pid"]),
                  rawPID > 0, let pid = Int32(exactly: rawPID),
                  let heartbeat = JSONValue.double(instance["heartbeat_at"]),
                  let started = JSONValue.double(instance["started_at"]),
                  (0...30).contains(environment.now - heartbeat / 1_000),
                  started <= heartbeat,
                  let identity = processes.identity(pid: pid),
                  ["kimi", "kimi-code"].contains(URL(fileURLWithPath: identity.path).lastPathComponent),
                  abs(identity.startedAt - started / 1_000) <= 5
            else { continue }
            // Normal CLI/Web titles already participate in the existing process count.
            if !processes.isNamed(pid: pid, basename: "kimi"),
               !processes.isNamed(pid: pid, basename: "kimi-code") {
                pids.insert(pid)
            }
        }
        return pids.count
    }

    func kimiWork() -> RawToolState {
        let appOn = processes.count(named: "Kimi") > 0
        var result = RawToolState(processOn: appOn, detail: appOn ? "App 在线" : "无进程")
        let support = environment.path("Library", "Application Support", "kimi-desktop")
        let statusesPath = (support as NSString).appendingPathComponent(
            "kimi-agent/conversation-statuses.json")
        let statuses = files.read(statusesPath).flatMap(JSONValue.object) ?? [:]
        let databasePath = (support as NSString).appendingPathComponent(
            "daimon-share/daimon/agents/main/sessions/hosted-logical/conversations.sqlite")
        guard let database = try? SQLiteDatabase(path: databasePath, readOnly: true),
            let columns = try? database.columns(in: "conversations"),
            Set(["conversation_key", "title", "updated_at_ms"]).isSubset(of: columns)
        else {
            if files.manager.fileExists(atPath: databasePath) {
                result.sourceError = "会话数据库不可读或格式不兼容"
            }
            return result
        }
        // 新版 Kimi（3.2.4+ 这代）不再把 running 维护进状态文件（只在 blocked 等场景
        // 写入）；运行态改为读会话库的 kernel_session_dir——内嵌 kimi-code 运行时的
        // 会话目录，用与 Kimi Code 相同的 wire.jsonl 未闭合 step/tool 判定，
        // main 与 swarm 子代理（agents/agent-N）任一在跑即算运行中。
        let sessionColumn = columns.contains("kernel_session_dir") ? ", kernel_session_dir" : ""
        guard let rows = try? database.query(
            """
            SELECT conversation_key, title, updated_at_ms / 1000.0 AS timestamp\(sessionColumn)
            FROM conversations
            WHERE title != ''
            ORDER BY updated_at_ms DESC
            """)
        else {
            result.sourceError = "无法查询会话数据库"
            return result
        }
        let window = TimeInterval(max(settings.busySeconds(for: "kimi-work"), 1_800))
        for row in rows {
            guard let id = row["conversation_key"]?.string,
                let title = row["title"]?.string,
                let timestamp = row["timestamp"]?.double
            else { continue }
            updateLatest(&result, title: title, timestamp: timestamp)
            // 旧库存裸 id、新库存完整 key（agent:main:main:conversation:<uuid>），双形式兼容，
            // 避免拼出双重前缀导致状态文件永远匹配不上。
            let statusKey = id.hasPrefix("agent:")
                ? id : "agent:main:main:conversation:\(id)"
            if appOn, JSONValue.string(statuses[statusKey]) == "running" {
                result.busy.append(BusyItem(id: id, title: title))
                continue
            }
            guard let sessionDir = row["kernel_session_dir"]?.string else { continue }
            let wireFiles = files.files(
                atDepth: 2,
                under: (sessionDir as NSString).appendingPathComponent("agents")
            ) { $0.hasSuffix("/wire.jsonl") }
            applyKimiSignals(wireFiles, id: id, title: title, processOn: appOn, to: &result)
        }
        return result
    }

    private struct KimiSignal {
        var busy = false
        var ended: TimeInterval?
    }

    private func applyKimiSignals(_ paths: [String], id: String, title: String,
                                  processOn: Bool, to result: inout RawToolState) {
        let signals = paths.filter {
            environment.now - (files.modificationTime($0) ?? 0) <= 1_800
        }.map { ($0, kimiSignal($0)) }
        if signals.contains(where: { $0.1.busy }) {
            if processOn { result.busy.append(BusyItem(id: id, title: title)) }
        } else if let ended = signals.first(where: {
            URL(fileURLWithPath: $0.0).deletingLastPathComponent().lastPathComponent == "main"
        })?.1.ended {
            result.activities.append(TaskActivity(id: "\(id):ended:\(ended)", sessionId: id,
                                                  title: title, phase: "ended", updatedAt: ended))
        }
    }

    private func kimiSignal(_ path: String) -> KimiSignal {
        // Ignore large context snapshots; only wire lifecycle records carry state.
        let objects = files.readTail(path, bytes: 1 << 20).split(whereSeparator: \.isNewline)
            .filter { $0.contains("context.append_loop_event") || $0.contains("turn.prompt") }
            .compactMap { JSONValue.object(from: String($0)) }
        var steps = Set<String>(), tools = Set<String>()
        var turn: String?
        var promptPending = false
        var ended: TimeInterval?
        for object in objects {
            if JSONValue.string(object["type"]) == "turn.prompt" {
                steps.removeAll(); tools.removeAll(); ended = nil; turn = nil
                promptPending = true
                continue
            }
            guard JSONValue.string(object["type"]) == "context.append_loop_event",
                  let event = object["event"] as? JSONObject,
                  let type = JSONValue.string(event["type"]) else { continue }
            if type == "tool.result" {
                if let id = JSONValue.string(event["toolCallId"]) { tools.remove(id) }
                continue
            }
            if let next = JSONValue.string(event["turnId"]), next != turn {
                turn = next; steps.removeAll(); tools.removeAll(); ended = nil
            }
            if type == "step.begin", let id = JSONValue.string(event["uuid"]) {
                steps.insert(id); promptPending = false; ended = nil
            }
            if type == "step.end", let id = JSONValue.string(event["uuid"]) {
                steps.remove(id)
                if JSONValue.string(event["finishReason"]) == "end_turn",
                   let time = JSONValue.double(object["time"]) {
                    ended = time / 1_000; promptPending = false
                }
            }
            if type == "tool.call", let id = JSONValue.string(event["toolCallId"]) {
                tools.insert(id); ended = nil
            }
        }
        return KimiSignal(busy: promptPending || !steps.isEmpty || !tools.isEmpty, ended: ended)
    }

    func claude() -> RawToolState {
        let count = processes.count(named: "claude", excluding: ["Claude.app/"])
        var result = RawToolState(processOn: count > 0, detail: "\(count) 个进程")
        let root = environment.path(".claude", "projects")
        let window = TimeInterval(max(settings.busySeconds(for: "claude"), 1_800))
        for path in files.files(atDepth: 2, under: root, where: { $0.hasSuffix(".jsonl") }) {
            guard let modified = files.modificationTime(path), environment.now - modified < 86_400
            else {
                continue
            }
            var title: String?
            var lastType: String?
            var lastKinds: [String] = []
            var lastStopReason: String?
            var lastMessageTime: TimeInterval = modified
            guard files.manager.isReadableFile(atPath: path) else {
                result.sourceError = "部分会话日志不可读取"
                continue
            }
            let text = files.readTail(path, bytes: 1 << 20)
            if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               !text.split(whereSeparator: \.isNewline).contains(where: { JSONValue.object(from: String($0)) != nil }) {
                result.sourceError = "部分会话日志格式不兼容"
                continue
            }
            for raw in text.split(whereSeparator: \.isNewline) {
                let line = String(raw)
                if line.contains("\"ai-title\""), let object = JSONValue.object(from: line),
                    let value = JSONValue.string(object["aiTitle"]), !value.isEmpty
                {
                    title = value
                    continue
                }
                guard line.contains("\"user\"") || line.contains("\"assistant\""),
                    let object = JSONValue.object(from: line),
                    let type = JSONValue.string(object["type"]),
                    ["user", "assistant"].contains(type)
                else { continue }
                lastType = type
                lastStopReason = JSONValue.string((object["message"] as? JSONObject)?["stop_reason"])
                lastMessageTime = DateSupport.timestamp(object["timestamp"]) ?? modified
                if let message = object["message"] as? JSONObject,
                    let content = message["content"] as? [JSONObject]
                {
                    lastKinds = content.compactMap { JSONValue.string($0["type"]) }
                } else {
                    lastKinds = ["text"]
                }
            }
            if title == nil {
                let encoded = URL(fileURLWithPath: path).deletingLastPathComponent()
                    .lastPathComponent
                title =
                    encoded.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
                    .split(separator: "-").last.map(String.init) ?? "(未命名会话)"
            }
            guard let title else { continue }
            updateLatest(&result, title: title, timestamp: modified)
            if lastType == "assistant", lastStopReason == "end_turn" {
                let id = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
                result.activities.append(TaskActivity(
                    id: "\(id):ended:\(lastMessageTime)", sessionId: id, title: title,
                    phase: "ended", updatedAt: lastMessageTime))
            }
            if count > 0, environment.now - modified <= window,
                lastStopReason != "end_turn", lastType == "user" || lastKinds.contains("tool_use")
            {
                result.busy.append(
                    BusyItem(
                        id: URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent,
                        title: title)
                )
            }
        }
        return result
    }

    func dsh() -> RawToolState {
        let count = processes.count(matching: ".bin/dsh")
        var result = RawToolState(processOn: count > 0, detail: count > 0 ? "Web 在线" : "无进程")
        let window = TimeInterval(settings.busySeconds(for: "dsh"))
        // 投影缓存：dsh web 端实时维护的会话投影（标题/进行中的 step/待回工具调用），
        // 与 session.jsonl.zstd 事件流同步落盘，免解压即可拿到 busy 信号。
        let cachePath = environment.path(".dsh", "storages", "session_projcache.json")
        let cacheModified = files.modificationTime(cachePath)
        let cacheFresh = cacheModified.map { environment.now - $0 <= window } ?? false
        var titles: [String: String] = [:]
        if let root = files.read(cachePath).flatMap(JSONValue.object),
            let tables = root["tables"] as? JSONObject,
            let sessions = tables["sessions"] as? JSONObject
        {
            for (id, entry) in sessions {
                guard let entry = entry as? JSONObject else { continue }
                let rows = entry["rows"] as? JSONObject ?? [:]
                let identity = entry["identity"] as? JSONObject ?? [:]
                func rowValue(_ key: String) -> Any? {
                    (rows[key] as? JSONObject)?["val"]
                }
                let title =
                    JSONValue.string(rowValue("title")).flatMap({ $0.isEmpty ? nil : $0 })
                    ?? JSONValue.string(identity["cwd"]).flatMap {
                        URL(fileURLWithPath: $0).lastPathComponent.nonempty
                    } ?? "(未命名会话)"
                titles[id] = title
                let metadata = rowValue("sessionListMetadata") as? JSONObject ?? [:]
                let milliseconds =
                    JSONValue.double(metadata["lastPromptAt"])
                    ?? JSONValue.double(identity["createdAt"])
                if let milliseconds {
                    updateLatest(&result, title: title, timestamp: milliseconds / 1_000)
                }
                let stats = rowValue("sessionStats") as? JSONObject ?? [:]
                let openStep =
                    stats["openStep"] != nil && !(stats["openStep"] is NSNull)
                let pendingCalls = (stats["pendingCalls"] as? JSONObject)?.isEmpty == false
                // 进程退出可能留下永久 openStep：仅当缓存本身在窗口期内才采信
                if result.processOn, cacheFresh, openStep || pendingCalls {
                    result.busy.append(BusyItem(id: id, title: title))
                }
            }
        }
        else if files.manager.fileExists(atPath: cachePath) {
            result.sourceError = "会话投影缓存不可读或格式不兼容"
        }
        // projcache 滞后/缺失时的备份：事件流文件在 busy 窗口内有写入即视为进行中
        let sessionFiles = files.files(atDepth: 3, under: environment.path(".dsh", "sessions")) {
            $0.hasSuffix("/session.jsonl.zstd")
        }
        var knownBusy = Set(result.busy.map(\.id))
        for path in sessionFiles {
            guard let modified = files.modificationTime(path) else { continue }
            result.activity = max(result.activity, modified)
            let id = URL(fileURLWithPath: path).deletingLastPathComponent().lastPathComponent
            if !cacheFresh, result.processOn, environment.now - modified <= window,
                knownBusy.insert(id).inserted
            {
                result.busy.append(BusyItem(id: id, title: titles[id] ?? "(进行中会话)"))
            }
        }
        if let cacheModified {
            result.activity = max(result.activity, cacheModified)
        }
        if result.latest == nil,
            let latestFile = sessionFiles.max(by: {
                files.modificationTime($0) ?? 0 < files.modificationTime($1) ?? 0
            }),
            let modified = files.modificationTime(latestFile)
        {
            let slug = URL(fileURLWithPath: latestFile).deletingLastPathComponent()
                .deletingLastPathComponent().lastPathComponent
            let title =
                slug.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
                .split(separator: "-").last.map(String.init) ?? "(未命名会话)"
            updateLatest(&result, title: title, timestamp: modified)
        }
        return result
    }

    func hermes() -> RawToolState {
        let appCount = processes.count(named: "Hermes") + processes.count(named: "hermes")
        let heartbeat = environment.path(".hermes", "state", "gateway.heartbeat")
        let gatewayAlive =
            files.modificationTime(heartbeat).map { environment.now - $0 < 120 } ?? false
        var result = RawToolState(
            processOn: appCount > 0 || gatewayAlive,
            detail: appCount > 0 || gatewayAlive ? "在线" : "无进程"
        )
        let path = environment.path(".hermes", "state.db")
        guard let database = try? SQLiteDatabase(path: path, readOnly: true),
            let sessionColumns = try? database.columns(in: "sessions")
        else {
            if files.manager.fileExists(atPath: path) {
                result.sourceError = "会话数据库不可读或格式不兼容"
            }
            return result
        }
        if let row = try? database.query(
            """
            SELECT title, started_at FROM sessions
            WHERE archived = 0 AND title IS NOT NULL AND title != ''
            ORDER BY started_at DESC LIMIT 1
            """
        ).first, let title = row["title"]?.string, let timestamp = row["started_at"]?.double {
            result.latest = LatestItem(title: title, timestamp: timestamp)
        }
        var activity =
            (try? database.query("SELECT MAX(last_seen) AS activity FROM session_model_usage")
                .first?[
                    "activity"]?.double) ?? 0
        if sessionColumns.contains("last_activity_at"),
            let projected = try? database.query(
                "SELECT MAX(last_activity_at) AS activity FROM sessions"
            ).first?["activity"]?.double
        {
            activity = max(activity, projected)
        }
        result.activity = activity

        // Modern Hermes persists a final assistant row and an active turn lease.
        // Usage timestamps are historical evidence, never an ongoing turn signal.
        if let messageColumns = try? database.columns(in: "messages"),
           Set(["id", "session_id", "role", "timestamp", "finish_reason", "tool_calls"])
            .isSubset(of: messageColumns),
           Set(["id", "title", "archived"]).isSubset(of: sessionColumns) {
            collectHermesTurns(database, into: &result)
            return result
        }

        // 回合租约：回合开始即写入、进行中持续续期、结束即删除，
        // 是"正在执行回合"的实时信号（conversation_id 为压缩轮转的血缘根）。
        var leaseBusy: [BusyItem] = []
        var untitledLeaseIds: [String] = []
        if let leaseColumns = try? database.columns(in: "session_turn_leases"),
            Set(["conversation_id", "expires_at"]).isSubset(of: leaseColumns)
        {
            let rows =
                (try? database.query(
                    """
                    SELECT l.conversation_id AS id, s.title AS title
                    FROM session_turn_leases l LEFT JOIN sessions s ON s.id = l.conversation_id
                    WHERE l.expires_at > ?
                    """,
                    binds: [.real(environment.now)])) ?? []
            for row in rows {
                guard let id = row["id"]?.string else { continue }
                if let title = row["title"]?.string, !title.isEmpty {
                    leaseBusy.append(BusyItem(id: id, title: title))
                } else {
                    untitledLeaseIds.append(id)
                }
            }
        }
        // 会话活动心跳：回合内各节点触碰、至多 30 秒落库一次，
        // 覆盖全新会话首轮（sessions 行尚未建、跳过租约）的场景。
        var heartbeatBusy: [BusyItem] = []
        if sessionColumns.contains("last_activity_at") {
            let rows =
                (try? database.query(
                    """
                    SELECT id, title FROM sessions
                    WHERE last_activity_at > ? AND archived = 0
                        AND title IS NOT NULL AND title != ''
                    """,
                    binds: [.real(environment.now - 90)])) ?? []
            heartbeatBusy = rows.compactMap { row in
                guard let id = row["id"]?.string, let title = row["title"]?.string else {
                    return nil
                }
                return BusyItem(id: id, title: title)
            }
        }
        // 模型调用完成窗口：老 schema 或无租约路径的兜底。
        var usageBusy: [BusyItem] = []
        if let usageColumns = try? database.columns(in: "session_model_usage"),
            usageColumns.contains("last_seen"),
            Set(["id", "title", "archived"]).isSubset(of: sessionColumns)
        {
            let rows =
                (try? database.query(
                    """
                    SELECT DISTINCT s.id AS id, s.title AS title FROM sessions s
                    JOIN session_model_usage u ON u.session_id = s.id
                    WHERE u.last_seen > ? AND s.archived = 0 AND s.title IS NOT NULL AND s.title != ''
                    ORDER BY u.last_seen DESC
                    """,
                    binds: [.real(environment.now - TimeInterval(settings.busySeconds(for: "hermes")))]))
                ?? []
            usageBusy = rows.compactMap { row in
                guard let id = row["id"]?.string, let title = row["title"]?.string else {
                    return nil
                }
                return BusyItem(id: id, title: title)
            }
        }
        var seen: Set<String> = []
        result.busy = (leaseBusy + heartbeatBusy + usageBusy).filter {
            seen.insert($0.id).inserted
        }
        // 血缘根在压缩轮转后可能查无标题；该回合的当前 segment
        // 已由心跳/用量层覆盖，仅在无其他信号时用最近会话名兜底。
        if result.busy.isEmpty, !untitledLeaseIds.isEmpty {
            let fallback = result.latest?.title ?? "(进行中会话)"
            result.busy = untitledLeaseIds.map { BusyItem(id: $0, title: fallback) }
        }
        if result.busy.isEmpty, let latest = result.latest {
            let pids = processes.pids(matching: "hermes_cli")
            if transientConnections(pids: pids)["python", default: 0] > 0 {
                result.busy = [BusyItem(id: "conn-hermes", title: latest.title)]
            }
        }
        return result
    }

    private func collectHermesTurns(_ database: SQLiteDatabase, into result: inout RawToolState) {
        var leased = Set<String>()
        if let columns = try? database.columns(in: "session_turn_leases"), !columns.isEmpty {
            guard Set(["conversation_id", "expires_at"]).isSubset(of: columns),
                  let leaseRows = try? database.query(
                    "SELECT conversation_id AS id FROM session_turn_leases WHERE expires_at > ?",
                    binds: [.real(environment.now)]) else {
                result.sourceError = "无法读取回合租约"; return
            }
            leased = Set(leaseRows.compactMap { $0["id"]?.string })
        }
        guard let rows = try? database.query("""
            SELECT s.id, s.title, m.role, m.timestamp, m.finish_reason, m.tool_calls
            FROM sessions s JOIN messages m ON m.id =
                (SELECT MAX(id) FROM messages WHERE session_id = s.id)
            WHERE s.archived = 0 AND m.timestamp > ?
            """, binds: [.real(environment.now - 86_400)]) else {
            result.sourceError = "无法读取回合消息"; return
        }
        var seen = Set<String>()
        for row in rows {
            guard let id = row["id"]?.string, let time = row["timestamp"]?.double else { continue }
            seen.insert(id)
            let title = row["title"]?.string?.nonempty ?? "(进行中会话)"
            updateLatest(&result, title: title, timestamp: time)
            let role = row["role"]?.string ?? ""
            let reason = row["finish_reason"]?.string ?? ""
            let calls = row["tool_calls"]?.string ?? ""
            let pendingTools = !["", "null", "[]"].contains(calls)
            if leased.contains(id) {
                result.busy.append(BusyItem(id: id, title: title))
            } else if role == "assistant", !pendingTools,
                      ["stop", "end_turn", "length", "error", "agent_error", "content_filter"].contains(reason) {
                let phase = ["error", "agent_error", "content_filter"].contains(reason) ? "interrupted" : "ended"
                result.activities.append(TaskActivity(id: "\(id):\(phase):\(time)", sessionId: id,
                                                      title: title, phase: phase, updatedAt: time))
            } else if result.processOn, environment.now - time <= 1_800,
                      role == "user" || role == "tool" || pendingTools {
                result.busy.append(BusyItem(id: id, title: title))
            }
        }
        // A new/rotated conversation can acquire its lease before the first row exists.
        for id in leased.subtracting(seen) {
            result.busy.append(BusyItem(id: id, title: "(进行中会话)"))
        }
    }

    func zcode() -> RawToolState {
        let cliCount = processes.count(named: "zcode-cli")
        let appOn = processes.count(named: "ZCode") > 0
        var result = RawToolState(
            processOn: cliCount > 0 || appOn, detail: appOn ? "App 在线" : "无进程")
        let zcode = environment.path(".zcode")
        let version = files.children(of: zcode).filter {
            URL(fileURLWithPath: $0).lastPathComponent.hasPrefix("v")
        }
        .max { files.modificationTime($0) ?? 0 < files.modificationTime($1) ?? 0 }
        let databasePath =
            version.map { ($0 as NSString).appendingPathComponent("tasks-index.sqlite") }
            ?? environment.path(".zcode", "v2", "tasks-index.sqlite")
        var titles: [String: String] = [:]
        if let database = try? SQLiteDatabase(path: databasePath, readOnly: true),
            let columns = try? database.columns(in: "tasks"),
            Set(["task_id", "title", "updated_at"]).isSubset(of: columns)
        {
            if let rows = try? database.query("SELECT task_id, title FROM tasks WHERE deleted=0") {
                for row in rows {
                    if let id = row["task_id"]?.string {
                        titles[id] = row["title"]?.string ?? "(未知任务)"
                    }
                }
            }
            if let row = try? database.query(
                "SELECT title, updated_at/1000.0 AS timestamp FROM tasks WHERE deleted=0 ORDER BY updated_at DESC LIMIT 1"
            ).first,
                let title = row["title"]?.string, let timestamp = row["timestamp"]?.double
            {
                result.latest = LatestItem(title: title, timestamp: timestamp)
            }
        }
        else if files.manager.fileExists(atPath: databasePath) {
            result.sourceError = "会话索引数据库不可读或格式不兼容"
        }
        if let database = try? SQLiteDatabase(path: environment.path(".zcode", "cli", "db", "db.sqlite"), readOnly: true),
           let columns = try? database.columns(in: "turn_usage"),
           Set(["session_id", "turn_id", "status", "started_at", "completed_at"]).isSubset(of: columns),
           let rows = try? database.query("""
                SELECT t.session_id, t.turn_id, t.status, t.started_at, t.completed_at
                FROM turn_usage t WHERE t.started_at > ?
                  AND t.session_id NOT LIKE 'sess_subagent_%'
                  AND NOT EXISTS (SELECT 1 FROM turn_usage newer
                    WHERE newer.session_id = t.session_id AND newer.started_at > t.started_at)
                """, binds: [.real((environment.now - 86_400) * 1_000)]) {
            let messageColumns = (try? database.columns(in: "message")) ?? []
            let hasMessages = Set(["session_id", "time_created", "data"]).isSubset(of: messageColumns)
            // A just-submitted user message precedes creation of its running row.
            // Assistant/metadata writes after completion must not reopen the turn.
            let onsetQuery = hasMessages ? """
                SELECT session_id, MAX(time_created) / 1000.0 AS time FROM message
                WHERE time_created > ? AND json_valid(data) AND json_extract(data, '$.role') = 'user'
                GROUP BY session_id
                """ : """
                SELECT session_id, MAX(time_updated) / 1000.0 AS time FROM part
                WHERE time_updated > ? GROUP BY session_id
                """
            let parts = (try? database.query(onsetQuery, binds: [
                .real((environment.now - TimeInterval(settings.busySeconds(for: "zcode"))) * 1_000)])) ?? []
            var pendingParts = Dictionary(parts.compactMap { row -> (String, Double)? in
                guard let id = row["session_id"]?.string, !id.hasPrefix("sess_subagent_"), let time = row["time"]?.double else { return nil }
                return (id, time)
            }, uniquingKeysWith: max)
            for row in rows {
                guard let id = row["session_id"]?.string, let started = row["started_at"]?.double else { continue }
                let status = row["status"]?.string ?? ""
                let time = (row["completed_at"]?.double ?? started) / 1_000
                let title = titles[id] ?? "(未知任务)"
                let partTime = pendingParts.removeValue(forKey: id) ?? 0
                updateLatest(&result, title: title, timestamp: max(time, partTime))
                if partTime > time, status != "running", result.processOn {
                    result.busy.append(BusyItem(id: id, title: title))
                } else if status == "running", result.processOn, environment.now - time <= 10_800 {
                    result.busy.append(BusyItem(id: id, title: title))
                } else if ["completed", "error", "cancelled"].contains(status), row["completed_at"]?.double != nil {
                    let phase = status == "completed" ? "ended" : "interrupted"
                    result.activities.append(TaskActivity(id: "\(id):\(phase):\(row["turn_id"]?.string ?? "")",
                        sessionId: id, title: title, phase: phase, updatedAt: time))
                }
            }
            if result.processOn {
                for (id, time) in pendingParts {
                    let title = titles[id] ?? "(未知任务)"
                    updateLatest(&result, title: title, timestamp: time)
                    result.busy.append(BusyItem(id: id, title: title))
                }
            }
            return result
        }
        let cli = environment.path(".zcode", "cli")
        var activity: [String: TimeInterval] = [:]
        for path in files.files(
            atDepth: 1, under: (cli as NSString).appendingPathComponent("rollout"),
            where: { $0.hasSuffix(".jsonl") })
        {
            let name = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
            guard name.hasPrefix("model-io-sess_"), let time = files.modificationTime(path) else {
                continue
            }
            let id = String(name.dropFirst("model-io-".count))
            if !id.hasPrefix("sess_subagent_") { activity[id] = max(activity[id] ?? 0, time) }
        }
        for path in files.children(of: (cli as NSString).appendingPathComponent("artifacts")) {
            let id = URL(fileURLWithPath: path).lastPathComponent
            if id.hasPrefix("sess_"), !id.hasPrefix("sess_subagent_"),
                let time = files.modificationTime(path)
            {
                activity[id] = max(activity[id] ?? 0, time)
            }
        }
        for path in files.files(
            under: (cli as NSString).appendingPathComponent("agents"),
            where: { !$1 && $0.hasSuffix("/transcript.jsonl") })
        {
            let id = URL(fileURLWithPath: path).deletingLastPathComponent()
                .deletingLastPathComponent()
                .lastPathComponent
            if id.hasPrefix("sess_"), !id.hasPrefix("sess_subagent_"),
                let time = files.modificationTime(path)
            {
                activity[id] = max(activity[id] ?? 0, time)
            }
        }
        // part 表实时活动 + turn_usage 完成戳：用户消息提交即落库、
        // 每个 part 完成即落库，而 turn_usage 在回合结束时写入完成时间。
        // "活动晚于该会话最近一次回合完成" 即有新回合在跑——开始/结束都
        // 是轮询间隔级，且长生成期间无需窗口续命（活动恒晚于旧完成戳）。
        var turnFinished: [String: TimeInterval] = [:]
        var usageDatabaseAvailable = false
        let horizon = environment.now - TimeInterval(settings.busySeconds(for: "zcode"))
        if let database = try? SQLiteDatabase(
            path: environment.path(".zcode", "cli", "db", "db.sqlite"), readOnly: true),
            let partColumns = try? database.columns(in: "part"),
            Set(["session_id", "time_updated"]).isSubset(of: partColumns)
        {
            usageDatabaseAvailable = true
            let partRows =
                (try? database.query(
                    """
                    SELECT session_id, MAX(time_updated) / 1000.0 AS activity FROM part
                    WHERE time_updated > ? AND session_id NOT LIKE 'sess\\_subagent\\_%' ESCAPE '\\'
                    GROUP BY session_id
                    """,
                    binds: [.real(horizon * 1_000)])) ?? []
            for row in partRows {
                guard let id = row["session_id"]?.string,
                    let time = row["activity"]?.double
                else { continue }
                activity[id] = max(activity[id] ?? 0, time)
            }
            if let turnColumns = try? database.columns(in: "turn_usage"),
                Set(["session_id", "completed_at"]).isSubset(of: turnColumns)
            {
                let turnRows =
                    (try? database.query(
                        """
                        SELECT session_id, MAX(completed_at) / 1000.0 AS finished FROM turn_usage
                        WHERE completed_at > ? GROUP BY session_id
                        """,
                        binds: [.real(horizon * 1_000)])) ?? []
                for row in turnRows {
                    if let id = row["session_id"]?.string,
                        let finished = row["finished"]?.double
                    {
                        turnFinished[id] = finished
                    }
                }
            }
        }
        result.busy = activity.sorted { $0.value > $1.value }.compactMap { id, time in
            let withinWindow = environment.now - time < TimeInterval(
                settings.busySeconds(for: "zcode"))
            // db 可用时以"活动晚于完成戳（留 5 秒落库时差容差）"判定，
            // 兜住长生成；否则退回纯窗口判定（老版本无 db.sqlite）。
            let working =
                withinWindow
                && (!usageDatabaseAvailable || time > (turnFinished[id] ?? 0) + 5)
            return working ? BusyItem(id: id, title: titles[id] ?? "(未知任务)") : nil
        }
        if result.latest == nil, let (id, time) = activity.max(by: { $0.value < $1.value }) {
            result.latest = LatestItem(title: titles[id] ?? "(未知任务)", timestamp: time)
        }
        result.activity = activity.values.max() ?? 0
        for (id, finished) in turnFinished where finished >= (activity[id] ?? 0) - 5 {
            result.activities.append(TaskActivity(
                id: "\(id):ended:\(finished)", sessionId: id, title: titles[id] ?? "(未知任务)",
                phase: "ended", updatedAt: finished))
        }
        if result.busy.isEmpty, result.activities.isEmpty, appOn, let latest = result.latest,
            transientConnections(processNames: ["ZCode"])["ZCode", default: 0] > 0
        {
            result.busy = [BusyItem(id: "conn-zcode", title: latest.title)]
        }
        return result
    }

    private func updateLatest(_ result: inout RawToolState, title: String, timestamp: TimeInterval)
    {
        if result.latest.map({ timestamp > $0.timestamp }) ?? true {
            result.latest = LatestItem(title: title, timestamp: timestamp)
        }
        result.activity = max(result.activity, timestamp)
    }

    /// lsof 全表扫描较贵（数十至数百毫秒），而它只兜底"空闲但疑似仍有
    /// 活动连接"的判定：30 秒内直接复用缓存结果。缓存落在 conn_state.json，
    /// App / SwiftBar / Übersicht 多个前端共享同一份节流。
    private static let lsofThrottleSeconds: TimeInterval = 30

    private func transientConnections(
        processNames: [String] = [], pids: [Int] = [], minimumAge: TimeInterval = 15,
        maximumAge: TimeInterval = 300
    ) -> [String: Int] {
        let cachePath = environment.path(".ai-statusbar", "conn_state.json")
        let state = files.read(cachePath).flatMap(JSONValue.object) ?? [:]
        if let computedAt = JSONValue.double(state["_lsof_at"]),
            let cached = state["_lsof_result"] as? JSONObject,
            environment.now - computedAt < Self.lsofThrottleSeconds
        {
            return cached.mapValues { JSONValue.int($0) ?? 0 }
        }
        var arguments = ["-nP", "-iTCP", "-sTCP:ESTABLISHED", "-a"]
        processNames.forEach { arguments += ["-c", $0] }
        pids.forEach { arguments += ["-p", String($0)] }
        let output = processes.output(executable: "/usr/sbin/lsof", arguments: arguments)
        var current: [String: Set<String>] = [:]
        for raw in output.split(whereSeparator: \.isNewline).dropFirst() {
            let line = String(raw)
            let parts = line.split(whereSeparator: \.isWhitespace).map(String.init)
            guard parts.count >= 9, let endpoint = parts.last, endpoint.contains("->"),
                !line.contains("->127.0.0.1"), !line.contains("->[::1]"),
                !line.contains("->localhost")
            else { continue }
            let local = endpoint.components(separatedBy: "->")[0]
            current[parts[0], default: []].insert(local.components(separatedBy: ":").last ?? local)
        }
        let old = state
        var saved: JSONObject = [:]
        var result: [String: Int] = [:]
        for (name, ports) in current {
            let previous = old[name] as? JSONObject ?? [:]
            var next: JSONObject = [:]
            var count = 0
            for port in ports {
                let first = JSONValue.double(previous[port]) ?? environment.now
                next[port] = first
                if environment.now - first >= minimumAge && environment.now - first < maximumAge {
                    count += 1
                }
            }
            saved[name] = next
            result[name] = count
        }
        saved["_lsof_at"] = environment.now
        var cachedResult: JSONObject = [:]
        for (name, count) in result { cachedResult[name] = count }
        saved["_lsof_result"] = cachedResult
        try? files.writePrivateJSON(saved, to: cachePath)
        return result
    }
}

extension String {
    fileprivate var nonempty: String? { isEmpty ? nil : self }
}
