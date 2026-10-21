import Foundation

struct CodexResult {
    var cli = RawToolState()
    var ide = RawToolState()
}

struct CodexCollector {
    let environment: CollectorEnvironment
    let settings: CollectorSettings
    let files: FileSupport
    let processes: ProcessSupport

    private struct ThreadInfo {
        /// 清洗后的标题；为 nil 时需要从会话日志推导或按子代理标注。
        let title: String?
        let updated: TimeInterval
        let kind: String
        /// 子代理线程的昵称（如 Heisenberg），非子代理为 nil。
        let subagentName: String?
        /// guardian 评审等内部子步骤：不是用户会话，完全不展示。
        let internalSubagent: Bool
    }

    func collect() -> CodexResult {
        // 只统计用户真正打开的交互式 CLI；App/编辑器托管的无头服务进程
        //（ChatGPT/Codex App、VS Code/Cursor 扩展拉起的 codex app-server / mcp-server）不算。
        let cliCount = processes.count(
            named: "codex",
            excluding: ["ChatGPT.app/", "Codex.app/", "app-server", "mcp-server"])
        let appCount = processes.count(named: "ChatGPT") + processes.count(named: "Codex")
        var result = CodexResult()
        result.cli.processOn = cliCount > 0
        result.cli.detail = "\(cliCount) 个进程"
        result.ide.processOn = appCount > 0
        result.ide.detail = appCount > 0 ? "App 在线" : "无进程"

        let cache = SourceStateCache(home: environment.homeDirectory)
        defer { cache.save() }
        let threads = loadThreads()
        let sessionsRoot = environment.path(".codex", "sessions")
        let sessionFiles = files.files(atDepth: 4, under: sessionsRoot) { $0.hasSuffix(".jsonl") }
        // 同一线程可能有多个 rollout 分段：压缩后续写的新文件名是
        // rollout-…-<线程id>_<新rolloutid>.jsonl，从文件名推不出线程 id。
        // 以 session_meta 头部里的线程 id 归并，避免一个会话显示成多条“(未命名会话)”。
        var groups: [String: [SessionFile]] = [:]
        for path in sessionFiles {
            guard let modified = files.modificationTime(path), environment.now - modified < 86_400
            else {
                continue
            }
            let header = sessionHeader(path)
            let id = header.id.flatMap { $0.isEmpty ? nil : $0 } ?? sessionID(from: path)
            groups[id, default: []].append(
                SessionFile(path: path, modified: modified, kind: header.kind,
                            subagentName: header.subagentName,
                            internalSubagent: header.internalSubagent))
        }
        for (id, segments) in groups {
            let sorted = segments.sorted { $0.modified > $1.modified }
            guard let newest = sorted.first else { continue }
            let stored = threads[id]
            // 子代理身份优先信线程库；库读不到（锁定、schema 迁移）时用会话头兜底，
            // 避免 guardian 评审这类内部线程被当成普通 CLI 会话。
            let subagentName = stored?.subagentName
                ?? sorted.lazy.compactMap(\.subagentName).first
            let internalSubagent = (stored?.internalSubagent ?? false)
                || sorted.contains(where: \.internalSubagent)
            // guardian 评审是父会话内部的 safety 步骤（用户从未把它当会话），
            // 不进 latest/busy/活动列表，也不会触发"已结束"历史记录。
            if internalSubagent { continue }
            // 标题优先级：线程库清洗后的标题 → 子代理标注 → 从日志推导的首条真实用户消息。
            let title = stored?.title
                ?? subagentName.map { $0.isEmpty ? "子代理会话" : "子代理·\($0)" }
                ?? derivedTitle(segments: sorted)
                ?? "(未命名会话)"
            let info = ThreadInfo(
                title: title, updated: stored?.updated ?? newest.modified,
                kind: sorted.lazy.compactMap(\.kind).first ?? stored?.kind ?? "ide",
                subagentName: nil, internalSubagent: false)
            let timestamp = info.updated > 0 ? info.updated : newest.modified
            let latest = LatestItem(title: title, timestamp: timestamp, sessionId: id)
            let signal = sessionSignal(segments: sorted, sessionID: id, title: title,
                                       processAlive: info.kind == "cli" ? cliCount > 0 : appCount > 0,
                                       cache: cache)
            // 子代理线程的结束/中断只是父会话的内部步骤，不作为独立会话展示；
            // 仍在运行的子代理保留，反映真实进行中的工作。
            let activity: TaskActivity? = signal.activity.flatMap {
                guard subagentName != nil,
                    $0.phase == "ended" || $0.phase == "interrupted"
                else { return $0 }
                return nil
            }
            if info.kind == "cli" {
                update(&result.cli, latest: latest, modified: newest.modified)
                if let activity { result.cli.activities.append(activity) }
                if signal.unreadable { result.cli.sourceError = "部分会话日志不可读取" }
                if signal.busy {
                    result.cli.busy.append(BusyItem(id: id, title: title))
                }
            } else {
                update(&result.ide, latest: latest, modified: newest.modified)
                if let activity { result.ide.activities.append(activity) }
                if signal.unreadable { result.ide.sourceError = "部分会话日志不可读取" }
                if signal.busy {
                    result.ide.busy.append(BusyItem(id: id, title: title))
                }
            }
        }
        return result
    }

