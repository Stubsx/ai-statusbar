import Cocoa
import Combine
import UserNotifications

// 状态与设置：SettingsStore（设置持久化）、StatusStore（状态采集）、NotificationRouter（通知点击路由）。

// MARK: - 设置（持久化到 ~/.ai-statusbar/settings.json，与采集端共享）

final class SettingsStore: ObservableObject {
    static let tools = [("codex", "Codex"), ("kimi", "Kimi Code"), ("kimi-work", "Kimi Work"),
                        ("claude", "Claude Code"), ("hermes", "Hermes"), ("zcode", "ZCode"),
                        ("dsh", "DSH")]
    static let busyOptions = [60, 180, 300, 600, 900, 1800]
    static let offlineOptions: [(String, Int)] = [("1 小时", 3600), ("2 小时", 7200), ("3 小时", 10800),
                                                  ("6 小时", 21600), ("12 小时", 43200), ("从不", 0)]
    /// 桌宠显示比例范围：0.6～1.6，默认原大
    static let petScaleRange: ClosedRange<Double> = 0.6...1.6

    private let systemEffects: Bool
    @Published var defaultSec = 300 { didSet { save() } }
    @Published var perTool: [String: Int] = [:] { didSet { save() } }
    @Published var offlineAfterSec = 10800 { didSet { save() } }
    @Published var notifyEnabled = false {
        didSet {
            save()
            if systemEffects && notifyEnabled && !oldValue {
                UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
            }
        }
    }
    @Published var notifyTools: [String: Bool] = [:] { didSet { save() } }
    @Published var showDockIcon = false { didSet { save(); applyDockIconPolicy() } }
    @Published var petAppearance = PetCatalog.defaultThemeID { didSet { save() } }
    @Published var petScale = 1.0 { didSet { save() } }
    /// 自定义形象素材库目录；空 = 默认本地目录 ~/.ai-statusbar/Pets。
    /// 指到 iCloud Drive 下的文件夹即可在多台 Mac 间同步形象（由系统 iCloud Drive 负责同步）。
    @Published var petLibraryDir = "" { didSet { save() } }
    @Published var onlineQuota = true { didSet { save() } }
    /// 解密新版 Kimi（3.2.4+）safeStorage 加密的登录凭证以读取月度额度；默认关闭
    @Published var kimiTokenDecrypt = false { didSet { save() } }
    /// Kimi App 关闭期间按频率代续期凭证（小时；0=关闭）。依赖解密开启。
    @Published var kimiTokenRefreshHours = 0 { didSet { save() } }
    /// 跳转 Kimi 网页时复用已打开的同源标签页（需浏览器自动化授权，失败回退新开）
    @Published var kimiWebTabReuse = true { didSet { save() } }
    /// 实验性桌面会话跳转；本机 Electron 调试连接，默认关闭。
    @Published var kimiDesktopSessionNavigation = false { didSet { save() } }
    /// 用量同步：多设备通过共享目录汇总用量/活跃；空目录 = iCloud Drive 默认目录
    @Published var usageSyncEnabled = false { didSet { save() } }
    @Published var usageSyncDir = "" { didSet { save() } }
    @Published var priceEstimatesEnabled = false { didSet { save() } }
    /// 用量数字单位：metric=K/M/B，wan=万/亿
    @Published var numberUnit = "metric" { didSet { save() } }
    /// 启动时后台检查一次新版本；发现更新会提醒，安装仍需用户确认
    @Published var autoUpdateCheck = true { didSet { save() } }
    @Published var experience = ExperiencePreferences() {
        didSet {
            save()
            if systemEffects && experience.quotaAlerts && !oldValue.quotaAlerts {
                UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
            }
            if systemEffects && experience.privacyMode && !oldValue.privacyMode {
                UNUserNotificationCenter.current().removeAllDeliveredNotifications()
                UNUserNotificationCenter.current().removeAllPendingNotificationRequests()
            }
        }
    }

    /// Dock 图标开关即时生效：regular 显示 Dock 图标，accessory 纯菜单栏
    func applyDockIconPolicy() {
        guard systemEffects else { return }
        NSApp.setActivationPolicy(showDockIcon ? .regular : .accessory)
    }

