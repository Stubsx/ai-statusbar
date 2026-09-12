import Foundation

var checks = 0
func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else { fatalError(message) }
    checks += 1
}
let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
defer { try? FileManager.default.removeItem(at: directory) }
let now: TimeInterval = 2_000_000_000
func activity(_ phase: String, at time: TimeInterval, token: String = "turn") -> TaskActivity {
    TaskActivity(id: "\(token):\(phase):\(time)", sessionId: "session", title: "虚构任务", phase: phase, updatedAt: time)
}
func tool(_ activities: [TaskActivity] = [], busy: Bool = false, key: String = "codex-ide",
          quota: ToolQuota? = nil) -> ToolStatus {
    var value = ToolStatus(key: key, letter: "C", name: "测试工具", state: busy ? "busy" : "idle",
                          busyCount: busy ? 1 : 0, busyItems: busy ? [BusyItem(id: "session", title: "虚构任务")] : [],
                          detail: "", latestTitle: nil, latestAge: nil, quota: quota)
    value.activities = activities
    value.capabilities = ToolCapabilities(eventPhases: ["ended", "interrupted", "waiting_input"])
    return value
}

do {
    let journal = EventJournal(directory: directory.appendingPathComponent("history"))
    check(journal.observe([tool([activity("working", at: now)], busy: true)], now: now).isEmpty, "Startup must not alert")
    let ended = tool([activity("ended", at: now + 10)])
    let events = journal.observe([ended], now: now + 10)
    check(events.count == 1 && events[0].phase == "ended", "Explicit end must produce one live event")
    check(journal.records.filter(\.needsAttention).count == 1, "End must remain pending review")
    for round in 2...5 {
        check(journal.observe([ended], now: now + Double(round * 10)).isEmpty, "End cannot duplicate as inactivity")
    }
    journal.acknowledge(events[0].id)
    check(journal.records.filter(\.needsAttention).isEmpty, "Review affects pending list")
    let reloaded = EventJournal(directory: directory.appendingPathComponent("history"))
    check(reloaded.records.count == 1, "History must survive restart")
    check(reloaded.observe([ended], now: now + 60).isEmpty, "Restart must not replay notifications")
    reloaded.clear()
    check(reloaded.records.isEmpty, "Clear must remove visible history")
    check(reloaded.observe([ended], now: now + 70).isEmpty && reloaded.records.isEmpty, "Clear must retain deduplication")
    let mode = try FileManager.default.attributesOfItem(atPath: directory.appendingPathComponent("history/task-history.json").path)[.posixPermissions] as? NSNumber
    check(mode?.intValue == 0o600, "History must be private")
}

do {
    let journal = EventJournal(directory: directory.appendingPathComponent("waiting"))
    let waiting = tool([activity("waiting_input", at: now)])
    check(journal.observe([waiting], now: now).isEmpty, "Startup wait should be visible without replayed alert")
    check(journal.records.filter(\.needsAttention).count == 1, "Current waiting task must be visible at startup")
    journal.acknowledge(journal.records[0].id)
    check(journal.records.filter(\.needsAttention).isEmpty, "Viewing a waiting event clears its reminder")
    check(journal.records[0].waiting && !journal.records[0].resolved, "Reading cannot resolve the original waiting task")
    check(journal.observe([waiting], now: now + 1).isEmpty && journal.records.filter(\.needsAttention).isEmpty,
          "Repeated waiting snapshot cannot restore a read reminder")
    let reloaded = EventJournal(directory: directory.appendingPathComponent("waiting"))
    check(reloaded.records[0].acknowledged && !reloaded.records[0].needsAttention, "Read waiting state survives restart")
    check(reloaded.observe([waiting], now: now + 2).isEmpty && reloaded.records.filter(\.needsAttention).isEmpty,
          "Startup cannot replay an already read waiting event")
    let newWait = reloaded.observe([tool([activity("waiting_permission", at: now + 3, token: "next")])], now: now + 3)
    check(newWait.count == 1 && newWait[0].needsAttention, "A new wait in the same session must still remind")
    reloaded.acknowledge(newWait[0].id)
    check(reloaded.records.filter(\.needsAttention).isEmpty && !reloaded.records[0].resolved,
          "Permission reminders can be read without granting permission")
    _ = journal.observe([tool([activity("working", at: now + 10)], busy: true)], now: now + 10)
    check(journal.records.filter(\.needsAttention).isEmpty, "Returned-to-work task resolves the waiting state")
    let interrupted = journal.observe([tool([activity("interrupted", at: now + 20)])], now: now + 20)
    check(interrupted.count == 1 && !interrupted[0].label.contains("完成"), "Interruption must never claim completion")
}

