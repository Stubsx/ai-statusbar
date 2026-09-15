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
        let title: String
        let updated: TimeInterval
        let kind: String
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
            groups[id, default: []].append(SessionFile(path: path, modified: modified, kind: header.kind))
        }
        for (id, segments) in groups {
            let sorted = segments.sorted { $0.modified > $1.modified }
            guard let newest = sorted.first else { continue }
            let stored = threads[id]
            let info = ThreadInfo(
                title: stored?.title ?? "(未命名会话)", updated: stored?.updated ?? newest.modified,
                kind: sorted.lazy.compactMap(\.kind).first ?? stored?.kind ?? "ide")
            let timestamp = info.updated > 0 ? info.updated : newest.modified
            let latest = LatestItem(title: info.title, timestamp: timestamp, sessionId: id)
            let signal = sessionSignal(segments: sorted, sessionID: id, title: info.title,
                                       processAlive: info.kind == "cli" ? cliCount > 0 : appCount > 0,
                                       cache: cache)
            if info.kind == "cli" {
                update(&result.cli, latest: latest, modified: newest.modified)
                if let activity = signal.activity { result.cli.activities.append(activity) }
                if signal.unreadable { result.cli.sourceError = "部分会话日志不可读取" }
                if signal.busy {
                    result.cli.busy.append(BusyItem(id: id, title: info.title))
                }
            } else {
                update(&result.ide, latest: latest, modified: newest.modified)
                if let activity = signal.activity { result.ide.activities.append(activity) }
                if signal.unreadable { result.ide.sourceError = "部分会话日志不可读取" }
                if signal.busy {
                    result.ide.busy.append(BusyItem(id: id, title: info.title))
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
        if let database = try? SQLiteDatabase(path: databasePath, readOnly: true),
            let columns = try? database.columns(in: "threads"),
            Set(["id", "title", "updated_at", "source"]).isSubset(of: columns),
            let rows = try? database.query(
                "SELECT id, title, updated_at, source FROM threads WHERE archived=0"
            )
        {
            let values = rows.reduce(into: [String: ThreadInfo]()) { result, row in
                guard let id = row["id"]?.string, !id.isEmpty else { return }
                let source = row["source"]?.string ?? ""
                let title = row["title"]?.string.flatMap { $0.isEmpty ? nil : $0 } ?? "(未命名会话)"
                result[id] = ThreadInfo(
                    title: title,
                    updated: row["updated_at"]?.double ?? 0,
                    kind: ["cli", "exec"].contains(source) ? "cli" : "ide"
                )
            }
            if !values.isEmpty { return values }
        }

        let index = environment.path(".codex", "session_index.jsonl")
        return files.jsonLines(files.readText(index) ?? "").reduce(into: [String: ThreadInfo]()) {
            result, row in
            guard let id = JSONValue.string(row["id"]), !id.isEmpty else { return }
            result[id] = ThreadInfo(
                title: JSONValue.string(row["thread_name"]) ?? "(未命名会话)",
                updated: DateSupport.timestamp(row["updated_at"]) ?? 0,
                kind: "cli"
            )
        }
    }

    private struct SessionFile {
        let path: String
        let modified: TimeInterval
        let kind: String?
    }

    /// The session header identifies the actual thread and source even while the
    /// thread DB is migrating, locked, or a different CLI/App schema was most
    /// recently touched. Compaction continuation files are named
    /// rollout-…-<线程id>_<新rolloutid>.jsonl, so the thread id can only come
    /// from the header, not the filename.
    private func sessionHeader(_ path: String) -> (id: String?, kind: String?) {
        guard let handle = FileHandle(forReadingAtPath: path) else { return (nil, nil) }
        defer { try? handle.close() }
        let data = (try? handle.read(upToCount: 65_536)) ?? Data()
        guard let line = String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline).first,
              let object = JSONValue.object(from: String(line)),
              JSONValue.string(object["type"]) == "session_meta",
              let payload = object["payload"] as? JSONObject else { return (nil, nil) }
        let id = JSONValue.string(payload["id"]) ?? JSONValue.string(payload["session_id"])
        let kind = JSONValue.string(payload["source"]).map {
            ["cli", "exec"].contains($0) ? "cli" : "ide"
        }
        return (id, kind)
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
