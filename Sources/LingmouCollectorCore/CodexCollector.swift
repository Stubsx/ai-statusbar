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

        let threads = loadThreads()
        let sessionsRoot = environment.path(".codex", "sessions")
        let sessionFiles = files.files(atDepth: 4, under: sessionsRoot) { $0.hasSuffix(".jsonl") }
        for path in sessionFiles {
            guard let modified = files.modificationTime(path), environment.now - modified < 86_400
            else {
                continue
            }
            let id = sessionID(from: path)
            let info = threads[id] ?? ThreadInfo(title: "(未命名会话)", updated: modified, kind: "ide")
            let timestamp = info.updated > 0 ? info.updated : modified
            let latest = LatestItem(title: info.title, timestamp: timestamp)
            if info.kind == "cli" {
                update(&result.cli, latest: latest, modified: modified)
                if isBusy(path: path, processAlive: cliCount > 0, modified: modified) {
                    result.cli.busy.append(BusyItem(id: id, title: info.title))
                }
            } else {
                update(&result.ide, latest: latest, modified: modified)
                if isBusy(path: path, processAlive: appCount > 0, modified: modified) {
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

    private func isBusy(path: String, processAlive: Bool, modified: TimeInterval) -> Bool {
        guard processAlive,
            environment.now - modified
                < TimeInterval(max(settings.busySeconds(for: "codex"), 10_800))
        else {
            return false
        }
        var lastTask: String?
        if let text = files.readText(path) {
            for line in text.split(whereSeparator: \.isNewline) {
                let value = String(line)
                guard
                    value.contains("task_started") || value.contains("task_complete")
                        || value.contains("turn_aborted"),
                    let object = JSONValue.object(from: value),
                    JSONValue.string(object["type"]) == "event_msg",
                    let payload = object["payload"] as? JSONObject,
                    let type = JSONValue.string(payload["type"]),
                    ["task_started", "task_complete", "turn_aborted"].contains(type)
                else { continue }
                lastTask = type
            }
        }
        var pending = Set<String>()
        for object in files.jsonLines(files.readTail(path)) {
            guard let payload = object["payload"] as? JSONObject,
                let type = JSONValue.string(payload["type"])
            else { continue }
            if JSONValue.string(object["type"]) == "event_msg",
                ["task_started", "task_complete", "turn_aborted"].contains(type)
            {
                lastTask = type
            } else if JSONValue.string(object["type"]) == "response_item" {
                if ["function_call", "custom_tool_call"].contains(type),
                    let id = JSONValue.string(payload["call_id"]) ?? JSONValue.string(payload["id"])
                {
                    pending.insert(id)
                } else if ["function_call_output", "custom_tool_call_output"].contains(type),
                    let id = JSONValue.string(payload["call_id"])
                {
                    pending.remove(id)
                }
            }
        }
        return lastTask == "task_started" || !pending.isEmpty
    }
}
