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
    // 小时级窗口的分级保鲜期为 1 小时，4_000 秒前的读取才判过期
    check(monitor.observe([tool(quota: quota(99, timestamp: Int(now - 4_000)))], threshold: 20, recovery: true,
                          now: now).isEmpty, "Stale quota must not alarm")
    check(monitor.observe([tool(quota: quota(99, reset: Int(now - 1)))], threshold: 20, recovery: true,
                          now: now).isEmpty, "Expired window must wait for fresh quota")
    check(monitor.observe([tool(quota: quota(120))], threshold: 20, recovery: true,
                          now: now).isEmpty, "Invalid quota percentage must not alarm")
}

do {
    func record(_ id: String, session: String = "session", key: String = "codex-ide",
                phase: String = "ended", at time: TimeInterval = now, resolved: Bool = false,
                read: Bool = false) -> TaskRecord {
        TaskRecord(id: id, toolKey: key, toolName: key, sessionId: session, title: id,
                   phase: phase, timestamp: time, evidence: "explicit", acknowledged: read, resolved: resolved)
    }
    let history = [record("old", at: now - 20), record("new", at: now - 10),
                   record("other", session: "second"), record("kimi", key: "kimi")]
    let groups = HarnessConversations.groups(tools: [tool(busy: true)], events: history)
    let codex = groups.first { $0.id == "codex-ide" }!
    check(codex.conversations.count == 2, "A resumed session must appear once alongside other completed sessions")
    check(codex.conversations[0].phase == "working", "A new running turn supersedes old completion")
    check(Set(codex.conversations[0].eventIDs) == Set(["old", "new"]), "One row retains all its own event IDs")
    check(groups.first { $0.id == "kimi" }?.conversations.count == 1, "The same session ID in another harness is separate")
    check(groups.first { $0.id == "kimi" }?.tool.state == "off", "An unread result remains available after its harness exits")
    check(codex.runningCount == 1 && codex.attentionCount == 1, "Counts match running and unread rows, not historical turns")
    let ended = HarnessConversations.conversations(tool: tool(), events: history)
    check(ended.first { $0.sessionId == "session" }?.title == "new", "Use the latest title and outcome per conversation")
    check(ended.filter { $0.sessionId == "session" }.count == 1, "Multiple completed turns collapse into one row")
    let states = HarnessConversations.conversations(tool: tool(), events: [
        record("quiet", phase: "inactive"),
        record("resolved", session: "resolved", phase: "waiting_input", resolved: true),
        record("waiting", session: "waiting", phase: "waiting_input"),
        record("abort", session: "abort", phase: "interrupted")
    ])
    check(states.first?.sessionId == "waiting", "An unresolved wait stays before past results")
    check(states.allSatisfy { !["resolved", "session"].contains($0.sessionId ?? "") },
          "Resolved waits and inactivity must not appear in the live status list")
    check(states.allSatisfy { $0.phase != "ended" }, "Inactivity and interruptions are never presented as completed")
    var many = tool(busy: true)
    many.activeItems = (1...8).map { BusyItem(id: "running-\($0)", title: "运行会话 \($0)") }
    let preview = HarnessConversations.groups(tools: [many], events: history)[0].preview
    check(preview.filter(\.current).count == 3 && preview.contains { $0.phase == "ended" },
          "Busy harnesses must still preview recent completed conversations")
    let anonymous = HarnessConversations.conversations(tool: tool(), events: [
        record("anonymous-1", session: ""), record("anonymous-2", session: "")
    ])
    check(anonymous.count == 2 && anonymous.allSatisfy { $0.sessionId == nil }, "Missing IDs cannot merge unrelated history")
    let readRows = HarnessConversations.conversations(tool: tool(), events: [
        record("old-unread", at: now - 20), record("latest-read", read: true),
        record("read-wait", session: "wait", phase: "waiting_input", read: true),
        record("resolved-end", session: "resolved-end", resolved: true)
    ])
    check(readRows.isEmpty, "Reading the latest result hides the conversation without resurrecting older unread turns")
    let historical = ToolStatus(key: "kimi", letter: "K", name: "Kimi", state: "idle", busyCount: 0,
                                busyItems: [], detail: "", latestTitle: "很早之前的对话", latestAge: "3 天前", quota: nil)
    check(HarnessConversations.conversations(tool: historical, events: []).isEmpty,
          "Latest-title fallback must not add old conversations to live status")
    check(HarnessConversations.groups(tools: [], events: [record("old-tool", read: true)]).isEmpty,
          "Read history cannot resurrect an offline harness")
    many.activeItems = [BusyItem(id: "same", title: "First"), BusyItem(id: "same", title: "Duplicate")]
    check(HarnessConversations.workingItems(for: many).count == 1,
          "Running icons and rows must share the same deduplicated session list")
}

