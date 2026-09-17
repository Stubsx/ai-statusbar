import Foundation

/// Quota cards have three states: current (fresh read), stale snapshot (last successful
/// read, shown dimmed with its age) and unavailable (never read or every window expired).
/// Some tools only refresh their token when a real session runs, so a read failure with
/// an unexpired historical snapshot still shows the snapshot instead of hiding it.
struct QuotaPresentation {
    let windows: [QuotaWindow]
    let lastSuccessAt: TimeInterval?
    let notice: String
    let unavailableReason: String
    let isCurrent: Bool
    /// True when `windows` holds an outdated snapshot rather than a fresh read.
    let isStale: Bool

    /// 快照保鲜期按窗口长度分级：月窗一天、周窗十二小时、小时级窗口一小时。
    /// 与采集端 ToolSupport.quotaFreshHorizon 保持一致（App 侧是独立的 QuotaWindow 类型）。
    static func freshHorizon(windows: [QuotaWindow]) -> TimeInterval {
        var horizon: TimeInterval = 3_600
        for window in windows {
            switch window.kind {
            case "month": horizon = max(horizon, 86_400)
            case "week": horizon = max(horizon, 43_200)
            default: break
            }
        }
        return horizon
    }

    init(tool: ToolStatus, now: TimeInterval) {
        let quota = tool.quota
        let timestamp = quota.map { TimeInterval($0.updatedAt) } ?? 0
        let validTimestamp = timestamp > 0 && timestamp <= now + 60
        let validWindows = (quota?.windows ?? []).filter {
            $0.usedPercent.isFinite && (0...100).contains($0.usedPercent)
        }
        // Error-only responses use updatedAt for the failed attempt, not a successful read.
        lastSuccessAt = validTimestamp && !validWindows.isEmpty ? timestamp : nil
        notice = quota?.notice?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        unavailableReason = notice.isEmpty ? "尚未取得最新额度，请检查连接状态。" : notice
        let quotaState = tool.health?.quotaState ?? ""
        // stale 不参与拦截：采集端已按同一套分级保鲜期判定，且 App 与内置采集器版本
        // 可能短暂不一致，新鲜度以本地分级 horizon 为准。
        let fresh = validTimestamp && now - timestamp <= Self.freshHorizon(windows: validWindows)
            && notice.isEmpty
            && !["unavailable", "login_required", "disabled"].contains(quotaState)
        let currentWindows = validWindows.filter { $0.resetsAt == 0 || TimeInterval($0.resetsAt) > now }
        // 登录失效或在线配额关闭时不展示旧快照，避免把过期数据伪装成现状。
        let snapshotAllowed = validTimestamp && !["login_required", "disabled"].contains(quotaState)
        if fresh {
            windows = currentWindows
            isStale = false
        } else {
            windows = snapshotAllowed ? currentWindows : []
            isStale = !windows.isEmpty
        }
        isCurrent = fresh && !windows.isEmpty
    }
}