    private let path: String

    init(path: String? = nil, systemEffects: Bool = true) {
        self.systemEffects = systemEffects
        self.path = path ?? NSHomeDirectory() + "/.ai-statusbar/settings.json"
        load()
    }

    func busySec(for key: String) -> Int { perTool[key] ?? defaultSec }
    func notifyEnabled(for key: String) -> Bool { notifyEnabled && (notifyTools[key] ?? true) }

    /// UI 用的工具 key（codex-ide/codex-cli）映射到设置 key（codex）
    static func settingKey(for toolKey: String) -> String {
        toolKey.hasPrefix("codex") ? "codex" : toolKey
    }

    static func labelSec(_ sec: Int) -> String {
        sec < 3600 ? "\(sec / 60) 分钟" : "\(sec / 3600) 小时"
    }

    private func load() {
        guard let data = FileManager.default.contents(atPath: path),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        if let v = obj["default_busy_sec"] as? Int { defaultSec = v }
        if let p = obj["per_tool"] as? [String: Int] { perTool = p }
        if let v = obj["offline_after_sec"] as? Int { offlineAfterSec = v }
        if let n = obj["notify"] as? [String: Any] {
            if let e = n["enabled"] as? Bool { notifyEnabled = e }
            if let t = n["tools"] as? [String: Bool] { notifyTools = t }
        }
        if let v = obj["show_dock_icon"] as? Bool { showDockIcon = v }
        // 形象 id 是开放的（内置 + 用户自定义），这里不做白名单校验；
        // 形象缺失时由 PetCatalog.currentTheme 回退到默认形象。
        if let value = obj["pet_appearance"] as? String { petAppearance = value }
        if let v = obj["pet_library_dir"] as? String { petLibraryDir = v }
        if let v = obj["pet_scale"] as? Double {
            petScale = min(max(v, SettingsStore.petScaleRange.lowerBound),
                           SettingsStore.petScaleRange.upperBound)
        }
        if let v = obj["online_quota"] as? Bool { onlineQuota = v }
        if let v = obj["kimi_token_decrypt"] as? Bool { kimiTokenDecrypt = v }
        if let v = obj["kimi_token_refresh_hours"] as? Int, [0, 2, 5, 24].contains(v) {
            kimiTokenRefreshHours = v
        }
        if let v = obj["kimi_web_tab_reuse"] as? Bool { kimiWebTabReuse = v }
        if let v = obj["kimi_desktop_session_navigation"] as? Bool { kimiDesktopSessionNavigation = v }
        if let s = obj["usage_sync"] as? [String: Any] {
            if let v = s["enabled"] as? Bool { usageSyncEnabled = v }
            if let v = s["dir"] as? String { usageSyncDir = v }
        }
        if let v = obj["price_estimates_enabled"] as? Bool { priceEstimatesEnabled = v }
        if let v = obj["number_unit"] as? String, ["metric", "wan"].contains(v) { numberUnit = v }
        if let v = obj["auto_update_check"] as? Bool { autoUpdateCheck = v }
        if let value = obj["experience"], let data = try? JSONSerialization.data(withJSONObject: value),
           let preferences = try? JSONDecoder().decode(ExperiencePreferences.self, from: data) {
            experience = preferences
        } else {
            // 已有用户升级时不主动打断；指南仍可在设置中打开。
            experience.onboardingCompleted = true
        }
    }

