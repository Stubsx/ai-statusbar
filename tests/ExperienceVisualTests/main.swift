import Cocoa
import SwiftUI

// Native wheel input scoped to a test window; a bare CGEvent has no target window.
private final class FixtureWheelEvent: NSEvent {
    weak var targetWindow: NSWindow?
    var targetNumber = 0
    var point = NSPoint.zero
    var source: NSEvent!
    override var type: NSEvent.EventType { .scrollWheel }
    override var window: NSWindow? { targetWindow }
    override var windowNumber: Int { targetNumber }
    override var locationInWindow: NSPoint { point }
    override var deltaX: CGFloat { source.deltaX }
    override var deltaY: CGFloat { source.deltaY }
    override var deltaZ: CGFloat { source.deltaZ }
    override var scrollingDeltaX: CGFloat { source.scrollingDeltaX }
    override var scrollingDeltaY: CGFloat { source.scrollingDeltaY }
    override var hasPreciseScrollingDeltas: Bool { source.hasPreciseScrollingDeltas }
    override var phase: NSEvent.Phase { source.phase }
    override var momentumPhase: NSEvent.Phase { source.momentumPhase }
    override var modifierFlags: NSEvent.ModifierFlags { [] }
    override var timestamp: TimeInterval { ProcessInfo.processInfo.systemUptime }
    override var cgEvent: CGEvent? { source.cgEvent }
}

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
    assert(NotificationRouter.supportsSessionNavigation(forToolKey: "codex-ide", sessionId: codexID))
    assert(!NotificationRouter.supportsSessionNavigation(forToolKey: "codex-ide", sessionId: "invalid"))
    assert(NotificationRouter.supportsSessionNavigation(forToolKey: "kimi", sessionId: "web-session", kimiWebAvailable: true))
    assert(!NotificationRouter.supportsSessionNavigation(forToolKey: "kimi", sessionId: "web-session"))
    assert(!NotificationRouter.supportsSessionNavigation(forToolKey: "kimi", sessionId: "../bad", kimiWebAvailable: true))
    for key in ["kimi-work", "claude", "codex-cli", "hermes", "zcode", "dsh", "unknown"] {
        assert(!NotificationRouter.supportsSessionNavigation(forToolKey: key, sessionId: codexID, kimiWebAvailable: true))
    }
    assert(!NotificationRouter.supportsApplicationNavigation(forToolKey: "unknown"))
    print("PASS: Codex conversation links validate IDs and preserve CLI host routing")
    let chrome = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
    assert(NotificationRouter.defaultChromiumProfilePID([(11, chrome), (22, chrome + " --headless --user-data-dir=/tmp/fixture")]) == 11)
    assert(NotificationRouter.defaultChromiumProfilePID([(11, chrome), (22, chrome + " --headless=new")]) == 11)
    assert(NotificationRouter.defaultChromiumProfilePID([(11, chrome)]) == nil)
    assert(NotificationRouter.defaultChromiumProfilePID([(11, chrome + " --user-data-dir=/tmp/custom"), (22, chrome + " --headless")]) == nil)
    assert(NotificationRouter.defaultChromiumProfilePID([(11, chrome), (12, chrome), (22, chrome + " --headless")]) == nil)
    print("PASS: browser routing avoids headless Chromium without guessing custom profiles")
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
    // A source event just before the old periodic tick must reset the fallback,
    // while the fallback must still scan later in the absence of further writes.
    let schedulingDirectory = temporary.appendingPathComponent("scheduling")
    let schedulingSessions = schedulingDirectory.appendingPathComponent(".codex/sessions")
    try FileManager.default.createDirectory(at: schedulingSessions, withIntermediateDirectories: true)
    let fakeCollector = schedulingDirectory.appendingPathComponent("collector.sh")
    try """
    #!/bin/sh
    [ "$1" = "--metrics-only" ] && exit 0
    cd "$(dirname "$0")"
    echo scan >> calls
    echo '{"updated_at":"test","tools":[]}'
    """.write(to: fakeCollector, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fakeCollector.path)
    var schedulingStore: StatusStore? = StatusStore(collectorPath: fakeCollector.path, settings: settings,
                                                    storageDirectory: schedulingDirectory.appendingPathComponent("history"))
    let schedulingStart = Date()
    schedulingStore?.start(home: schedulingDirectory.path)
    RunLoop.current.run(until: schedulingStart.addingTimeInterval(4.2))
    func scanCount() -> Int {
        ((try? String(contentsOf: schedulingDirectory.appendingPathComponent("calls"))) ?? "")
            .split(separator: "\n").count
    }
    let beforeSourceScan = scanCount()
    assert(beforeSourceScan >= 1)
    try Data("changed".utf8).write(to: schedulingSessions.appendingPathComponent("test.jsonl"))
    RunLoop.current.run(until: schedulingStart.addingTimeInterval(5.8))
    assert(scanCount() == beforeSourceScan + 1, "Source scan must replace the imminent fallback scan")
    let afterSourceScan = scanCount()
    RunLoop.current.run(until: schedulingStart.addingTimeInterval(10.5))
    assert(scanCount() > afterSourceScan, "Reset fallback must still detect process exits without file events")
    schedulingStore = nil
    print("PASS: filesystem refresh resets fallback without redundant scans or losing the next fallback")
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
    let sessionIDs = (1...7).map { "01234567-89ab-4cde-8fab-0123456789a\($0)" }
    let sessionJSON = sessionIDs.enumerated().reduce(json) { value, entry in
        value.replacingOccurrences(of: "\"s\(entry.offset + 1)\"", with: "\"\(entry.element)\"")
    }
    let decoder = JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase
    store.data = try decoder.decode(StatusData.self, from: Data(sessionJSON.utf8))
    store.lastCollectedAt = now
    store.recentEvents = [
        TaskRecord(id: "wait", toolKey: "codex-ide", toolName: "Codex App", sessionId: "wait-session", title: "选择本次导出的报告范围", phase: "waiting_input", timestamp: now - 20, evidence: "explicit", acknowledged: false, resolved: false),
        TaskRecord(id: "end", toolKey: "claude", toolName: "Claude Code", sessionId: "end-session", title: "检查新版本的连接诊断", phase: "ended", timestamp: now - 90, evidence: "explicit", acknowledged: false, resolved: false),
        TaskRecord(id: "abort", toolKey: "codex-ide", toolName: "Codex App", sessionId: "abort-session", title: "本地事件接口测试", phase: "interrupted", timestamp: now - 180, evidence: "explicit", acknowledged: false, resolved: false)
    ]
    store.recentEvents += [
        TaskRecord(id: "older-end", toolKey: "claude", toolName: "Claude Code", sessionId: "end-session", title: "同一对话的上一轮结果", phase: "ended", timestamp: now - 200, evidence: "explicit", acknowledged: false, resolved: false),
        TaskRecord(id: "read-history", toolKey: "codex-ide", toolName: "Codex App", sessionId: "read-session", title: "已查看的历史对话不应出现", phase: "ended", timestamp: now - 60, evidence: "explicit", acknowledged: true, resolved: false),
        TaskRecord(id: "resumed-history", toolKey: "codex-ide", toolName: "Codex App", sessionId: sessionIDs[0], title: "重新运行前的旧结果", phase: "ended", timestamp: now - 60, evidence: "explicit", acknowledged: false, resolved: false)
    ]
    assert(store.attentionEvents.count == 3 && store.harnessGroups.reduce(0, { $0 + $1.attentionCount }) == 3,
           "Badges and rows must count unread conversations, excluding read history and resumed turns")
    assert(store.harnessGroups.reduce(0, { $0 + $1.runningCount }) == 7
           && PetMood.current(data: store.data, error: nil) == .working(taskCount: 7),
           "The running icon must count exactly the sessions shown under each harness")
    assert(!store.harnessGroups.flatMap(\.conversations).contains { $0.sessionId == "read-session" })
    // 紧凑菜单仍要保留全部任务的精确跳转，且子菜单和提示也必须遵守演示模式。
    func menuItems(_ menu: NSMenu) -> [NSMenuItem] {
        menu.items.flatMap { [$0] + ($0.submenu.map(menuItems) ?? []) }
    }
    let menuTarget = NSObject()
    let toolMenu = NSMenu()
    MenuBarPresentation.appendTools(to: toolMenu, tools: store.data!.tools, target: menuTarget,
                                    openTool: Selector(("openTool:")), openConnections: Selector(("openConnections")),
                                    displayTitle: { store.displayTitle($0) })
    let destinations = menuItems(toolMenu).compactMap { $0.representedObject as? HarnessConversation }
    assert(Set(destinations.compactMap(\.sessionId)) == Set(sessionIDs),
           "Overflow must use activeItems, not the one-item busyItems preview")
    assert(destinations.allSatisfy { $0.toolKey == "codex-ide" })
    settings.experience.privacyMode = true
    let privateMenu = NSMenu()
    MenuBarPresentation.appendTools(to: privateMenu, tools: store.data!.tools, target: menuTarget,
                                    openTool: Selector(("openTool:")), openConnections: Selector(("openConnections")),
                                    displayTitle: { store.displayTitle($0) })
    for item in menuItems(privateMenu) where item.representedObject is HarnessConversation {
        assert(item.title.hasPrefix("任务标题已隐藏 · ") && item.toolTip?.hasPrefix("任务标题已隐藏") == true)
    }
    settings.experience.privacyMode = false
    var failedTool = store.data!.tools[1]
    failedTool.health = ToolHealth(state: "error", message: "读取失败", checkedAt: now)
    let failedMenu = NSMenu()
    MenuBarPresentation.appendTools(to: failedMenu, tools: [failedTool], target: menuTarget,
                                    openTool: Selector(("openTool:")), openConnections: Selector(("openConnections")),
                                    displayTitle: { $0 })
    assert(failedMenu.items.contains { $0.action == Selector(("openConnections")) },
           "Failed tools need an actionable diagnosis entry")
    assert(MenuBarPresentation.fittedTitle("一个短标题") == "一个短标题")
    assert(MenuBarPresentation.fittedTitle(String(repeating: "长标题", count: 50)).hasSuffix("…"))
    let integratedMenu = NSMenu()
    let menuDelegate = AppDelegate()
    menuDelegate.populateStatusMenu(integratedMenu, store: store)
    assert(integratedMenu.items.first?.representedObject as? String == "codex-ide")
    assert(!integratedMenu.items.contains { $0.action == Selector(("openTaskCenter")) })
    let desktopMenu = integratedMenu.items.first { $0.title == "桌面显示" }!.submenu!
    assert(desktopMenu.items.contains { $0.action == Selector(("openTaskCenter")) && $0.keyEquivalent == "1" })
    assert(desktopMenu.items.contains { $0.action == Selector(("togglePin")) && $0.keyEquivalent == "t" })
    assert(!integratedMenu.items.contains { $0.action == Selector(("openHistory")) || $0.title.hasPrefix("最近事件") })
    let groupedMenuRows = menuItems(integratedMenu).compactMap { $0.representedObject as? HarnessConversation }
    assert(groupedMenuRows.contains { $0.phase == "working" } && groupedMenuRows.contains { $0.phase == "ended" },
           "Native menu must include current and completed conversations under each harness")
    print("PASS: native menu preserves all seven session routes, redacts overflow titles and routes failures to diagnosis")
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
    // Isolated session fixtures cover both navigation capabilities and privacy.
    var kimiTool = ToolStatus(key: "kimi", letter: "K", name: "Kimi Code / Web", state: "busy",
                              busyCount: 2, busyItems: [], detail: "", latestTitle: nil, latestAge: nil, quota: nil)
    kimiTool.activeItems = [BusyItem(id: "kimi-web-one", title: "检查状态页的会话跳转"),
                           BusyItem(id: "kimi-web-two", title: "整理本周项目进度")]
    let hostTool = ToolStatus(key: "claude", letter: "L", name: "Claude Code", state: "busy",
                              busyCount: 1, busyItems: [BusyItem(id: "host-only", title: "核对构建输出")],
                              detail: "", latestTitle: nil, latestAge: nil, quota: nil)
    let sessionHistory = [
        TaskRecord(id: "codex-done", toolKey: "codex-ide", toolName: "Codex App", sessionId: codexID,
                   title: "合并远程更新并验证发布", phase: "ended", timestamp: now - 90,
                   evidence: "explicit", acknowledged: false, resolved: false),
        TaskRecord(id: "kimi-done", toolKey: "kimi", toolName: "Kimi Code / Web", sessionId: "kimi-finished",
                   title: "导出产品状态与核对结果", phase: "ended", timestamp: now - 120,
                   evidence: "explicit", acknowledged: true, resolved: false)
    ]
    func sessionSections(webAvailable: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(HarnessConversations.groups(tools: [store.data!.tools[0], kimiTool, hostTool],
                                                 events: sessionHistory)) { group in
                StatusToolSection(group: group, kimiWebAvailable: webAvailable,
                                  displayTitle: { settings.experience.privacyMode ? "任务标题已隐藏" : $0 },
                                  openDestination: { print("SESSION_ROUTE: \($0.toolKey) / \($0.sessionId ?? "application")") },
                                  openConversation: { print("SESSION_ROUTE: \($0.toolKey) / \($0.sessionId ?? "application")") })
            }
        }.padding(14).frame(width: PanelView.panelWidth)
    }
    for scheme in [ColorScheme.light, .dark] {
        try save("session-list-" + (scheme == .light ? "light" : "dark"),
                 content: sessionSections(webAvailable: true)
                    .background(scheme == .light ? Color.white : Color(red: 0.09, green: 0.11, blue: 0.16)), scheme: scheme)
    }
    settings.experience.privacyMode = true
    try save("session-list-private", content: sessionSections(webAvailable: true).background(Color.white), scheme: .light)
    settings.experience.privacyMode = false
    try save("session-list-host-only", content: sessionSections(webAvailable: false).background(Color.white), scheme: .light)
    // Optional visible fixture for real pointer/keyboard checks; routes are captured
    // locally so checking a sample row cannot open an unrelated real conversation.
    if CommandLine.arguments.contains("--interactive-sessions") {
        NSApp.setActivationPolicy(.regular)
        let hosted = NSHostingView(rootView: sessionSections(webAvailable: true).background(Color.white))
        let window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: PanelView.panelWidth, height: 500),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "状态会话交互验证"
        window.acceptsMouseMovedEvents = true
        window.isReleasedWhenClosed = false
        window.contentView = hosted
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        NSApp.run()
        window.orderOut(nil)
        window.close()
    }
    if CommandLine.arguments.contains("--interactive-tabs") {
        let suite = "io.github.stubsx.lingmou.tabs.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("status", forKey: "panelTab")
        NSApp.setActivationPolicy(.regular)
        let hosted = NSHostingView(rootView: PanelView(store: store).defaultAppStorage(defaults)
            .background(Color.white)
            .onReceive(NotificationCenter.default.publisher(for: .statusUpdated)) { _ in
                print("PANEL_PAGE: \(defaults.string(forKey: "panelTab") ?? "status")")
            })
        let window = TaskPanel(contentRect: NSRect(x: 200, y: 200, width: PanelView.panelWidth, height: 440),
                               styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.navigationDefaults = defaults
        window.title = "看板横向导航验证"
        window.acceptsMouseMovedEvents = true
        window.isReleasedWhenClosed = false
        window.contentView = hosted
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        NSApp.run()
        window.close()
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
    for scenario in ["cached", "empty", "current"] {
        let current = scenario == "current"
        let monthly = QuotaWindow(kind: "month", label: "本月", usedPercent: 5,
                                  resetsAt: Int(now + 22 * 86_400), windowMinutes: 43_200,
                                  components: [QuotaComponent(key: "kimi", label: "Kimi", usedPercent: 1),
                                               QuotaComponent(key: "code", label: "Code", usedPercent: 4)])
        let quota = ToolQuota(plan: "Allegro", windows: scenario == "empty" ? [] : [monthly],
                              updatedAt: Int(scenario == "cached" ? now - 172_800 : now),
                              notice: current ? nil : "新版 Kimi 已加密本地凭证，月度额度暂不可读（可在设置开启解密）")
        var kimi = ToolStatus(key: "kimi-work", letter: "W", name: "Kimi Work", state: "idle", busyCount: 0,
                              busyItems: [], detail: "", latestTitle: nil, latestAge: nil, quota: quota)
        kimi.health = ToolHealth(state: "ready", message: "", checkedAt: now,
                                 quotaState: current ? "ready" : (scenario == "empty" ? "unavailable" : "stale"))
        staleStore.data = StatusData(updatedAt: "", tools: [kimi], usage: nil, usageMerged: nil, sync: nil)
        try save("quota-kimi-" + scenario, content: PanelView(store: staleStore).defaultAppStorage(staleDefaults)
            .background(Color.white), scheme: .light)
    }
    for scheme in [ColorScheme.light, .dark] {
        let quota = ToolQuota(plan: "Allegro", windows: [
            QuotaWindow(kind: "week", label: "7天", usedPercent: 11, resetsAt: Int(now + 86_400),
                        windowMinutes: 10_080, components: nil),
            QuotaWindow(kind: "5h", label: "5小时", usedPercent: 3, resetsAt: Int(now + 3_600),
                        windowMinutes: 300, components: nil)
        ], updatedAt: Int(now - 900), notice: nil)
        var kimi = ToolStatus(key: "kimi", letter: "K", name: "Kimi Code", state: "idle", busyCount: 0,
                              busyItems: [], detail: "", latestTitle: nil, latestAge: nil, quota: quota)
        kimi.health = ToolHealth(state: "ready", message: "", checkedAt: now, quotaState: "stale")
        staleStore.data = StatusData(updatedAt: "", tools: [kimi], usage: nil, usageMerged: nil, sync: nil)
        try save("quota-kimi-code-history-" + (scheme == .light ? "light" : "dark"),
                 content: PanelView(store: staleStore).defaultAppStorage(staleDefaults)
                    .background(scheme == .light ? Color.white : Color(red: 0.09, green: 0.11, blue: 0.16)), scheme: scheme)
    }
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
    assert(pipeline.completedEventCount == 2, "Symbol bubble must use the actual ending batch size")
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
    let waitingConversation = reviewStore.harnessGroups.flatMap(\.conversations).first { $0.sessionId == waitingRecord.sessionId }!
    reviewStore.openConversation(waitingConversation)
    assert(reviewStore.attentionEvents.count == 2 && openedTools == ["codex-ide"])
    assert(!reviewStore.harnessGroups.flatMap(\.conversations).contains { $0.sessionId == waitingRecord.sessionId },
           "Viewing a waiting reminder removes its row while leaving the original task unchanged")
    assert(openedSessions.last! == waitingRecord.sessionId)
    assert(reviewNotifications.first?["session_id"] == nil, "A batch notification must not carry a single session")
    assert(reviewStore.recentEvents.first { $0.id == waitingRecord.id }?.resolved == false)
    reviewStore.openConversation(reviewStore.harnessGroups.flatMap(\.conversations).first { $0.sessionId == endedRecord.sessionId }!)
    assert(reviewStore.attentionEvents.count == 1 && openedTools.count == 2)
    var historyOpened = 0
    reviewStore.openNotification(["event_ids": [interruptedRecord.id]]) { historyOpened += 1 }
    assert(reviewStore.attentionEvents.count == 1 && historyOpened == 1 && openedTools.count == 2,
           "A notification that opens only the list must keep its result available")
    reviewStore.openConversation(reviewStore.harnessGroups.flatMap(\.conversations).first { $0.sessionId == interruptedRecord.sessionId }!)
    assert(reviewStore.attentionEvents.isEmpty && openedTools.count == 3)
    assert(reviewStore.harnessGroups.flatMap(\.conversations).isEmpty,
           "After reading results the live list is empty, even though the journal is preserved")
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
    assert(reviewStore.attentionEvents.count == 3 && openedTools.count == 4)
    assert(openedSessions.last! == nil, "Quota notifications must not select a conversation")
    reviewStore.openNotification(["event_ids": batchIDs]) { historyOpened += 1 }
    assert(reviewStore.attentionEvents.count == 3, "Batch notification opens the list without hiding unread results")
    for row in reviewStore.harnessGroups.flatMap(\.conversations) where row.eventIDs.contains(where: batchIDs.contains) {
        reviewStore.openConversation(row)
    }
    assert(reviewStore.attentionEvents.count == 1 && reviewStore.attentionEvents[0].sessionId == "later")
    reviewStore.openNotification(["event_ids": [reviewStore.attentionEvents[0].id], "tool": "codex-ide"]) {
        historyOpened += 1
    }
    assert(reviewStore.attentionEvents.isEmpty && openedTools.count == 7 && historyOpened == 2)
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
    let groupedStore = StatusStore(collectorPath: nil, settings: reviewSettings,
                                   storageDirectory: temporary.appendingPathComponent("grouped-reads"),
                                   notificationSink: { _, _, _ in },
                                   eventOpener: { openedSessions.append($0.sessionId) })
    groupedStore.accept(snapshot([], at: now), now: now)
    groupedStore.accept(snapshot([("same", "ended"), ("unrelated", "ended")], at: now + 1), now: now + 1)
    groupedStore.accept(snapshot([("same", "waiting_input")], at: now + 2), now: now + 2)
    let oldRow = groupedStore.harnessGroups.flatMap(\.conversations).first { $0.sessionId == "same" }!
    assert(oldRow.eventIDs.count == 2)
    groupedStore.accept(snapshot([("same", "ended")], at: now + 3), now: now + 3)
    groupedStore.openConversation(oldRow)
    assert(openedSessions.last! == "same")
    assert(groupedStore.recentEvents.filter { oldRow.eventIDs.contains($0.id) }.allSatisfy(\.acknowledged))
    assert(groupedStore.attentionEvents.contains { $0.sessionId == "same" && $0.timestamp == now + 3 },
           "An event arriving after the clicked row was rendered must remain unread")
    assert(groupedStore.attentionEvents.contains { $0.sessionId == "unrelated" },
           "Opening one conversation cannot acknowledge another conversation")
    print("PASS: grouped conversation navigation preserves session IDs and scopes acknowledgements to displayed turns")
    for (name, tab, scheme) in [
        ("tasks-compact-light", "status", ColorScheme.light),
        ("status-attention-dark", "status", ColorScheme.dark),
        ("legacy-details-dark", "details", ColorScheme.dark),
        ("legacy-history-light", "history", ColorScheme.light),
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
        if ["status", "details", "history"].contains(tab) {
            assert(size.width == 380 && size.height <= 430)
            assert(defaults.string(forKey: "panelTab") == "status", "Removed pages must restore the unified status page")
        }
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
        assert(size.width == 380 && size.height <= 430, "Summary must stay bounded, even with 240 active tasks")
    }
    settings.experience.privacyMode = false
    for tab in ["general", "connections", "notify", "data", "welcome"] {
        let suite = "io.github.stubsx.lingmou.visual.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(tab, forKey: "settingsTab")
        try save("settings-" + tab, content: SettingsView(store: store, settings: settings, catalog: catalog,
                                                       maintenance: MaintenanceStore())
            .defaultAppStorage(defaults).frame(height: 740).background(Color.white), scheme: .light)
    }
    settings.experience.privacyMode = true
    try save("privacy-light", content: PanelView(store: store).defaultAppStorage(overviewDefaults)
        .background(Color.white), scheme: .light)
    try save("ball-attention", content: FloatingBallView(store: store, onToggle: {}).padding(16)
        .background(Color.white), scheme: .light)
    let petFolder = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("AIStatusBar/Resources/Pet/rem")
    let petTheme = PetThemeStore.loadTheme(folder: petFolder, isBuiltIn: true)
    let bubbleSamples: [(String, StatusBubbleState, Bool)] = [
        ("运行", StatusBubbleState(mood: .working(taskCount: 3)), false),
        ("悬停", StatusBubbleState(mood: .working(taskCount: 3)), true),
        ("部分结束", StatusBubbleState(mood: .working(taskCount: 2), completedCount: 1,
                                    completionMessage: "Codex 本轮已结束"), false),
        ("待处理", StatusBubbleState(mood: .working(taskCount: 3), attentionCount: 1), false)
    ]
    for scheme in [ColorScheme.light, .dark] {
        try save("pet-bubbles-" + (scheme == .light ? "light" : "dark"), content: HStack(spacing: 16) {
            ForEach(0..<bubbleSamples.count, id: \.self) { index in
                let sample = bubbleSamples[index]
                VStack(spacing: 12) {
                    PetSprite(mood: sample.1.completedCount > 0 ? .celebrating : sample.1.mood,
                              theme: petTheme, scale: 1)
                        .frame(width: 220, height: 236, alignment: .bottom)
                        .overlay(alignment: .top) {
                            StatusBubble(state: sample.1, expanded: sample.2).padding(.top, 3)
                        }
                    Text(sample.0).font(.system(size: 12))
                }
            }
        }.padding(20).background(scheme == .light ? Color.white : Color(red: 0.08, green: 0.11, blue: 0.17)), scheme: scheme)
    }
    try save("pet-gallery", content: PetGalleryView(settings: settings, catalog: catalog).background(Color.white), scheme: .light)
    let keyboardPanel = TaskPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    keyboardPanel.isReleasedWhenClosed = false
    keyboardPanel.navigationDefaults = overviewDefaults
    assert(keyboardPanel.canBecomeKey, "Status panel must support keyboard focus")
    let keyboardHost = NSHostingView(rootView: PanelView(store: store).defaultAppStorage(overviewDefaults))
    keyboardPanel.contentView = keyboardHost
    keyboardPanel.setFrame(NSRect(x: -10000, y: -10000, width: PanelView.panelWidth, height: 300), display: false)
    keyboardPanel.makeKeyAndOrderFront(nil)
    RunLoop.current.run(until: Date().addingTimeInterval(0.1))
    for (character, code, expected) in [("2", UInt16(19), "usage"), ("3", 20, "heat"), ("4", 21, "quota"),
                                        ("1", 18, "status")] {
        let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0,
                                    windowNumber: keyboardPanel.windowNumber, context: nil, characters: character,
                                    charactersIgnoringModifiers: character, isARepeat: false, keyCode: code)!
        let handled = keyboardPanel.performKeyEquivalent(with: event)
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        assert(handled && overviewDefaults.string(forKey: "panelTab") == expected, "Panel shortcut ⌘\(character) must open \(expected)")
        let expectedWidth: CGFloat = 380
        assert(keyboardHost.fittingSize.width == expectedWidth && keyboardHost.fittingSize.height <= 430,
               "Switching among all four pages must keep the same wider panel width")
    }
    for character in ["5", "e"] {
        let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0,
                                    windowNumber: keyboardPanel.windowNumber, context: nil, characters: character,
                                    charactersIgnoringModifiers: character, isARepeat: false, keyCode: 0)!
        _ = keyboardPanel.performKeyEquivalent(with: event)
        assert(overviewDefaults.string(forKey: "panelTab") == "status", "Removed page shortcuts cannot reopen a details page")
    }
    func nativeScrollViews(_ view: NSView) -> [NSScrollView] {
        (view as? NSScrollView).map { [$0] } ?? view.subviews.flatMap(nativeScrollViews)
    }
    let horizontal = nativeScrollViews(keyboardHost).first {
        ($0.documentView?.frame.width ?? 0) > $0.contentView.bounds.width + 20
    }!
    assert(horizontal.contentView.bounds.width > 155 && horizontal.contentView.bounds.width < 175,
           "The tab strip must expose about three-and-a-half compact buttons")
    // Fit the fixture as the app does so the tab strip stays inside its window.
    keyboardPanel.setContentSize(keyboardHost.fittingSize)
    keyboardHost.layoutSubtreeIfNeeded()
    keyboardPanel.center()
    RunLoop.current.run(until: Date().addingTimeInterval(0.1))
    func wheelEvent(_ delta: Int32) -> NSEvent {
        let cg = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2,
                         wheel1: 0, wheel2: delta, wheel3: 0)!
        let event = FixtureWheelEvent()
        event.source = NSEvent(cgEvent: cg)!
        event.targetWindow = keyboardPanel
        event.targetNumber = keyboardPanel.windowNumber
        event.point = horizontal.convert(NSPoint(x: horizontal.bounds.midX, y: horizontal.bounds.midY), to: nil)
        return event
    }
    // Dispatch only inside the fixture, with window-local coordinates. Never post
    // input globally or depend on the fixture's position on the user's desktop.
    let beforeScroll = horizontal.contentView.bounds.origin.x
    horizontal.scrollWheel(with: wheelEvent(-90))
    RunLoop.current.run(until: Date().addingTimeInterval(0.2))
    assert(horizontal.contentView.bounds.origin.x > beforeScroll,
           "Native horizontal wheel/trackpad scrolling must reveal the offscreen page buttons")
    assert(overviewDefaults.string(forKey: "panelTab") == "status", "Scrolling reveals choices without changing pages")
    horizontal.scrollWheel(with: wheelEvent(90))
    RunLoop.current.run(until: Date().addingTimeInterval(0.2))
    assert(horizontal.contentView.bounds.origin.x <= beforeScroll + 1,
           "Reverse horizontal scrolling must reveal the first page again")
    overviewDefaults.set("quota", forKey: "panelTab")
    RunLoop.current.run(until: Date().addingTimeInterval(0.2))
    assert(horizontal.contentView.bounds.origin.x > 0, "Keyboard selection must reveal its selected tab")
    let escape = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                 windowNumber: keyboardPanel.windowNumber, context: nil, characters: "\u{1b}",
                                 charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53)!
    assert(keyboardPanel.performKeyEquivalent(with: escape) && overviewDefaults.string(forKey: "panelTab") == "status")
    keyboardPanel.close()
    print("PASS: four direct page shortcuts, legacy-page migration, removed shortcuts and native horizontal tab scrolling")
    print("PASS: rendered isolated native experience snapshots, session links, event reading, bounded summaries, light/dark, inline page tabs, privacy, settings and attention badge")
}
if #available(macOS 13, *) { try MainActor.assumeIsolated { try renderExperience() } }
