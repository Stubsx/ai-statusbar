import Foundation

/// Kimi Code can retain a clearly dated snapshot between messages. Other tools
/// only display current quota; a historical reading never becomes current again.
struct QuotaPresentation {
    let windows: [QuotaWindow]
    let lastSuccessAt: TimeInterval?
    let unavailableReason: String
    let isCurrent: Bool
    var isHistorical: Bool { !isCurrent && !windows.isEmpty }

    init(tool: ToolStatus, now: TimeInterval) {
        let quota = tool.quota
        let timestamp = quota.map { TimeInterval($0.updatedAt) } ?? 0
        let validTimestamp = timestamp > 0 && timestamp <= now + 60
        let validWindows = (quota?.windows ?? []).filter {
            $0.usedPercent.isFinite && (0...100).contains($0.usedPercent)
        }
        // Error-only responses use updatedAt for the failed attempt, not a successful read.
        lastSuccessAt = validTimestamp && !validWindows.isEmpty ? timestamp : nil
        let notice = quota?.notice?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        unavailableReason = notice.isEmpty ? "尚未取得最新额度，请检查连接状态。" : notice
        let maxAge: TimeInterval = tool.key == "kimi-work" ? 4_200 : 600
        let fresh = validTimestamp && now - timestamp <= maxAge && notice.isEmpty
            && !["stale", "unavailable", "login_required", "disabled"].contains(tool.health?.quotaState ?? "")
        let currentWindows = validWindows.filter { $0.resetsAt == 0 || TimeInterval($0.resetsAt) > now }
        if tool.key == "kimi", validTimestamp, notice.isEmpty,
           !["unavailable", "login_required", "disabled"].contains(tool.health?.quotaState ?? "") {
            windows = validWindows
            isCurrent = fresh && !windows.isEmpty && currentWindows.count == windows.count
        } else {
            windows = fresh ? currentWindows : []
            isCurrent = !windows.isEmpty
        }
    }
}