    private func save() {
        let obj: [String: Any] = [
            "default_busy_sec": defaultSec,
            "per_tool": perTool,
            "offline_after_sec": offlineAfterSec,
            "notify": ["enabled": notifyEnabled, "tools": notifyTools],
            "show_dock_icon": showDockIcon,
            "pet_appearance": petAppearance,
            "pet_library_dir": petLibraryDir,
            "pet_scale": petScale,
            "online_quota": onlineQuota,
            "kimi_token_decrypt": kimiTokenDecrypt,
            "kimi_token_refresh_hours": kimiTokenRefreshHours,
            "kimi_web_tab_reuse": kimiWebTabReuse,
            "kimi_desktop_session_navigation": kimiDesktopSessionNavigation,
            "usage_sync": ["enabled": usageSyncEnabled, "dir": usageSyncDir],
            "price_estimates_enabled": priceEstimatesEnabled,
            "number_unit": numberUnit,
            "auto_update_check": autoUpdateCheck,
            "experience": (try? JSONSerialization.jsonObject(with: JSONEncoder().encode(experience))) ?? [:],
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: obj, options: .prettyPrinted) else { return }
        let directory = URL(fileURLWithPath: path).deletingLastPathComponent().path
        try? FileManager.default.createDirectory(
            atPath: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory)
        let url = URL(fileURLWithPath: path)
        try? data.write(to: url, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
    }
}

// MARK: - 状态采集

final class StatusStore: ObservableObject {
    @Published var data: StatusData?
    @Published var collectorError: String?
    @Published private(set) var isAuthorizingKimi = false
    @Published private(set) var kimiAuthorizationMessage: String?
    private var kimiAuthorizationProcess: Process?
    private var kimiAuthorizationCancelled = false