do {
    let window = QuotaWindow(kind: "month", label: "本月", usedPercent: 5, resetsAt: Int(now + 86_400),
                             windowMinutes: 43_200, components: nil)
    func reading(age: TimeInterval = 0, notice: String? = nil, windows: [QuotaWindow]? = nil) -> ToolQuota {
        ToolQuota(plan: "Allegro", windows: windows ?? [window], updatedAt: Int(now - age), notice: notice)
    }
    // 读取失败但窗口未重置的历史快照：展示为降饱和快照，而不是清空
    let unavailable = QuotaPresentation(tool: tool(key: "kimi-work", quota: reading(age: 172_800,
        notice: "凭证读取尚未开启")), now: now)
    check(!unavailable.isCurrent && unavailable.isStale && !unavailable.windows.isEmpty,
          "A failed refresh keeps its unexpired snapshot as a dimmed stale reading")
    check(unavailable.lastSuccessAt == now - 172_800, "Keep the actual successful read time when refresh fails")
    let failedAttempt = QuotaPresentation(tool: tool(quota: reading(notice: "需要登录", windows: [])), now: now)
    check(!failedAttempt.isCurrent && failedAttempt.lastSuccessAt == nil, "A failed attempt is not a successful update")
    check(!QuotaPresentation(tool: tool(quota: reading(notice: "无法更新")), now: now).isCurrent,
          "A recent timestamp cannot override an explicit read failure")
    check(!QuotaPresentation(tool: tool(quota: reading(age: 86_500)), now: now).isCurrent,
          "Monthly readings must expire after their tiered horizon")
    check(QuotaPresentation(tool: tool(key: "kimi-work", quota: reading(age: 3_600)), now: now).isCurrent,
          "Monthly snapshots stay current for a full day")
    check(QuotaPresentation(tool: tool(key: "kimi-work", quota: reading(age: 4_201)), now: now).isCurrent,
          "The kimi-work cache exception is replaced by the tiered horizon")
    var staleTool = tool(quota: reading())
    staleTool.health = ToolHealth(state: "ready", message: "", checkedAt: now, quotaState: "stale")
    check(QuotaPresentation(tool: staleTool, now: now).isCurrent,
          "Within the tiered horizon a collector stale flag no longer suppresses numbers")
    check(!QuotaPresentation(tool: tool(quota: reading(age: -120)), now: now).isCurrent,
          "A future timestamp cannot make a quota current")
    let expired = QuotaWindow(kind: "primary", label: "五小时", usedPercent: 50, resetsAt: Int(now - 1),
                              windowMinutes: 300, components: nil)
    check(QuotaPresentation(tool: tool(quota: reading(windows: [expired, window])), now: now).windows.count == 1,
          "Do not show old percentages from windows that have already reset")
    let codeWindow = QuotaWindow(kind: "5h", label: "5小时", usedPercent: 95, resetsAt: Int(now + 300),
                                 windowMinutes: 300, components: nil)
    let cachedCode = tool(key: "kimi", quota: reading(age: 3_601, windows: [codeWindow]))
    let codeSnapshot = QuotaPresentation(tool: cachedCode, now: now)
    check(!codeSnapshot.isCurrent && codeSnapshot.isStale && !codeSnapshot.windows.isEmpty,
          "An hourly snapshot past its horizon lingers dimmed until the window resets")
    check(codeSnapshot.lastSuccessAt == now - 3_601, "Expired quota keeps its real update time")
    let expiredCode = QuotaPresentation(tool: tool(key: "kimi", quota: reading(windows: [expired])), now: now)
    check(!expiredCode.isCurrent && expiredCode.windows.isEmpty,
          "A reset Kimi window cannot claim current quota")
    check(QuotaPresentation(tool: tool(key: "kimi", quota: reading(windows: [codeWindow])), now: now).isCurrent,
          "A fresh Kimi reading shows as current quota")
    check(QuotaPresentation(tool: tool(key: "kimi", quota: reading(windows: [])), now: now).windows.isEmpty,
          "An empty response cannot fabricate a quota reading")
    check(!QuotaPresentation(tool: tool(key: "kimi", quota: reading(age: -120)), now: now).isCurrent,
          "Quota display cannot accept invalid future timestamps")
    let codeMonitor = QuotaMonitor(directory: directory.appendingPathComponent("code-snapshots"))
    check(codeMonitor.observe([cachedCode], threshold: 20, recovery: true, now: now).isEmpty,
          "Expired Kimi quota must never trigger a quota alert")
}

let preferences = try JSONDecoder().decode(ExperiencePreferences.self, from: Data(#"{"quotaAlerts":true}"#.utf8))
check(preferences.quotaAlerts && !preferences.eventExport && preferences.quotaThreshold == 20,
      "New preferences must decode old partial settings with safe defaults")
print("PASS: \(checks) experience checks for explicit/inferred events, history, restart, review, privacy permissions and quota alerts")
