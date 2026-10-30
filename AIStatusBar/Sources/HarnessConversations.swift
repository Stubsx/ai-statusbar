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
    var usageRequest: UsageRequest? = nil
    var sessionSpeed: SessionUsageSpeed? = nil

    var current: Bool { ["working", "waiting_input", "waiting_permission"].contains(phase) }
    var speedText: String? {
        if let sessionSpeed {
            guard let tps = sessionSpeed.tps else { return nil }
            let kind = sessionSpeed.metricKind == "effective" ? "有效"
                : (sessionSpeed.metricKind == "generation" ? "生成" : "整轮")
            return String(format: "%.1f t/s · %@", tps, kind)
        }
        guard let usageRequest, let value = usageRequest.generationTps ?? usageRequest.averageTps
        else { return nil }
        let kind = usageRequest.metricKind == "effective"
            ? "有效" : (usageRequest.generationTps != nil ? "生成" : "整轮")
        return String(format: "%.1f t/s · %@", value, kind)
    }
    var firstTokenText: String? {
        let seconds: Double?
        if let sessionSpeed { seconds = sessionSpeed.firstTokenSeconds }
        else { seconds = usageRequest?.timeToFirstToken }
        guard let seconds else { return nil }
        let estimated = ["kimi", "kimi-work"].contains(sessionSpeed?.tool ?? usageRequest?.tool ?? "")
        let label = "首词" + (estimated ? "约" : "")
        let duration = seconds < 1
            ? String(format: "%.0f ms", seconds * 1_000)
            : String(format: "%.1f s", seconds)
        return "\(label) \(duration)"
    }
    var metricsText: String? {
        let parts = [speedText, firstTokenText].compactMap { $0 }
        guard !parts.isEmpty else { return nil }
        return (sessionSpeed == nil ? "最新 " : "平均 ") + parts.joined(separator: " · ")
    }
    func metricsText(hovered: Bool) -> String? {
        hovered ? (latestMetricsText ?? metricsText) : metricsText
    }
    var metricsHelp: String? {
        guard metricsText != nil else { return nil }
        var lines = [String]()
        if let latestMetricsText { lines.append(latestMetricsText) }
        if sessionSpeed != nil {
            if let metricsText { lines.append(metricsText) }
        }
        return lines.joined(separator: "\n")
    }
    var latestMetricsText: String? {
        guard let usageRequest = sessionSpeed?.latest ?? usageRequest else { return nil }
        let row = HarnessConversation(id: id, toolKey: toolKey, sessionId: sessionId,
            title: title, phase: phase, timestamp: timestamp, eventIDs: [],
            needsAttention: false, usageRequest: usageRequest)
        let parts = [row.speedText, row.firstTokenText].compactMap { $0 }
        return parts.isEmpty ? nil : "最新 " + parts.joined(separator: " · ")
    }
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

    static func groups(
        tools: [ToolStatus], events: [TaskRecord], requests: [UsageRequest] = [],
        sessions: [SessionUsageSpeed] = []
    ) -> [HarnessConversationGroup] {
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
            let rows = conversations(tool: tool, events: byTool[tool.key] ?? [], requests: requests,
                                     sessions: sessions)
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

    static func conversations(
        tool: ToolStatus, events: [TaskRecord], requests: [UsageRequest] = [],
        sessions: [SessionUsageSpeed] = []
    ) -> [HarnessConversation] {
        // Unknown IDs must not merge unrelated records into one conversation.
        func identity(_ record: TaskRecord) -> String {
            record.sessionId.isEmpty ? "event:\(record.id)" : "session:\(record.sessionId)"
        }
        func speed(_ sessionId: String?) -> UsageRequest? {
            guard let sessionId else { return nil }
            return requests.first {
                $0.sessionId == sessionId
                    && ($0.tool != "codex" || $0.metricKind == "effective")
                    && ($0.tool == tool.key || ($0.tool == "codex" && tool.key.hasPrefix("codex")))
            }
        }
        func summary(_ sessionId: String?) -> SessionUsageSpeed? {
            guard let sessionId else { return nil }
            return sessions.first {
                $0.sessionId == sessionId
                    && ($0.tool == tool.key || ($0.tool == "codex" && tool.key.hasPrefix("codex")))
            }
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
                                             eventIDs: history.map(\.id), needsAttention: false,
                                             usageRequest: summary(item.id)?.latest ?? speed(item.id),
                                             sessionSpeed: summary(item.id)))
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
                                             needsAttention: true,
                                             usageRequest: summary(record.sessionId)?.latest ?? speed(record.sessionId),
                                             sessionSpeed: summary(record.sessionId)))
        }
        // Keep waiting conversations visible before running work, then recent results.
        return rows.filter { $0.current && $0.phase != "working" }
            + rows.filter { $0.phase == "working" } + rows.filter { !$0.current }
    }
}