    private func loadThreads() -> [String: ThreadInfo] {
        let codexDirectory = environment.path(".codex")
        let databasePath =
            files.latest(matchingPrefix: "state_", suffix: ".sqlite", in: codexDirectory)
            ?? environment.path(".codex", "state_5.sqlite")
        // name 是 Codex App 生成、侧边栏展示的简明标题；title 只是首条用户消息原文。
        // 旧库可能还没有 name / agent_nickname 列，按实际列动态拼 SELECT。
        if let database = try? SQLiteDatabase(path: databasePath, readOnly: true),
            let columns = try? database.columns(in: "threads"),
            Set(["id", "title", "updated_at", "source"]).isSubset(of: columns)
        {
            let hasName = columns.contains("name")
            let hasNickname = columns.contains("agent_nickname")
            let select = ["id", "title", "updated_at", "source",
                          hasName ? "name" : nil,
                          hasNickname ? "agent_nickname" : nil]
                .compactMap { $0 }.joined(separator: ", ")
            if let rows = try? database.query("SELECT \(select) FROM threads WHERE archived=0") {
                let values = rows.reduce(into: [String: ThreadInfo]()) { result, row in
                    guard let id = row["id"]?.string, !id.isEmpty else { return }
                    let source = row["source"]?.string ?? ""
                    result[id] = ThreadInfo(
                        title: Self.cleanedTitle(row["name"]?.string)
                            ?? Self.cleanedTitle(row["title"]?.string),
                        updated: row["updated_at"]?.double ?? 0,
                        kind: ["cli", "exec"].contains(source) ? "cli" : "ide",
                        subagentName: row["agent_nickname"]?.string.flatMap { $0.isEmpty ? nil : $0 }
                            ?? Self.subagentName(from: source),
                        internalSubagent: Self.isInternalSubagent(source: source)
                    )
                }
                if !values.isEmpty { return values }
            }
        }

        let index = environment.path(".codex", "session_index.jsonl")
        return files.jsonLines(files.readText(index) ?? "").reduce(into: [String: ThreadInfo]()) {
            result, row in
            guard let id = JSONValue.string(row["id"]), !id.isEmpty else { return }
            result[id] = ThreadInfo(
                title: Self.cleanedTitle(JSONValue.string(row["thread_name"])),
                updated: DateSupport.timestamp(row["updated_at"]) ?? 0,
                kind: "cli",
                subagentName: nil,
                internalSubagent: false
            )
        }
    }

