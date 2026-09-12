import Cocoa
import SwiftUI

@MainActor
func renderExperience() throws {
    setbuf(stdout, nil)
    _ = NSApplication.shared
    let codexID = "01234567-89ab-4cde-8fab-0123456789ab"
    assert(NotificationRouter.conversationURL(forToolKey: "codex-ide", sessionId: codexID)?.absoluteString
           == "codex://threads/\(codexID)")
    assert(NotificationRouter.conversationURL(forToolKey: "codex-ide", sessionId: codexID.uppercased())?.absoluteString
           == "codex://threads/\(codexID)")
    for invalid in [nil, "", "new", "../../settings", codexID + "?prompt=hello"] as [String?] {
        assert(NotificationRouter.conversationURL(forToolKey: "codex-ide", sessionId: invalid) == nil)
    }
    for key in ["codex-cli", "claude", "kimi"] {
        assert(NotificationRouter.conversationURL(forToolKey: key, sessionId: codexID) == nil)
    }
    print("PASS: Codex conversation links validate IDs and preserve CLI host routing")
    // Process names and interpreter wrappers must route to the same host without
    // treating task text or a desktop app's internal server as a separate CLI.
    let routes: [(String, String, [String], Bool)] = [
        ("/opt/bin/kimi-code", "kimi", [], true),
        ("/opt/bin/python3.13 /opt/bin/kimi-code", "kimi", [], true),
        ("MODE=local /opt/bin/kimi", "kimi", [], true),
        ("/opt/bin/node /opt/bin/codex", "codex", [], true),
        ("/opt/bin/claude", "claude", [], true),
        ("/opt/bin/python3 -m hermes_cli.main", "hermes", [], true),
        ("/opt/bin/python3 /opt/bin/hermes", "hermes", [], true),
        ("/opt/bin/zcode-cli", "zcode-cli", [], true),
        ("/Applications/Codex.app/Contents/Resources/codex app-server", "codex", ["Codex.app/", "app-server"], false),
        ("/usr/bin/rg hermes_cli", "hermes", [], false),
        ("/opt/bin/python3 /tmp/report.py kimi-code", "kimi", [], false),
        ("/opt/bin/node /tmp/task.js codex", "codex", [], false)
    ]
    for (args, name, excluding, expected) in routes {
        assert(NotificationRouter.matches(args, name: name, excluding: excluding) == expected,
               "Incorrect host routing for \(args)")
    }
    print("PASS: 12 CLI host routing fixtures, including Kimi runtime aliases and false matches")
    let output = URL(fileURLWithPath: CommandLine.arguments[1])
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
    let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: temporary) }
    try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
    // Simulate an unresponsive child without touching Keychain or any real account.
    let stuck = Process()
    stuck.executableURL = URL(fileURLWithPath: "/bin/sh")
    stuck.arguments = ["-c", "trap '' TERM; printf ready; exec /bin/sleep 30"]
    let ready = Pipe()
    stuck.standardOutput = ready
    try stuck.run()
    assert(!ready.fileHandleForReading.availableData.isEmpty)
    let waitStarted = Date()
    let deadline = CollectorProcessWatchdog.schedule(stuck, after: 0.1)
    stuck.waitUntilExit()
    deadline.cancel()
    assert(Date().timeIntervalSince(waitStarted) < 4 && stuck.terminationReason == .uncaughtSignal,
           "A child ignoring SIGTERM must still be stopped within the deadline")
    let deniedCollector = temporary.appendingPathComponent("denied-collector")
    try Data("#!/bin/sh\nprintf 'call\\n' >> \"$0.calls\"\n/bin/sleep 0.2\nexit 1\n".utf8)
        .write(to: deniedCollector)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: deniedCollector.path)
    let authorizationSettings = SettingsStore(path: temporary.appendingPathComponent("auth-settings.json").path,
                                              systemEffects: false)
    let authorizationStore = StatusStore(collectorPath: deniedCollector.path, settings: authorizationSettings,
                                        storageDirectory: temporary.appendingPathComponent("auth"))
    authorizationStore.authorizeKimiCredentials()
    authorizationStore.authorizeKimiCredentials()
    let authDeadline = Date().addingTimeInterval(3)
    while authorizationStore.isAuthorizingKimi && Date() < authDeadline {
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
    }
    assert(!authorizationStore.isAuthorizingKimi && !authorizationSettings.kimiTokenDecrypt)
    let authorizationCalls = try String(contentsOfFile: deniedCollector.path + ".calls")
    assert(authorizationCalls == "call\n",
           "Repeated clicks must launch only one authorization request")
    assert(authorizationStore.kimiAuthorizationMessage?.contains("不会自动重试") == true)
    authorizationStore.authorizeKimiCredentials()
    authorizationStore.cancelKimiAuthorization()
    let cancelDeadline = Date().addingTimeInterval(3)
    while authorizationStore.isAuthorizingKimi && Date() < cancelDeadline {
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
    }
    assert(!authorizationStore.isAuthorizingKimi && !authorizationSettings.kimiTokenDecrypt)
    assert(authorizationStore.kimiAuthorizationMessage?.contains("已取消") == true)
    print("PASS: collector timeout, duplicate authorization prevention, denial and cancellation")
    let watchedHome = temporary.appendingPathComponent("source-watcher")
    let watchedDirectory = watchedHome.appendingPathComponent(".codex/sessions")
    try FileManager.default.createDirectory(at: watchedDirectory, withIntermediateDirectories: true)
    var sourceChanges = 0
    var watcher: SourceChangeMonitor? = SourceChangeMonitor(home: watchedHome.path) { sourceChanges += 1 }
    assert(watcher != nil)
    RunLoop.current.run(until: Date().addingTimeInterval(0.2))
    try Data("task_started".utf8).write(to: watchedDirectory.appendingPathComponent("test.jsonl"), options: .atomic)
    let sourceDeadline = Date().addingTimeInterval(3)
    while sourceChanges == 0 && Date() < sourceDeadline {
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
    }
    assert(sourceChanges > 0, "A real atomic session write must wake the collector")
    // WAL remains open while appending: the lightweight stat fallback must still fire.
    let walDirectory = watchedHome.appendingPathComponent(".hermes")
    try FileManager.default.createDirectory(at: walDirectory, withIntermediateDirectories: true)
    let wal = walDirectory.appendingPathComponent("state.db-wal")
    try Data().write(to: wal)
    let handle = try FileHandle(forWritingTo: wal)
    RunLoop.current.run(until: Date().addingTimeInterval(0.7))
    let beforeAppend = sourceChanges
    try handle.write(contentsOf: Data("open-descriptor-write".utf8))
    RunLoop.current.run(until: Date().addingTimeInterval(0.8))
    assert(sourceChanges > beforeAppend, "An open WAL write must wake status before the descriptor closes")
    try handle.close()
    watcher = nil
    assert(!SourceChangeMonitor.isStatusSource("/fixture/.codex/logs/telemetry.log"))
    assert(!SourceChangeMonitor.isStatusSource("/fixture/.ai-statusbar/collector-cache.json"))
    print("PASS: native filesystem events detect atomic session writes without collector feedback loops")
    let settings = SettingsStore(path: temporary.appendingPathComponent("settings.json").path, systemEffects: false)
    let store = StatusStore(collectorPath: nil, settings: settings, storageDirectory: temporary)
    let catalog = PetCatalog(userPetsDirectory: temporary.appendingPathComponent("Pets"))
    let now = Date().timeIntervalSince1970
    let json = """
    {"updated_at":"21:30:00","tools":[
      {"key":"codex-ide","letter":"C","name":"Codex App","state":"busy","busy_count":7,
       "busy_items":[{"id":"s1","title":"验证新版本的任务提醒与多窗口交互"}],
       "active_items":[{"id":"s1","title":"验证新版本的任务提醒与多窗口交互"},{"id":"s2","title":"编写跨设备用量统计报告"},{"id":"s3","title":"检查素材导出"},{"id":"s4","title":"整理待处理任务"},{"id":"s5","title":"测试演示模式"},{"id":"s6","title":"回归连接诊断"},{"id":"s7","title":"核对模型用量"}],"detail":"7 个任务",
       "health":{"state":"ready","message":"本地状态读取正常","checked_at":\(now),"source_updated_at":\(now),"quota_state":"ready"},
       "capabilities":{"event_phases":["ended","interrupted","waiting_input"],"usage":true,"quota":true,"navigation":"application"},
       "quota":{"windows":[{"kind":"primary","label":"五小时","used_percent":85,"resets_at":\(Int(now+3000))}],"updated_at":\(Int(now))}},
      {"key":"claude","letter":"L","name":"Claude Code","state":"idle","busy_count":0,"busy_items":[],"detail":"1 个进程",
       "health":{"state":"ready","message":"本地状态读取正常","checked_at":\(now),"quota_state":"unsupported"},
       "capabilities":{"event_phases":["ended"],"usage":true,"quota":false,"navigation":"host"}}
    ],"usage":{"date":"2026-09-11","tools":{"codex":{"input":125000,"output":31000,"cache":480000}},"models":{"sample-model":{"input":125000,"output":31000,"cache":480000}},"total":{"input":125000,"output":31000,"cache":480000}}}
    """
    let decoder = JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase
    store.data = try decoder.decode(StatusData.self, from: Data(json.utf8))
    store.lastCollectedAt = now
    store.recentEvents = [
        TaskRecord(id: "wait", toolKey: "codex-ide", toolName: "Codex App", sessionId: "wait-session", title: "选择本次导出的报告范围", phase: "waiting_input", timestamp: now - 20, evidence: "explicit", acknowledged: false, resolved: false),
        TaskRecord(id: "end", toolKey: "claude", toolName: "Claude Code", sessionId: "end-session", title: "检查新版本的连接诊断", phase: "ended", timestamp: now - 90, evidence: "explicit", acknowledged: false, resolved: false),
        TaskRecord(id: "abort", toolKey: "codex-ide", toolName: "Codex App", sessionId: "abort-session", title: "本地事件接口测试", phase: "interrupted", timestamp: now - 180, evidence: "explicit", acknowledged: false, resolved: false)
    ]
    @discardableResult
    func save<V: View>(_ name: String, content: V, scheme: ColorScheme) throws -> CGSize {
        let hosted = NSHostingView(rootView: content.environment(\.colorScheme, scheme))
        var size = hosted.fittingSize
        let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: size.width, height: size.height),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosted
        window.orderFront(nil)
        hosted.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.12))
        // Scroll content reports its natural height after the first layout pass.
        size = hosted.fittingSize
        window.setContentSize(size)
        hosted.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.12))
        guard let bitmap = hosted.bitmapImageRepForCachingDisplay(in: hosted.bounds) else {
            fatalError("Unable to render \(name)")
        }
        hosted.cacheDisplay(in: hosted.bounds, to: bitmap)
        window.orderOut(nil)
        window.close()
        guard let data = bitmap.representation(using: .png, properties: [:]) else { fatalError("PNG failed") }
        try data.write(to: output.appendingPathComponent(name + ".png"))
        print("SNAPSHOT: \(name) · \(Int(size.width)) × \(Int(size.height)) pt")
        return size
    }
    // A fresh collector snapshot must not make an old quota appear current.
    let staleStore = StatusStore(collectorPath: nil, settings: settings, storageDirectory: temporary.appendingPathComponent("stale"))
    staleStore.data = try decoder.decode(StatusData.self, from: Data(json.replacingOccurrences(
        of: "\"updated_at\":\(Int(now))", with: "\"updated_at\":\(Int(now - 7200))").utf8))
    staleStore.lastCollectedAt = now
    let staleSuite = "io.github.stubsx.lingmou.visual.\(UUID().uuidString)"
    let staleDefaults = UserDefaults(suiteName: staleSuite)!
    staleDefaults.set("quota", forKey: "panelTab")
    try save("quota-stale", content: PanelView(store: staleStore).defaultAppStorage(staleDefaults).background(Color.white), scheme: .light)
    staleDefaults.removePersistentDomain(forName: staleSuite)
    // Exercise the real store pipeline with isolated preferences and a captured notification sink.
    let pipelineDir = temporary.appendingPathComponent("pipeline")
    let pipelineSettings = SettingsStore(path: pipelineDir.appendingPathComponent("settings.json").path, systemEffects: false)
    pipelineSettings.notifyEnabled = true
    pipelineSettings.experience.eventExport = true
    pipelineSettings.experience.eventExportTitles = true
    var delivered: [(String, String, [String: Any])] = []
    let pipeline = StatusStore(collectorPath: nil, settings: pipelineSettings, storageDirectory: pipelineDir,
                              notificationSink: { delivered.append(($0, $1, $2)) })
    func snapshot(_ phases: [(String, String)], at timestamp: TimeInterval) -> StatusData {
        var tool = ToolStatus(key: "codex-ide", letter: "C", name: "Codex App", state: "idle", busyCount: 0,
                              busyItems: [], detail: "", latestTitle: nil, latestAge: nil, quota: nil)
        tool.activities = phases.map {
            TaskActivity(id: "\($0.0):\($0.1):\(timestamp)", sessionId: $0.0, title: "保密测试任务",
                         phase: $0.1, updatedAt: timestamp)
        }
        tool.capabilities = ToolCapabilities(eventPhases: ["ended", "interrupted", "waiting_input"])
        return StatusData(updatedAt: "", tools: [tool], usage: nil, usageMerged: nil, sync: nil)
    }
    pipeline.accept(snapshot([], at: now), now: now)
    pipeline.accept(snapshot([("one", "ended"), ("two", "ended")], at: now + 1), now: now + 1)
    assert(delivered.isEmpty, "Merge must delay notification delivery")
    assert(pipeline.completedEventSerial == 1, "Explicit endings celebrate once per batch")
    let titled = try LocalEventFeed.read(directory: pipelineDir)
    assert(titled.events.count == 2 && titled.events[0].title != nil)
    pipelineSettings.experience.privacyMode = true
    assert(try! LocalEventFeed.read(directory: pipelineDir).events.allSatisfy { $0.title == nil })
    RunLoop.current.run(until: Date().addingTimeInterval(4.2))
    assert(delivered.count == 1 && delivered[0].0.contains("2"), "One notification for a batch")
    assert(!delivered[0].1.contains("保密测试任务") && delivered[0].2["tool"] == nil)
    pipeline.accept(snapshot([("three", "waiting_input")], at: now + 2), now: now + 2)
    assert(delivered.count == 2, "Waiting input must notify immediately")
    assert(delivered[1].2["session_id"] as? String == "three", "Single notifications retain the exact conversation")
    pipeline.clearHistory()
    assert(pipeline.attentionEvents.count == 1 && pipeline.attentionEvents[0].waiting)
    pipelineSettings.experience.muteUntil = now + 1000
    pipeline.accept(snapshot([("four", "interrupted")], at: now + 3), now: now + 3)
    assert(delivered.count == 2 && pipeline.recentEvents.contains { $0.phase == "interrupted" })
    assert(pipeline.completedEventSerial == 1, "Interruption cannot celebrate")
    pipelineSettings.experience.muteUntil = 0
    pipeline.accept(snapshot([("five", "ended")], at: now + 4), now: now + 4)
    pipelineSettings.notifyEnabled = false
    pipelineSettings.experience.eventExport = false
    assert(try! !LocalEventFeed.read(directory: pipelineDir).enabled)
    RunLoop.current.run(until: Date().addingTimeInterval(4.2))
    assert(delivered.count == 2, "Disabling must cancel queued notification delivery")
    let restarted = StatusStore(collectorPath: nil, settings: pipelineSettings, storageDirectory: pipelineDir,
                               notificationSink: { delivered.append(($0, $1, $2)) })
    restarted.accept(snapshot([("five", "ended")], at: now + 4), now: now + 5)
    assert(delivered.count == 2 && restarted.recentEvents.count == pipeline.recentEvents.count)
    assert(pipeline.displayTitle("保密测试任务") == "任务标题已隐藏")
    print("PASS: 14 store pipeline assertions for batching, immediate wait, privacy redaction, mute, disable, restart and export policy")
    // Exercise the shared event-opening action without opening the user's tools.
    let reviewDir = temporary.appendingPathComponent("review")
    let reviewSettings = SettingsStore(path: reviewDir.appendingPathComponent("settings.json").path, systemEffects: false)
    reviewSettings.notifyEnabled = true
    var openedTools: [String] = []
    var openedSessions: [String?] = []
    var reviewNotifications: [[String: Any]] = []
    let reviewStore = StatusStore(collectorPath: nil, settings: reviewSettings, storageDirectory: reviewDir,
                                  notificationSink: { reviewNotifications.append($2) },
                                  eventOpener: { openedTools.append($0.toolKey); openedSessions.append($0.sessionId) })
    reviewStore.accept(snapshot([], at: now), now: now)
    let reviewSnapshot = snapshot([("review-end", "ended"), ("review-wait", "waiting_input"),
                                   ("review-abort", "interrupted")], at: now + 1)
    reviewStore.accept(reviewSnapshot, now: now + 1)
    let waitingRecord = reviewStore.attentionEvents.first!
    let endedRecord = reviewStore.recentEvents.first { $0.phase == "ended" }!
    let interruptedRecord = reviewStore.recentEvents.first { $0.phase == "interrupted" }!
    let reviewSuite = "io.github.stubsx.lingmou.visual.\(UUID().uuidString)"
    let reviewDefaults = UserDefaults(suiteName: reviewSuite)!
    defer { reviewDefaults.removePersistentDomain(forName: reviewSuite) }
    reviewDefaults.set("status", forKey: "panelTab")
    try save("event-before-reading", content: PanelView(store: reviewStore).defaultAppStorage(reviewDefaults)
        .background(Color.white), scheme: .light)
    reviewStore.openEvent(waitingRecord)
    assert(reviewStore.attentionEvents.count == 2 && openedTools == ["codex-ide"])
    assert(openedSessions.last! == waitingRecord.sessionId)
    assert(reviewNotifications.first?["session_id"] == nil, "A batch notification must not carry a single session")
    assert(reviewStore.recentEvents.first { $0.id == waitingRecord.id }?.resolved == false)
    reviewStore.openEvent(endedRecord)
    assert(reviewStore.attentionEvents.count == 1 && openedTools.count == 2)
    var historyOpened = 0
    reviewStore.openNotification(["event_ids": [interruptedRecord.id]]) { historyOpened += 1 }
    assert(reviewStore.attentionEvents.isEmpty && historyOpened == 1 && openedTools.count == 2)
    assert(reviewStore.recentEvents.count == 3 && reviewStore.recentEvents.allSatisfy(\.acknowledged))
    try save("event-after-reading", content: PanelView(store: reviewStore).defaultAppStorage(reviewDefaults)
        .background(Color.white), scheme: .light)
    let reviewRestart = StatusStore(collectorPath: nil, settings: reviewSettings, storageDirectory: reviewDir,
                                   notificationSink: { reviewNotifications.append($2) }, eventOpener: { openedTools.append($0.toolKey) })
    reviewRestart.accept(reviewSnapshot, now: now + 2)
    assert(reviewRestart.attentionEvents.isEmpty && reviewNotifications.count == 1, "Read events cannot replay on restart")
    reviewStore.accept(snapshot([("new-one", "ended"), ("new-two", "failed")], at: now + 3), now: now + 3)
    let batchIDs = reviewStore.attentionEvents.map(\.id)
    reviewStore.accept(snapshot([("later", "ended")], at: now + 4), now: now + 4)
    // Quota/legacy notifications have no event IDs and must not clear unrelated events.
    reviewStore.openNotification(["tool": "codex-ide"]) { historyOpened += 1 }
    assert(reviewStore.attentionEvents.count == 3 && openedTools.count == 3)
    assert(openedSessions.last! == nil, "Quota notifications must not select a conversation")
    reviewStore.openNotification(["event_ids": batchIDs]) { historyOpened += 1 }
    assert(reviewStore.attentionEvents.count == 1 && reviewStore.attentionEvents[0].sessionId == "later")
    reviewStore.openNotification(["event_ids": [reviewStore.attentionEvents[0].id], "tool": "codex-ide"]) {
        historyOpened += 1
    }
    assert(reviewStore.attentionEvents.isEmpty && openedTools.count == 4 && historyOpened == 2)
    assert(openedSessions.last! == "later", "Legacy notification must resolve its own event's session")
    reviewStore.openNotification(["event_ids": ["expired-event"], "tool": "codex-ide", "session_id": codexID]) {
        historyOpened += 1
    }
    assert(openedSessions.last! == codexID, "Notification payload keeps routing after journal expiry")
    reviewStore.openNotification(["event_ids": ["one", "two"], "tool": "codex-ide", "session_id": codexID]) {
        historyOpened += 1
    }
    assert(openedSessions.last! == nil, "A batch must not choose one arbitrary conversation")
    RunLoop.current.run(until: Date().addingTimeInterval(4.2))
    assert(reviewNotifications.count == 1, "Read events must be removed from queued notification batches")
    print("PASS: shared event-open action, scoped notification reads, waiting semantics, persistence and queued-reminder cancellation")
    for (name, tab, scheme) in [
        ("tasks-compact-light", "status", ColorScheme.light),
        ("status-attention-dark", "status", ColorScheme.dark),
        ("tasks-expanded-dark", "details", ColorScheme.dark),
        ("history-light", "history", ColorScheme.light),
        ("usage-light", "usage", ColorScheme.light),
        ("quota-dark", "quota", ColorScheme.dark)
    ] {
        let suite = "io.github.stubsx.lingmou.visual.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(tab, forKey: "panelTab")
        // An old saved expanded preference must not turn the new default into a dashboard.
        defaults.set(true, forKey: "panelExpanded")
        let size = try save(name, content: PanelView(store: store).defaultAppStorage(defaults)
            .background(scheme == .light ? Color.white : Color(red: 0.09, green: 0.11, blue: 0.16)), scheme: scheme)
        if tab == "status" { assert(size.width == 300 && size.height < 300) }
    }
    let overviewStore = StatusStore(collectorPath: nil, settings: settings,
                                   storageDirectory: temporary.appendingPathComponent("overview"))
    let overviewSuite = "io.github.stubsx.lingmou.visual.\(UUID().uuidString)"
    let overviewDefaults = UserDefaults(suiteName: overviewSuite)!
    defer { overviewDefaults.removePersistentDomain(forName: overviewSuite) }
    overviewDefaults.set("status", forKey: "panelTab")
    for scenario in ["quiet", "idle", "busy", "many-tools", "many-tools-quiet", "error", "private"] {
        var overviewTools = store.data!.tools
        if scenario == "quiet" { overviewTools = [] }
        if scenario == "idle" { overviewTools = Array(store.data!.tools.suffix(1)) }
        overviewStore.recentEvents = []
        overviewStore.collectorError = nil
        if ["many-tools", "many-tools-quiet", "error", "private"].contains(scenario) {
            overviewTools = (1...8).map { index in
                var tool = ToolStatus(key: "fixture-\(index)", letter: "A", name: "AI 工具 \(index)", state: "busy",
                                      busyCount: 30, busyItems: [], detail: "", latestTitle: nil, latestAge: nil, quota: nil)
                tool.activeItems = (1...30).map { BusyItem(id: "task-\($0)", title: "核对多工具并行时的状态与报告输出") }
                return tool
            }
            if scenario != "many-tools-quiet" { overviewStore.recentEvents = store.recentEvents }
        }
        overviewStore.data = StatusData(updatedAt: "", tools: overviewTools, usage: nil, usageMerged: nil, sync: nil)
        if scenario == "error" { overviewStore.collectorError = "采集器暂时无法读取本地状态" }
        settings.experience.privacyMode = scenario == "private"
        overviewStore.lastCollectedAt = scenario == "error" ? now - 100 : now
        let size = try save("status-" + scenario, content: PanelView(store: overviewStore)
            .defaultAppStorage(overviewDefaults).background(Color.white), scheme: .light)
        assert(size.width == 300 && size.height <= 340, "Summary must stay small, even with 240 active tasks")
    }
    settings.experience.privacyMode = false
    for tab in ["general", "connections", "notify", "data", "welcome"] {
        let suite = "io.github.stubsx.lingmou.visual.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(tab, forKey: "settingsTab")
        try save("settings-" + tab, content: SettingsView(store: store, settings: settings, catalog: catalog)
            .defaultAppStorage(defaults).frame(height: 740).background(Color.white), scheme: .light)
    }
    settings.experience.privacyMode = true
    try save("privacy-light", content: TaskEventRows(store: store, events: store.recentEvents, expanded: true)
        .padding(20).frame(width: 470).background(Color.white), scheme: .light)
    try save("ball-attention", content: FloatingBallView(store: store, onToggle: {}).frame(width: 100, height: 100)
        .background(Color.white), scheme: .light)
    try save("pet-gallery", content: PetGalleryView(settings: settings, catalog: catalog).background(Color.white), scheme: .light)
    let keyboardPanel = TaskPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    keyboardPanel.isReleasedWhenClosed = false
    keyboardPanel.navigationDefaults = overviewDefaults
    assert(keyboardPanel.canBecomeKey, "Status panel must support keyboard focus")
    let keyboardHost = NSHostingView(rootView: PanelView(store: store).defaultAppStorage(overviewDefaults))
    keyboardPanel.contentView = keyboardHost
    keyboardPanel.setFrame(NSRect(x: -10000, y: -10000, width: 300, height: 300), display: false)
    keyboardPanel.makeKeyAndOrderFront(nil)
    RunLoop.current.run(until: Date().addingTimeInterval(0.1))
    for (character, code, expected) in [("2", UInt16(19), "usage"), ("3", 20, "heat"), ("4", 21, "quota"), ("5", 23, "history"),
                                        ("1", 18, "status"), ("e", 14, "details"), ("e", 14, "status")] {
        let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0,
                                    windowNumber: keyboardPanel.windowNumber, context: nil, characters: character,
                                    charactersIgnoringModifiers: character, isARepeat: false, keyCode: code)!
        let handled = keyboardPanel.performKeyEquivalent(with: event)
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        assert(handled && overviewDefaults.string(forKey: "panelTab") == expected, "Panel shortcut ⌘\(character) must open \(expected)")
        let expectedWidth: CGFloat = expected == "status" ? 300 : (expected == "details" ? 380 : 340)
        assert(keyboardHost.fittingSize.width == expectedWidth && keyboardHost.fittingSize.height <= 420,
               "Keyboard navigation must also update the fitted panel size")
    }
    overviewDefaults.set("details", forKey: "panelTab")
    let escape = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                 windowNumber: keyboardPanel.windowNumber, context: nil, characters: "\u{1b}",
                                 charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53)!
    assert(keyboardPanel.performKeyEquivalent(with: escape) && overviewDefaults.string(forKey: "panelTab") == "status")
    keyboardPanel.close()
    print("PASS: 8 native panel keyboard shortcuts and fitted sizing after navigation")
    print("PASS: rendered 24 isolated native experience snapshots, event reading, bounded summaries, light/dark, task details, privacy, settings and attention badge")
}
if #available(macOS 13, *) { try MainActor.assumeIsolated { try renderExperience() } }
