import Foundation

/// One row per conversation, shared by the desktop panel and the native menu.
struct HarnessConversation: Identifiable {
    let id: String
    let toolKey: String
    let sessionId: String?
    let title: String
    let phase: String
    let timestamp: TimeInterval?
    let eventIDs: [String]
    let needsAttention: Bool

    var current: Bool { ["working", "waiting_input", "waiting_permission"].contains(phase) }
    var label: String {
        switch phase {
        case "working": return "运行中"
        case "waiting_input": return "待回答"
        case "waiting_permission": return "待确认"
        case "ended": return "已结束"
        case "interrupted": return "已中断"
        case "failed": return "异常"
        case "inactive": return "暂无活动"
        default: return "最近"
        }
    }
    var symbol: String {
        switch phase {
        case "working": return "play.fill"
        case "waiting_input", "waiting_permission": return "hand.raised"
        case "ended": return "checkmark.circle"
        case "interrupted": return "pause.circle"
        case "failed": return "exclamationmark.triangle"
        default: return "clock"
        }
    }
}

struct HarnessConversationGroup: Identifiable {
    let tool: ToolStatus
    let conversations: [HarnessConversation]
    var id: String { tool.key }
    var runningCount: Int { conversations.filter { $0.phase == "working" }.count }
    var attentionCount: Int { conversations.filter(\.needsAttention).count }
    var statusLabel: String {
        var parts: [String] = []
        if runningCount > 0 { parts.append("\(runningCount) 个运行中") }
        if attentionCount > 0 { parts.append("\(attentionCount) 条待查看") }
        if !parts.isEmpty { return parts.joined(separator: " · ") }
        if tool.health?.state == "error" { return "读取异常" }
        return tool.state == "off" ? "未运行" : "空闲"
    }

    /// The native menu keeps an overflow submenu; the panel displays every row.
    var preview: [HarnessConversation] {
        Array(conversations.filter(\.current).prefix(3))
            + Array(conversations.filter { !$0.current }.prefix(2))
    }
}

enum HarnessConversations {
    static func workingItems(for tool: ToolStatus) -> [BusyItem] {
        guard tool.state == "busy", tool.health?.state != "error" else { return [] }
        var seen = Set<String>()
        return (tool.activeItems ?? tool.busyItems).filter { !$0.id.isEmpty && seen.insert($0.id).inserted }
    }

    static func groups(tools: [ToolStatus], events: [TaskRecord]) -> [HarnessConversationGroup] {
        let byTool = Dictionary(grouping: events, by: \.toolKey)
        var allTools = tools
        let known = Set(tools.map(\.key))
        for (key, records) in byTool where !known.contains(key) {
            guard let latest = records.max(by: { $0.timestamp < $1.timestamp }) else { continue }
            allTools.append(ToolStatus(key: key, letter: "", name: latest.toolName, state: "off",
                                       busyCount: 0, busyItems: [], detail: "", latestTitle: nil,
                                       latestAge: nil, quota: nil))
        }
        return allTools.compactMap { tool in
            let rows = conversations(tool: tool, events: byTool[tool.key] ?? [])
            guard tool.state != "off" || tool.health?.state == "error" || !rows.isEmpty else { return nil }
            return HarnessConversationGroup(tool: tool, conversations: rows)
        }.sorted {
            func priority(_ group: HarnessConversationGroup) -> Int {
                if group.conversations.contains(where: { $0.phase == "working" }) { return 0 }
                if group.conversations.contains(where: \.needsAttention) { return 1 }
                if group.tool.health?.state == "error" { return 2 }
                return group.conversations.isEmpty ? 4 : 3
            }
            return priority($0) == priority($1) ? $0.id < $1.id : priority($0) < priority($1)
        }
    }

    static func conversations(tool: ToolStatus, events: [TaskRecord]) -> [HarnessConversation] {
        // Unknown IDs must not merge unrelated records into one conversation.
        func identity(_ record: TaskRecord) -> String {
            record.sessionId.isEmpty ? "event:\(record.id)" : "session:\(record.sessionId)"
        }
        let records = events.filter { $0.toolKey == tool.key }.sorted {
            $0.timestamp == $1.timestamp ? $0.id < $1.id : $0.timestamp > $1.timestamp
        }
        let bySession = Dictionary(grouping: records, by: identity)
        var seen = Set<String>()
        var rows: [HarnessConversation] = []
        // A new running turn supersedes old outcomes for the same conversation.
        for item in workingItems(for: tool) {
            let id = "session:\(item.id)"
            guard seen.insert(id).inserted else { continue }
            let history = bySession[id] ?? []
            rows.append(HarnessConversation(id: id, toolKey: tool.key, sessionId: item.id,
                                             title: item.title, phase: "working", timestamp: nil,
                                             eventIDs: history.map(\.id), needsAttention: false))
        }
        for record in records {
            let id = identity(record)
            guard seen.insert(id).inserted else { continue }
            // Decide from the latest turn before filtering: an old unread result
            // must not reappear after its replacement was read or resolved.
            guard record.needsAttention, !record.resolved else { continue }
            let history = bySession[id] ?? []
            rows.append(HarnessConversation(id: id, toolKey: tool.key,
                                             sessionId: record.sessionId.isEmpty ? nil : record.sessionId,
                                             title: record.title, phase: record.phase, timestamp: record.timestamp,
                                             eventIDs: history.map(\.id),
                                             needsAttention: true))
        }
        // Keep waiting conversations visible before running work, then recent results.
        return rows.filter { $0.current && $0.phase != "working" }
            + rows.filter { $0.phase == "working" } + rows.filter { !$0.current }
    }
}