    /// Only a settings action can enter this path. Timers never invoke it.
    func authorizeKimiCredentials() {
        guard !isAuthorizingKimi else { return }
        guard let path = collectorPath else {
            kimiAuthorizationMessage = "缺少采集器，无法发起授权。请重新安装灵眸。"
            return
        }
        settings.kimiTokenDecrypt = false
        isAuthorizingKimi = true
        kimiAuthorizationCancelled = false
        kimiAuthorizationMessage = "请处理系统授权窗口；60 秒内未完成会自动结束，不会重试。"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = ["--authorize-kimi-keychain"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        kimiAuthorizationProcess = process
        // Launch on the main queue so cancel/quit cannot race a not-yet-started child.
        do { try process.run() } catch {
            kimiAuthorizationProcess = nil
            isAuthorizingKimi = false
            kimiAuthorizationMessage = "无法启动授权请求，解密保持关闭。"
            return
        }
        DispatchQueue.global(qos: .userInitiated).async {
            var status: Int32 = -1
            let timeout = CollectorProcessWatchdog.schedule(process, after: 62)
            process.waitUntilExit()
            timeout.cancel()
            if process.terminationReason == .exit { status = process.terminationStatus }
            let exitStatus = status
            DispatchQueue.main.async {
                self.kimiAuthorizationProcess = nil
                self.isAuthorizingKimi = false
                if self.kimiAuthorizationCancelled {
                    self.kimiAuthorizationMessage = "已取消授权，Kimi 凭证解密保持关闭。"
                } else if exitStatus == 0 {
                    self.settings.kimiTokenDecrypt = true
                    self.kimiAuthorizationMessage = "本次读取成功，授权已长期保存：重建或重装灵眸不再失效，后台不会弹窗。"
                    self.refresh()
                } else if exitStatus == 124 {
                    self.kimiAuthorizationMessage = "授权等待已超时，解密保持关闭。需要时可手动重试。"
                } else if exitStatus == 3 {
                    self.kimiAuthorizationMessage = "已有一个授权请求，请先处理或取消它。"
                } else {
                    self.kimiAuthorizationMessage = "未获得钥匙串读取权限，解密保持关闭，不会自动重试。"
                }
            }
        }
    }

    func cancelKimiAuthorization() {
        kimiAuthorizationCancelled = true
        if let process = kimiAuthorizationProcess { CollectorProcessWatchdog.stop(process) }
    }

    /// 关闭"读取 Kimi 月度额度"时删除授权时备份的解密口令副本。
    /// 路径与 LingmouCollectorCore/KimiSafeStorage.keyCachePath 保持一致。
    func clearKimiKeyCache() {
        try? FileManager.default.removeItem(
            atPath: NSHomeDirectory() + "/.ai-statusbar/kimi-safe-storage.key")
    }
    /// 任务完成事件序号：通知和桌宠共用同一套去抖后完成判定。
    @Published var completedEventSerial = 0
    /// 桌宠庆祝气泡文案：在序号变化前先更新，确保 UI 拿到完成任务的工具名。
    @Published var completedEventMessage = "本轮已结束"
    /// 本次事件批次的结束数量，供符号气泡使用；不是累计完成总数。
    @Published var completedEventCount = 0
    let collectorPath: String?
    let settings: SettingsStore
    private var timer: Timer?
    private var metricsTimer: Timer?
    private var isRefreshingMetrics = false
    private var isRefreshing = false
    private var sourceMonitor: SourceChangeMonitor?
    private var pendingRefresh: DispatchWorkItem?
    private var refreshAgain = false
    private var lastRefreshStarted = Date.distantPast
    @Published var recentEvents: [TaskRecord] = []
    @Published var historyError: String?
    @Published var lastCollectedAt: TimeInterval?
    private let journal: EventJournal
    private let quotaMonitor: QuotaMonitor
    private let eventFeed: LocalEventFeed
    private let notificationSink: ((String, String, [String: Any]) -> Void)?
    private let eventOpener: (ToolDestination) -> Void
    @Published var integrationError: String?
    @Published var quotaError: String?
    private var exportChanges: AnyCancellable?
    private var pendingNotifications: [TaskRecord] = []
    private var notificationWork: DispatchWorkItem?
    private var settingsChanges: AnyCancellable?

    var attentionEvents: [TaskRecord] {
        // The badge counts the same visible conversations as the panel, not
        // every historical turn. Running conversations supersede old results.
        let visibleIDs = Set(harnessGroups.flatMap(\.conversations).filter(\.needsAttention)
            .compactMap { $0.eventIDs.first })
        return recentEvents.filter { visibleIDs.contains($0.id) }.sorted {
            $0.priority == $1.priority ? $0.timestamp > $1.timestamp : $0.priority < $1.priority
        }
    }

    func displayTitle(_ title: String, fallback: String = "任务标题已隐藏") -> String {
        settings.experience.privacyMode ? fallback : title
    }

    func acknowledge(_ id: String) {
        acknowledgeEvents([id])
    }

    private func acknowledgeEvents(_ ids: [String]) {
        guard !ids.isEmpty else { return }
        journal.acknowledge(ids)
        let selected = Set(ids)
        // 用户先看过的事件不应在一秒合并窗口结束后再次弹出。
        pendingNotifications.removeAll { selected.contains($0.id) }
        recentEvents = journal.records
        historyError = journal.storageError
        NotificationCenter.default.post(name: .statusUpdated, object: nil)
    }

    /// 已读只清除本次提醒；历史与原工具的等待/结束状态仍然保留。
    func openEvent(_ record: TaskRecord) {
        acknowledge(record.id)
        eventOpener(ToolDestination(toolKey: record.toolKey, sessionId: record.sessionId))
    }

    var harnessGroups: [HarnessConversationGroup] {
        HarnessConversations.groups(tools: data?.tools ?? [], events: recentEvents)
    }

    func openConversation(_ conversation: HarnessConversation) {
        // A grouped row represents every recorded turn in this conversation.
        // Only acknowledge the events it displayed; a newer arriving event stays unread.
        acknowledgeEvents(conversation.eventIDs)
        eventOpener(ToolDestination(toolKey: conversation.toolKey, sessionId: conversation.sessionId))
    }

    /// 一键已读：批量清除一组会话的提醒，不打开任何会话；历史与原工具状态不受影响。
    func acknowledgeConversations(_ conversations: [HarnessConversation]) {
        acknowledgeEvents(conversations.flatMap(\.eventIDs))
    }

    func openNotification(_ info: [AnyHashable: Any], showHistory: () -> Void) {
        let ids = info["event_ids"] as? [String] ?? []
        let record = ids.count == 1 ? recentEvents.first { $0.id == ids[0] } : nil
        if let key = info["tool"] as? String {
            if ids.count == 1 { acknowledgeEvents(ids) }
            // Old notifications can recover their session from the journal. Quota and
            // multi-event notifications must not guess which conversation to open.
            let sessionId = ids.count == 1
                ? (info["session_id"] as? String ?? (record?.toolKey == key ? record?.sessionId : nil)) : nil
            eventOpener(ToolDestination(toolKey: key, sessionId: sessionId))
        } else {
            // Opening the list is not opening its results. Keep batch reminders
            // visible until the user follows each conversation's destination.
            showHistory()
        }
    }

    func clearHistory() {
        journal.clear()
        recentEvents = journal.records
        historyError = journal.storageError
        NotificationCenter.default.post(name: .statusUpdated, object: nil)
    }

    init(collectorPath: String?, settings: SettingsStore, storageDirectory: URL? = nil,
         notificationSink: ((String, String, [String: Any]) -> Void)? = nil,
         eventOpener: @escaping (ToolDestination) -> Void = NotificationRouter.openDestination) {
        self.notificationSink = notificationSink
        self.eventOpener = eventOpener
        self.collectorPath = collectorPath
        self.settings = settings
        let directory = storageDirectory ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".ai-statusbar")
        journal = EventJournal(directory: directory)
        quotaMonitor = QuotaMonitor(directory: directory)
        eventFeed = LocalEventFeed(directory: directory)
        recentEvents = journal.records
        historyError = journal.storageError
        exportChanges = settings.$experience.sink { [weak self] preferences in
            guard let self else { return }
            self.eventFeed.configure(enabled: preferences.eventExport,
                                     includeTitles: preferences.eventExportTitles && !preferences.privacyMode)
            self.integrationError = self.eventFeed.storageError
        }
        settingsChanges = settings.objectWillChange.sink { [weak self] in
            self?.objectWillChange.send()
        }
    }