    /// Codex 把首条用户消息原样存为线程标题，其中常带上下文块
    ///（剪贴板图片说明、AGENTS.md 注入等）。真正的请求跟在 "## My request:" 之后；
    /// 纯上下文块没有请求正文，返回 nil 让调用方从日志推导。
    static func cleanedTitle(_ raw: String?) -> String? {
        guard var text = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty
        else { return nil }
        if let range = text.range(of: Self.requestMarker) {
            text = text[range.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
        } else if Self.preambleMarkers.contains(where: { text.hasPrefix($0) }) {
            return nil
        }
        return text.isEmpty ? nil : text
    }

    private static let requestMarker = "## My request:"
    private static let preambleMarkers = [
        "# Files mentioned by the user:",
        "# AGENTS.md instructions",
        "<environment_context>",
        "<INSTRUCTIONS>",
    ]

    /// 线程库的 source 字段对子代理线程是 JSON：
    /// {"subagent":{"thread_spawn":{...,"agent_nickname":"Heisenberg"}}} 或
    /// {"subagent":{"other":"guardian"}}。普通来源是 "cli"/"vscode" 等裸字符串。
    static func subagentName(from source: String) -> String? {
        guard source.hasPrefix("{"), let object = JSONValue.object(from: source)
        else { return nil }
        return subagentName(from: object)
    }

    static func subagentName(from object: JSONObject) -> String? {
        guard let subagent = object["subagent"] as? JSONObject else { return nil }
        if let spawn = subagent["thread_spawn"] as? JSONObject {
            return JSONValue.string(spawn["agent_nickname"]) ?? ""
        }
        if let other = JSONValue.string(subagent["other"]) { return other }
        return ""
    }

    /// {"subagent":{"other":...}} 是 Codex 自己的内部步骤（目前是 guardian 安全评审），
    /// 与用户在侧边栏能看到的有昵称委派子代理（thread_spawn）不同，不作为会话展示。
    static func isInternalSubagent(source: String) -> Bool {
        guard source.hasPrefix("{"), let object = JSONValue.object(from: source)
        else { return false }
        return isInternalSubagent(source: object)
    }

    static func isInternalSubagent(source object: JSONObject) -> Bool {
        guard let subagent = object["subagent"] as? JSONObject else { return false }
        return subagent["other"] != nil
    }

    /// 线程库没有标题（或标题只是上下文块）时，从最新分段的头部按序找第一条
    /// 真实用户消息：跳过 AGENTS.md 注入、environment_context 等前导块。
    private func derivedTitle(segments: [SessionFile]) -> String? {
        for segment in segments.prefix(3) {
            guard let handle = FileHandle(forReadingAtPath: segment.path) else { continue }
            let data = (try? handle.read(upToCount: 1 << 19)) ?? Data()
            try? handle.close()
            for line in String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline)
            where line.contains("\"message\"") {
                guard let object = JSONValue.object(from: String(line)),
                    JSONValue.string(object["type"]) == "response_item",
                    let payload = object["payload"] as? JSONObject,
                    JSONValue.string(payload["type"]) == "message",
                    JSONValue.string(payload["role"]) == "user",
                    let content = payload["content"] as? [JSONObject]
                else { continue }
                let joined = content.compactMap { JSONValue.string($0["text"]) }
                    .joined(separator: " ")
                if let title = Self.cleanedTitle(joined) {
                    return title.count > 100 ? String(title.prefix(100)) + "…" : title
                }
            }
        }
        return nil
    }

    private struct SessionFile {
        let path: String
        let modified: TimeInterval
        let kind: String?
        let subagentName: String?
        let internalSubagent: Bool
    }

