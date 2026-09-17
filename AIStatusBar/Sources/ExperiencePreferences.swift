import Foundation

struct ExperiencePreferences: Codable {
    var quotaAlerts = false
    var quotaThreshold = 20
    var quotaRecovery = false
    var muteUntil: TimeInterval = 0
    var privacyMode = false
    var mergeNotifications = true
    var eventExport = false
    var eventExportTitles = false
    var onboardingCompleted = false

    init() {}
    private enum CodingKeys: String, CodingKey {
        case quotaAlerts, quotaThreshold, quotaRecovery, muteUntil, privacyMode
        case mergeNotifications, eventExport, eventExportTitles, onboardingCompleted
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        quotaAlerts = try c.decodeIfPresent(Bool.self, forKey: .quotaAlerts) ?? false
        quotaThreshold = min(50, max(1, try c.decodeIfPresent(Int.self, forKey: .quotaThreshold) ?? 20))
        quotaRecovery = try c.decodeIfPresent(Bool.self, forKey: .quotaRecovery) ?? false
        muteUntil = try c.decodeIfPresent(TimeInterval.self, forKey: .muteUntil) ?? 0
        privacyMode = try c.decodeIfPresent(Bool.self, forKey: .privacyMode) ?? false
        mergeNotifications = try c.decodeIfPresent(Bool.self, forKey: .mergeNotifications) ?? true
        eventExport = try c.decodeIfPresent(Bool.self, forKey: .eventExport) ?? false
        eventExportTitles = try c.decodeIfPresent(Bool.self, forKey: .eventExportTitles) ?? false
        onboardingCompleted = try c.decodeIfPresent(Bool.self, forKey: .onboardingCompleted) ?? false
    }
}

struct QuotaAlert {
    let toolKey: String
    let title: String
    let body: String
}

final class QuotaMonitor {
    private struct WindowState: Codable, Equatable {
        var reset: Int
        var lowNotified: Bool
        var recoveryNotified: Bool
        var wasLow: Bool
        var updatedAt: TimeInterval
    }
    private var states: [String: WindowState] = [:]
    private let url: URL
    private(set) var storageError: String?
    init(directory: URL) {
        url = directory.appendingPathComponent("quota-alerts.json")
        if let data = try? Data(contentsOf: url),
           let stored = try? JSONDecoder().decode([String: WindowState].self, from: data) { states = stored }
    }

    func observe(_ tools: [ToolStatus], threshold: Int, recovery: Bool, now: TimeInterval) -> [QuotaAlert] {
        var alerts: [QuotaAlert] = []
        var visited = Set<String>()
        var changed = false
        for tool in tools.sorted(by: { $0.key < $1.key }) {
            let account = tool.key.hasPrefix("codex") ? "codex" : tool.key
            guard !visited.contains(account), let quota = tool.quota, quota.notice == nil,
                  quota.updatedAt > 0, Double(quota.updatedAt) <= now + 60,
                  now - Double(quota.updatedAt) <= QuotaPresentation.freshHorizon(windows: quota.windows),
                  tool.health?.quotaState != "stale", !quota.windows.isEmpty else { continue }
            visited.insert(account)
            for window in quota.windows {
                guard window.usedPercent.isFinite, (0...100).contains(window.usedPercent),
                      window.resetsAt == 0 || Double(window.resetsAt) > now else { continue }
                let key = "\(account)|\(window.kind)|\(window.label)"
                let low = 100 - window.usedPercent <= Double(threshold)
                let previous = states[key]
                var state = previous ?? WindowState(reset: window.resetsAt, lowNotified: false,
                                                     recoveryNotified: false, wasLow: false, updatedAt: now)
                if state.reset != window.resetsAt {
                    state = WindowState(reset: window.resetsAt, lowNotified: false,
                                        recoveryNotified: false, wasLow: previous?.wasLow ?? false, updatedAt: now)
                }
                if low && !state.lowNotified {
                    alerts.append(QuotaAlert(toolKey: tool.key, title: "\(tool.name) 配额提醒",
                                             body: "\(window.label)剩余 \(Int((100 - window.usedPercent).rounded()))%"))
                    state.lowNotified = true
                } else if !low && state.wasLow && recovery && !state.recoveryNotified {
                    alerts.append(QuotaAlert(toolKey: tool.key, title: "\(tool.name) 配额已恢复",
                                             body: "\(window.label)当前剩余 \(Int((100 - window.usedPercent).rounded()))%"))
                    state.recoveryNotified = true
                }
                state.wasLow = low
                if previous == nil || now - state.updatedAt >= 3_600 || previous?.reset != state.reset
                    || previous?.wasLow != low || previous?.lowNotified != state.lowNotified
                    || previous?.recoveryNotified != state.recoveryNotified { state.updatedAt = now }
                if previous != state {
                    states[key] = state
                    changed = true
                }
            }
        }
        states = states.filter { now - $0.value.updatedAt < 35 * 86_400 }
        if changed {
            do {
                try PrivateStore.write(JSONEncoder().encode(states), to: url)
                storageError = nil
            } catch { storageError = "配额提醒去重记录无法保存" }
        }
        return alerts
    }
}