    private func finishRefresh(error: String?) {
        DispatchQueue.main.async {
            self.collectorError = error
            self.completeRefresh()
            if error != nil { self.journal.invalidate() }
            NotificationCenter.default.post(name: .statusUpdated, object: nil)
        }
    }

    func start(home: String = NSHomeDirectory()) {
        timer?.invalidate()
        metricsTimer?.invalidate()
        sourceMonitor = SourceChangeMonitor(home: home) { [weak self] in self?.scheduleRefresh() }
        refresh()
        metricsTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            self?.refreshMetrics()
        }
        metricsTimer?.tolerance = 2
    }

    /// Every actual scan resets the fallback deadline. A fixed repeating timer
    /// could launch another scan immediately after a filesystem-triggered one.
    private func armStatusFallback() {
        timer?.invalidate()
        let timer = Timer(timeInterval: 5, repeats: false) { [weak self] _ in
            self?.scheduleRefresh()
        }
        timer.tolerance = 0.1
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func scheduleRefresh() {
        if isRefreshing { refreshAgain = true; return }
        guard pendingRefresh == nil else { return }
        let delay = max(0.15, 1 - Date().timeIntervalSince(lastRefreshStarted))
        let work = DispatchWorkItem { [weak self] in
            self?.pendingRefresh = nil
            self?.refreshStatus()
        }
        pendingRefresh = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func completeRefresh() {
        isRefreshing = false
        if refreshAgain { refreshAgain = false; scheduleRefresh() }
    }

    private func refreshMetrics() {
        guard !isRefreshingMetrics, let path = collectorPath else { return }
        isRefreshingMetrics = true
        DispatchQueue.global(qos: .utility).async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: path)
            process.arguments = ["--metrics-only"]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            if (try? process.run()) != nil {
                let timeout = CollectorProcessWatchdog.schedule(process, after: 45)
                process.waitUntilExit()
                timeout.cancel()
            }
            DispatchQueue.main.async {
                self.isRefreshingMetrics = false
                self.scheduleRefresh()
            }
        }
    }

    /// Manual refresh includes enrichment; scheduled work keeps the two lanes independent.
    func refresh() {
        refreshMetrics()
        refreshStatus()
    }

