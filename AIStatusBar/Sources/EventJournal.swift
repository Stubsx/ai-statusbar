import Foundation

struct TaskRecord: Codable, Identifiable, Equatable {
    let id: String
    let toolKey: String
    let toolName: String
    let sessionId: String
    let title: String
    let phase: String
    let timestamp: TimeInterval
    let evidence: String
    var acknowledged: Bool
    var resolved: Bool

    var waiting: Bool { ["waiting_input", "waiting_permission"].contains(phase) }
    var needsAttention: Bool {
        !acknowledged && (waiting ? !resolved : ["ended", "interrupted", "failed"].contains(phase))
    }
    var priority: Int { waiting ? 0 : (phase == "failed" ? 1 : 2) }
    var label: String {
        switch phase {
        case "waiting_input": return resolved ? "等待回答已解除" : "等待你回答"
        case "waiting_permission": return resolved ? "等待确认已解除" : "等待你确认"
        case "ended": return "本轮已结束，可查看结果"
        case "interrupted": return "本轮已中断"
        case "failed": return "任务出现异常"
        default: return "暂无新活动"
        }
    }
    var symbol: String {
        switch phase {
        case "waiting_input", "waiting_permission": return "hand.raised.fill"
        case "ended": return "checkmark.circle"
        case "interrupted": return "pause.circle"
        case "failed": return "exclamationmark.triangle"
        default: return "clock"
        }
    }
}

/// Local, bounded history. Acknowledgement affects Lingmou only, never the original tool.
final class EventJournal {
    private struct Snapshot: Codable {
        var schema = 1
        var records: [TaskRecord]
        var seen: [String: TimeInterval]
    }
    private(set) var records: [TaskRecord] = []
    private(set) var storageError: String?
    private var seen: [String: TimeInterval] = [:]
    private var tracker = BusySessionTracker()
    private var observedTools = Set<String>()
    private let url: URL
    private var canWrite = true
    private var lastSavedData: Data?

    init(directory: URL) {
        url = directory.appendingPathComponent("task-history.json")
        if FileManager.default.fileExists(atPath: url.path) {
            do {
                let data = try Data(contentsOf: url)
                let snapshot = try JSONDecoder().decode(Snapshot.self, from: data)
                guard snapshot.schema == 1 else {
                    storageError = "历史记录版本暂不兼容"
                    canWrite = false
                    return
                }
                records = snapshot.records
                seen = snapshot.seen
                lastSavedData = data
            } catch {
                storageError = "无法读取最近事件，请检查本地存储"
                canWrite = false
            }
        }
    }

    func invalidate() {
        tracker.reset()
        observedTools.removeAll()
    }

    /// Returns only new live events for notification/export; startup history does not replay alerts.
    func observe(_ tools: [ToolStatus], now: TimeInterval) -> [TaskRecord] {
        let initial = Set(tools.map(\.key)).subtracting(observedTools)
        let inferred = tracker.observe(tools, at: now)
        var candidates: [(ToolStatus, TaskActivity)] = []
        for tool in tools where tool.health?.state != "error" {
            let activities = tool.activities ?? []
            let current = Dictionary(activities.map { ($0.sessionId, $0) },
                                     uniquingKeysWith: { $0.updatedAt > $1.updatedAt ? $0 : $1 })
            for index in records.indices where records[index].toolKey == tool.key && !records[index].resolved {
                let record = records[index]
                let activity = current[record.sessionId]
                let returnedToWork = (tool.activeItems ?? tool.busyItems).contains { $0.id == record.sessionId }
                let movedOn = activity.map {
                    $0.updatedAt >= record.timestamp
                        && ($0.phase == "working" || "\(tool.key)|\($0.id)" != record.id)
                } ?? false
                if returnedToWork || movedOn || (record.waiting && tool.state == "off") {
                    records[index].resolved = true
                    records[index].acknowledged = true
                } else if record.waiting, tool.activities != nil,
                          tool.capabilities?.eventPhases.contains(record.phase) == true,
                          current[record.sessionId] == nil {
                    records[index].resolved = true
                }
            }
            candidates += activities.filter {
                ["ended", "interrupted", "failed", "waiting_input", "waiting_permission"].contains($0.phase)
                    && $0.evidence == "explicit"
            }.map { (tool, $0) }
        }
        for group in inferred {
            guard let tool = tools.first(where: { $0.key == group.toolKey }) else { continue }
            for item in group.items {
                // Explicit outcome and waiting signals always take precedence over disappearance.
                guard !(tool.activities ?? []).contains(where: {
                    $0.sessionId == item.id && $0.phase != "working"
                }) else { continue }
                candidates.append((tool, TaskActivity(
                    id: "\(item.id):inactive:\(now)", sessionId: item.id, title: item.title,
                    phase: "inactive", updatedAt: now, evidence: "inferred")))
            }
        }
        var live: [TaskRecord] = []
        for (tool, activity) in candidates.sorted(by: { $0.1.updatedAt < $1.1.updatedAt }) {
            guard activity.updatedAt.isFinite, activity.updatedAt > 0,
                  activity.updatedAt <= now + 60, activity.updatedAt >= now - 7 * 86_400 else { continue }
            let id = "\(tool.key)|\(activity.id)"
            guard seen[id] == nil else { continue }
            seen[id] = now
            let waiting = ["waiting_input", "waiting_permission"].contains(activity.phase)
            let record = TaskRecord(id: id, toolKey: tool.key, toolName: tool.name,
                                    sessionId: activity.sessionId, title: activity.title,
                                    phase: activity.phase, timestamp: activity.updatedAt, evidence: activity.evidence,
                                    acknowledged: initial.contains(tool.key) && !waiting, resolved: false)
            records.append(record)
            if !initial.contains(tool.key) { live.append(record) }
        }
        observedTools.formUnion(tools.filter { $0.health?.state != "error" }.map(\.key))
        records = Array(records.filter { $0.timestamp >= now - 7 * 86_400 }
            .sorted { $0.timestamp > $1.timestamp }.prefix(200))
        seen = seen.filter { $0.value >= now - 30 * 86_400 }
        if seen.count > 5_000 {
            seen = Dictionary(uniqueKeysWithValues: seen.sorted { $0.value > $1.value }.prefix(5_000).map { ($0.key, $0.value) })
        }
        save()
        return live
    }

    func acknowledge(_ id: String) {
        acknowledge([id])
    }

    func acknowledge(_ ids: [String]) {
        let selected = Set(ids)
        var changed = false
        for index in records.indices where selected.contains(records[index].id) && !records[index].acknowledged {
            records[index].acknowledged = true
            changed = true
        }
        if changed { save() }
    }

    func clear() {
        records.removeAll { !$0.waiting || $0.resolved }
        canWrite = true
        // Keep deduplication state so clearing history cannot replay old notifications.
        save()
    }

    private func save() {
        guard canWrite else { return }
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(Snapshot(records: records, seen: seen))
            if data != lastSavedData {
                try PrivateStore.write(data, to: url)
                lastSavedData = data
            }
            storageError = nil
        } catch {
            storageError = "最近事件暂时无法保存，请检查磁盘空间与目录权限"
        }
    }
}

enum PrivateStore {
    static func write(_ data: Data, to url: URL) throws {
        let manager = FileManager.default
        try manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                    attributes: [.posixPermissions: 0o700])
        try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.deletingLastPathComponent().path)
        try data.write(to: url, options: .atomic)
        try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
