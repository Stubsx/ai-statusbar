import Foundation

/// 只表示已知会话持续离开忙碌列表；不证明任务成功完成。
struct InactiveTaskGroup {
    let toolKey: String
    let toolName: String
    let items: [BusyItem]
}

/// 快照完整性与三轮去抖共用一处实现，不依赖通知权限或桌宠界面。
struct BusySessionTracker {
    private struct Observation {
        var known: [String: BusyItem] = [:]
        var missingRounds: [String: Int] = [:]
    }

    private var observations: [String: Observation] = [:]
    private let graceRounds = 3
    private var lastAdvanceAt: TimeInterval?

    /// 采集失败后重新建立基线，避免把未知期间的变化解释成结束。
    mutating func reset() {
        observations.removeAll()
        lastAdvanceAt = nil
    }

    mutating func observe(_ tools: [ToolStatus], at timestamp: TimeInterval? = nil) -> [InactiveTaskGroup] {
        if let timestamp, let lastAdvanceAt, timestamp < lastAdvanceAt { reset() }
        let advances = timestamp.map { now in lastAdvanceAt.map { now - $0 >= 10 } ?? true } ?? true
        if advances { lastAdvanceAt = timestamp }
        var next: [String: Observation] = [:]
        var events: [InactiveTaskGroup] = []

        for tool in tools {
            guard tool.health?.state != "error" else { continue }
            // 离线、未知状态或状态与数量冲突时丢弃旧依据。
            // 工具整体缺失也会被排除在 next 外，恢复后重新建立基线。
            guard (tool.state == "busy" && tool.busyCount > 0)
                || (tool.state == "idle" && tool.busyCount == 0)
            else { continue }

            var current: [String: BusyItem] = [:]
            let items = tool.activeItems ?? tool.busyItems
            for item in items {
                guard !item.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                current[item.id] = item
            }
            var observation = observations[tool.key] ?? Observation()
            for (id, item) in current {
                observation.known[id] = item
                observation.missingRounds.removeValue(forKey: id)
            }

            // 采集器最多返回 5 条预览。数量不匹配、重复或空 ID 都说明
            // 当前快照不能证明某个未展示的任务已停止，必须中断缺失计数。
            let isComplete = tool.busyCount == items.count && current.count == items.count
            if isComplete {
                var inactive: [BusyItem] = []
                for id in observation.known.keys.sorted() where current[id] == nil {
                    guard advances else { continue }
                    let rounds = (observation.missingRounds[id] ?? 0) + 1
                    if rounds >= graceRounds {
                        if let item = observation.known.removeValue(forKey: id) {
                            inactive.append(item)
                        }
                        observation.missingRounds.removeValue(forKey: id)
                    } else {
                        observation.missingRounds[id] = rounds
                    }
                }
                if !inactive.isEmpty {
                    events.append(InactiveTaskGroup(
                        toolKey: tool.key, toolName: tool.name, items: inactive))
                }
            } else {
                observation.missingRounds.removeAll()
            }
            next[tool.key] = observation
        }

        observations = next
        return events
    }
}