    private func refreshStatus() {
        guard !isRefreshing else { return }
        guard let path = collectorPath else {
            collectorError = "应用资源不完整：缺少 Swift 状态采集器"
            journal.invalidate()
            return
        }
        // Manual refresh and source events share one pending slot.
        pendingRefresh?.cancel()
        pendingRefresh = nil
        armStatusFallback()
        isRefreshing = true
        lastRefreshStarted = Date()
        DispatchQueue.global(qos: .userInitiated).async {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: path)
            // Fast local state retains independently refreshed quota and usage.
            // Other frontends reuse the same complete JSON snapshot.
            p.arguments = ["--json", "--status-only"]
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = FileHandle.nullDevice
            do {
                try p.run()
            } catch {
                self.finishRefresh(error: "无法启动 Swift 状态采集器")
                return
            }
            let timeout = CollectorProcessWatchdog.schedule(p, after: 15)
            let raw = pipe.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            timeout.cancel()
            guard p.terminationStatus == 0 else {
                self.finishRefresh(error: "状态采集器异常退出（代码 \(p.terminationStatus)）")
                return
            }
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            guard let decoded = try? decoder.decode(StatusData.self, from: raw) else {
                self.finishRefresh(error: "状态数据格式不兼容，请尝试更新灵眸")
                return
            }
            DispatchQueue.main.async {
                self.accept(decoded)
                self.completeRefresh()
                NotificationCenter.default.post(name: .statusUpdated, object: nil)
            }
        }
    }

    func accept(_ decoded: StatusData, now: TimeInterval = Date().timeIntervalSince1970) {
        lastCollectedAt = decoded.collectedAt ?? now
        data = decoded
        collectorError = nil
        let events = journal.observe(decoded.tools, now: now)
        recentEvents = journal.records
        historyError = journal.storageError
        let endedIDs = Set(events.filter { $0.phase == "ended" }.map(\.id))
        let ended = attentionEvents.filter { endedIDs.contains($0.id) }
        if !ended.isEmpty {
            completedEventMessage = ended.count == 1
                ? "\(ended[0].toolName) 本轮已结束" : "\(ended.count) 个任务本轮已结束"
            completedEventCount = ended.count
            completedEventSerial &+= 1
        }
        eventFeed.append(events.map {
            LocalEvent(id: $0.id, tool: $0.toolKey, session: $0.sessionId, timestamp: $0.timestamp,
                       phase: $0.phase, evidence: $0.evidence, title: $0.title)
        }, includeTitles: settings.experience.eventExportTitles && !settings.experience.privacyMode, now: now)
        integrationError = eventFeed.storageError
        enqueueNotifications(events)
        if settings.experience.quotaAlerts, settings.experience.muteUntil <= now {
            for alert in quotaMonitor.observe(decoded.tools, threshold: settings.experience.quotaThreshold,
                                               recovery: settings.experience.quotaRecovery, now: now) {
                postNotification(title: alert.title, body: alert.body, info: ["tool": alert.toolKey])
            }
            quotaError = quotaMonitor.storageError
        }
    }

    private func enqueueNotifications(_ events: [TaskRecord]) {
        let eligible = events.filter { settings.notifyEnabled(for: SettingsStore.settingKey(for: $0.toolKey)) }
        guard !eligible.isEmpty, settings.experience.muteUntil <= Date().timeIntervalSince1970 else { return }
        if !settings.experience.mergeNotifications || eligible.contains(where: \.waiting) {
            deliverNotifications(eligible)
            return
        }
        pendingNotifications.append(contentsOf: eligible)
        notificationWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let records = self.pendingNotifications
            self.pendingNotifications.removeAll()
            self.deliverNotifications(records)
        }
        notificationWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: work)
    }

    private func deliverNotifications(_ records: [TaskRecord]) {
        guard settings.experience.muteUntil <= Date().timeIntervalSince1970 else { return }
        let eligible = records.filter { settings.notifyEnabled(for: SettingsStore.settingKey(for: $0.toolKey)) }
        guard let first = eligible.first else { return }
        let title = eligible.count == 1 ? "\(first.toolName) · \(first.label)" : "\(eligible.count) 项任务有更新"
        let body = eligible.prefix(5).map {
            settings.experience.privacyMode ? "\($0.toolName)：\($0.label)" : "\($0.title) · \($0.label)"
        }.joined(separator: "\n")
        var info: [String: Any] = ["event_ids": eligible.map(\.id)]
        if eligible.count == 1 {
            info["tool"] = first.toolKey
            info["session_id"] = first.sessionId
        }
        postNotification(title: title, body: String(body.prefix(400)), info: info)
    }

    private func postNotification(title: String, body: String, info: [String: Any]) {
        if let notificationSink { notificationSink(title, body, info); return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.userInfo = info
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        ) { error in
            if let error { NSLog("灵眸：通知投递失败：\(error.localizedDescription)") }
        }
    }
}