do {
    let journal = EventJournal(directory: directory.appendingPathComponent("inferred"))
    _ = journal.observe([tool(busy: true)], now: now)
    for second in 1...29 {
        check(journal.observe([tool()], now: now + Double(second)).isEmpty, "Manual refresh must not accelerate grace")
    }
    let events = journal.observe([tool()], now: now + 30)
    check(events.count == 1 && events[0].phase == "inactive", "No-activity fallback must remain conservative")
    check(events[0].label == "暂无新活动" && !events[0].needsAttention, "Inactivity is not a completed task")
    journal.invalidate()
    check(journal.observe([tool([activity("ended", at: now + 40)])], now: now + 40).isEmpty,
          "Recovery after missing collection cannot replay completion alerts")
}

do {
    let journal = EventJournal(directory: directory.appendingPathComponent("initial"))
    check(journal.observe([tool([activity("ended", at: now - 500)])], now: now).isEmpty, "Historic event must not alert")
    check(journal.records.filter(\.needsAttention).isEmpty, "Historic end must not flood pending list")
    check(journal.observe([tool([activity("ended", at: now + 5_000)])], now: now + 10).isEmpty, "Future event must be rejected")
}

func quota(_ percent: Double, reset: Int = Int(now + 1_000), timestamp: Int = Int(now)) -> ToolQuota {
    ToolQuota(plan: nil, windows: [QuotaWindow(kind: "primary", label: "五小时", usedPercent: percent,
                                               resetsAt: reset, windowMinutes: 300, components: nil)],
              updatedAt: timestamp, notice: nil)
}
do {
    let monitor = QuotaMonitor(directory: directory.appendingPathComponent("quota"))
    let low = [tool(key: "codex-ide", quota: quota(85)), tool(key: "codex-cli", quota: quota(85))]
    check(monitor.observe(low, threshold: 20, recovery: true, now: now).count == 1, "Shared account quota alerts only once")
    check(monitor.observe(low, threshold: 20, recovery: true, now: now + 10).isEmpty, "Low quota must not repeat")
    let reloaded = QuotaMonitor(directory: directory.appendingPathComponent("quota"))
    check(reloaded.observe(low, threshold: 20, recovery: true, now: now + 20).isEmpty, "Quota dedup survives restart")
    check(reloaded.observe([tool(quota: quota(10))], threshold: 20, recovery: true, now: now + 30).count == 1,
          "Recovery must notify once when enabled")
    check(reloaded.observe([tool(quota: quota(85))], threshold: 20, recovery: true, now: now + 40).isEmpty,
          "Threshold jitter within one window must not re-alert")
    check(reloaded.observe([tool(quota: quota(10))], threshold: 20, recovery: true, now: now + 50).isEmpty,
          "Recovery within one window must not re-alert")
    check(reloaded.observe([tool(quota: quota(90, reset: Int(now + 2_000)))], threshold: 20, recovery: true,
                            now: now + 60).count == 1, "New window allows a new low alert")
}

do {
    let monitor = QuotaMonitor(directory: directory.appendingPathComponent("stale"))
    check(monitor.observe([tool(quota: quota(99, timestamp: Int(now - 700)))], threshold: 20, recovery: true,
                          now: now).isEmpty, "Stale quota must not alarm")
    check(monitor.observe([tool(quota: quota(99, reset: Int(now - 1)))], threshold: 20, recovery: true,
                          now: now).isEmpty, "Expired window must wait for fresh quota")
    check(monitor.observe([tool(quota: quota(120))], threshold: 20, recovery: true,
                          now: now).isEmpty, "Invalid quota percentage must not alarm")
}

let preferences = try JSONDecoder().decode(ExperiencePreferences.self, from: Data(#"{"quotaAlerts":true}"#.utf8))
check(preferences.quotaAlerts && !preferences.eventExport && preferences.quotaThreshold == 20,
      "New preferences must decode old partial settings with safe defaults")
print("PASS: \(checks) experience checks for explicit/inferred events, history, restart, review, privacy permissions and quota alerts")