    /// The session header identifies the actual thread and source even while the
    /// thread DB is migrating, locked, or a different CLI/App schema was most
    /// recently touched. Compaction continuation files are named
    /// rollout-…-<线程id>_<新rolloutid>.jsonl, so the thread id can only come
    /// from the header, not the filename.
    /// source 对子代理线程是对象（{"subagent":…}）而非字符串，这里一并解析，
    /// 线程库读取失败时仍能识别 guardian 评审等内部线程。
    private func sessionHeader(_ path: String)
        -> (id: String?, kind: String?, subagentName: String?, internalSubagent: Bool)
    {
        guard let handle = FileHandle(forReadingAtPath: path) else { return (nil, nil, nil, false) }
        defer { try? handle.close() }
        let data = (try? handle.read(upToCount: 65_536)) ?? Data()
        guard let line = String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline).first,
              let object = JSONValue.object(from: String(line)),
              JSONValue.string(object["type"]) == "session_meta",
              let payload = object["payload"] as? JSONObject else { return (nil, nil, nil, false) }
        let id = JSONValue.string(payload["id"]) ?? JSONValue.string(payload["session_id"])
        var kind: String?
        var subagentName: String?
        var internalSubagent = false
        if let source = JSONValue.string(payload["source"]) {
            kind = ["cli", "exec"].contains(source) ? "cli" : "ide"
        } else if let source = payload["source"] as? JSONObject {
            subagentName = Self.subagentName(from: source)
            internalSubagent = Self.isInternalSubagent(source: source)
        }
        if JSONValue.string(payload["thread_source"]) == "guardian_review" {
            internalSubagent = true
            subagentName = subagentName ?? "guardian"
        }
        return (id, kind, subagentName, internalSubagent)
    }

    private func sessionID(from path: String) -> String {
        let name = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
        let parts = name.split(separator: "-")
        guard parts.count >= 5 else { return "" }
        return parts.suffix(5).joined(separator: "-")
    }

    private func update(_ state: inout RawToolState, latest: LatestItem, modified: TimeInterval) {
        if state.latest.map({ latest.timestamp > $0.timestamp }) ?? true { state.latest = latest }
        state.activity = max(state.activity, modified, latest.timestamp)
    }

    /// 分段按修改时间倒序传入。压缩后的新分段可能还没有任何任务事件
    ///（用户尚未开新一轮），此时沿用上一分段的结束/中断状态；
    /// 只有最新分段带有任务事件或挂起调用时才以它为准。
    private func sessionSignal(
        segments: [SessionFile], sessionID: String, title: String, processAlive: Bool,
        cache: SourceStateCache
    ) -> (busy: Bool, activity: TaskActivity?, unreadable: Bool) {
        for (index, segment) in segments.enumerated() {
            guard files.manager.isReadableFile(atPath: segment.path) else { return (false, nil, true) }
            let parsed: ParsedSignal = cache.value(at: segment.path) {
                parseSignal(path: segment.path, modified: segment.modified)
            }
            if parsed.unreadable { return (false, nil, true) }
            let decisive = parsed.lastTask != nil || !parsed.pending.isEmpty
            if !decisive, index + 1 < segments.count { continue }
            return finalizeSignal(parsed, sessionID: sessionID, title: title,
                                  processAlive: processAlive, modified: segment.modified)
        }
        return (false, nil, false)
    }

    private func finalizeSignal(
        _ parsed: ParsedSignal, sessionID: String, title: String, processAlive: Bool,
        modified: TimeInterval
    ) -> (busy: Bool, activity: TaskActivity?, unreadable: Bool) {
        let lastTask = parsed.lastTask, lifecycleTime = parsed.lifecycleTime, pending = parsed.pending
        func activity(_ phase: String, _ time: TimeInterval, token: String = "") -> TaskActivity {
            TaskActivity(id: "\(sessionID):\(phase):\(time):\(token)", sessionId: sessionID,
                         title: title, phase: phase, updatedAt: time)
        }
        // 结束／中断是明确事件；即使应用随后退出，也保留它的含义。
        if lastTask == "task_complete", pending.isEmpty {
            return (false, activity("ended", lifecycleTime), false)
        }
        if lastTask == "turn_aborted", pending.isEmpty {
            return (false, activity("interrupted", lifecycleTime), false)
        }
        guard processAlive,
              environment.now - modified < TimeInterval(max(settings.busySeconds(for: "codex"), 10_800))
        else { return (false, nil, false) }
        // 仅 request_user_input 的未返回调用能证明等待回答，普通工具调用不推断为审批。
        if let waiting = pending.sorted(by: { $0.key < $1.key }).first(where: {
            $0.value.name == "request_user_input" || $0.value.name.hasSuffix("__request_user_input")
        }) {
            return (false, activity("waiting_input", waiting.value.time, token: waiting.key), false)
        }
        let busy = lastTask == "task_started" || !pending.isEmpty
        return (busy, busy ? activity("working", lifecycleTime) : nil, false)
    }

    private struct PendingCall: Codable {
        let name: String
        let time: TimeInterval
    }
    private struct ParsedSignal: Codable {
        let lastTask: String?
        let lifecycleTime: TimeInterval
        let pending: [String: PendingCall]
        let unreadable: Bool
    }

    private func parseSignal(path: String, modified: TimeInterval) -> ParsedSignal {
        let tail = files.readTail(path, bytes: 1 << 20)
        if !tail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           !tail.split(whereSeparator: \.isNewline).contains(where: { JSONValue.object(from: String($0)) != nil }) {
            return ParsedSignal(lastTask: nil, lifecycleTime: modified, pending: [:], unreadable: true)
        }
        let lifecycle = lastTaskEvent(in: tail) ?? lastTaskEvent(in: files.readText(path))
        let payload = lifecycle?["payload"] as? JSONObject
        var lastTask = JSONValue.string(payload?["type"])
        var lifecycleTime = DateSupport.timestamp(lifecycle?["timestamp"]) ?? modified
        var pending: [String: PendingCall] = [:]
        let signalLines = tail.split(whereSeparator: \.isNewline).filter {
            $0.contains("event_msg") || $0.contains("function_call") || $0.contains("custom_tool_call")
        }
        for line in signalLines {
            guard let object = JSONValue.object(from: String(line)) else { continue }
            guard let payload = object["payload"] as? JSONObject,
                  let type = JSONValue.string(payload["type"]) else { continue }
            if JSONValue.string(object["type"]) == "event_msg",
               Self.taskEventMarkers.contains(type) {
                lastTask = type
                lifecycleTime = DateSupport.timestamp(object["timestamp"]) ?? modified
                pending.removeAll()
            } else if JSONValue.string(object["type"]) == "response_item" {
                if ["function_call", "custom_tool_call"].contains(type),
                   let id = JSONValue.string(payload["call_id"]) ?? JSONValue.string(payload["id"]) {
                    let name = JSONValue.string(payload["name"]) ?? ""
                    pending[id] = PendingCall(name: name, time: name.contains("request_user_input")
                        ? DateSupport.timestamp(object["timestamp"]) ?? modified : lifecycleTime)
                } else if ["function_call_output", "custom_tool_call_output"].contains(type),
                          let id = JSONValue.string(payload["call_id"]) {
                    pending.removeValue(forKey: id)
                }
            }
        }
        return ParsedSignal(lastTask: lastTask, lifecycleTime: lifecycleTime, pending: pending, unreadable: false)
    }

    private static let taskEventMarkers = ["task_started", "task_complete", "turn_aborted"]

    /// 倒序找文本里最后一次任务事件（task_started / task_complete / turn_aborted）。
    /// 每个候选行按事件结构校验；正文里恰好提到这些词的行会被跳过（最多回溯 32 个候选，
    /// 再多视为没有事件，由调用方走全文件兜底或按 pending 判定）。
    private func lastTaskEvent(in text: String?) -> JSONObject? {
        guard let text, !text.isEmpty else { return nil }
        var searchUpper = text.endIndex
        for _ in 0..<32 {
            var hit: (index: String.Index, marker: String)?
            for marker in Self.taskEventMarkers {
                if let range = text.range(
                    of: marker, options: [.backwards, .literal],
                    range: text.startIndex..<searchUpper),
                    hit == nil || range.lowerBound > hit!.index
                {
                    hit = (range.lowerBound, marker)
                }
            }
            guard let found = hit else { return nil }
            let lineStart =
                text[..<found.index].lastIndex(of: "\n").map { text.index(after: $0) }
                ?? text.startIndex
            let lineEnd = text[found.index...].firstIndex(of: "\n") ?? text.endIndex
            if let object = JSONValue.object(from: String(text[lineStart..<lineEnd])),
                JSONValue.string(object["type"]) == "event_msg",
                let payload = object["payload"] as? JSONObject,
                JSONValue.string(payload["type"]) == found.marker
            {
                return object
            }
            searchUpper = lineStart
        }
        return nil
    }
}
