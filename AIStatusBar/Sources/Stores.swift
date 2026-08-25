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

    @Published var defaultSec = 300 { didSet { save() } }
    @Published var perTool: [String: Int] = [:] { didSet { save() } }
    @Published var offlineAfterSec = 10800 { didSet { save() } }
    @Published var notifyEnabled = false {
        didSet {
            save()
            if notifyEnabled && !oldValue {
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
    /// 用量同步：多设备通过共享目录汇总用量/活跃；空目录 = iCloud Drive 默认目录
    @Published var usageSyncEnabled = false { didSet { save() } }
    @Published var usageSyncDir = "" { didSet { save() } }
    /// 用量数字单位：metric=K/M/B，wan=万/亿
    @Published var numberUnit = "metric" { didSet { save() } }

    /// Dock 图标开关即时生效：regular 显示 Dock 图标，accessory 纯菜单栏
    func applyDockIconPolicy() {
        NSApp.setActivationPolicy(showDockIcon ? .regular : .accessory)
    }

    private let path = NSHomeDirectory() + "/.ai-statusbar/settings.json"

    init() { load() }

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
        if let s = obj["usage_sync"] as? [String: Any] {
            if let v = s["enabled"] as? Bool { usageSyncEnabled = v }
            if let v = s["dir"] as? String { usageSyncDir = v }
        }
        if let v = obj["number_unit"] as? String, ["metric", "wan"].contains(v) { numberUnit = v }
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
            "usage_sync": ["enabled": usageSyncEnabled, "dir": usageSyncDir],
            "number_unit": numberUnit,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: obj, options: .prettyPrinted) else { return }
        let directory = NSHomeDirectory() + "/.ai-statusbar"
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
    /// 任务完成事件序号：通知和桌宠共用同一套去抖后完成判定。
    @Published var completedEventSerial = 0
    /// 桌宠庆祝气泡文案：在序号变化前先更新，确保 UI 拿到完成任务的工具名。
    @Published var completedEventMessage = "任务完成啦！"
    let collectorPath: String?
    let settings: SettingsStore
    private var timer: Timer?
    private var isRefreshing = false

    init(collectorPath: String?, settings: SettingsStore) {
        self.collectorPath = collectorPath
        self.settings = settings
    }

    private func finishRefresh(error: String?) {
        DispatchQueue.main.async {
            self.collectorError = error
            self.isRefreshing = false
        }
    }

    func start() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    func refresh() {
        guard !isRefreshing else { return }
        guard let path = collectorPath else {
            collectorError = "应用资源不完整：缺少 Swift 状态采集器"
            return
        }
            isRefreshing = true
            DispatchQueue.global(qos: .userInitiated).async {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: path)
                // 常驻宿主强制真采集（不读结果缓存）并回写 collector-cache.json，
                // SwiftBar / Übersicht 同一 10 秒窗口内直接共享这份结果。
                p.arguments = ["--json", "--refresh"]
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = FileHandle.nullDevice
            do {
                try p.run()
            } catch {
                self.finishRefresh(error: "无法启动 Swift 状态采集器")
                return
            }
            let raw = pipe.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
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
                self.data = decoded
                self.collectorError = nil
                self.isRefreshing = false
                self.checkTransitions(decoded)
                NotificationCenter.default.post(name: .statusUpdated, object: nil)
            }
        }
    }

    /// 会话级完成通知：按稳定会话 ID 追踪忙碌任务，某会话连续消失 N 轮才判定完成。
    /// 标题中途改名不会误报（ID 不变）；短暂卡顿掉线有宽限，不抖动。
    private static let finishGraceRounds = 3  // 连续消失 3 轮（约 30s）才通知
    private var trackedBusy: [String: [String: String]] = [:]   // toolKey -> (sessionId -> title)
    private var missingRounds: [String: [String: Int]] = [:]    // toolKey -> (sessionId -> 连续缺失轮数)

    private func checkTransitions(_ decoded: StatusData) {
        for t in decoded.tools {
            let skey = SettingsStore.settingKey(for: t.key)
            let current = Dictionary(uniqueKeysWithValues: t.busyItems.map { ($0.id, $0.title) })
            let prev = trackedBusy[t.key] ?? [:]

            // 消失的会话累计缺失轮数；重新出现的清零
            var missing = missingRounds[t.key] ?? [:]
            for id in prev.keys where current[id] == nil {
                missing[id] = (missing[id] ?? 0) + 1
            }
            for id in current.keys { missing.removeValue(forKey: id) }

            // 达到宽限轮数 → 判定完成，发通知（用最新标题），并从追踪表移除防止重复通知
            let finished = missing.filter { $0.value >= Self.finishGraceRounds }.map(\.key)
            if !finished.isEmpty {
                for id in finished { missing.removeValue(forKey: id) }
                let titles = finished.map { prev[$0] ?? "" }
                completedEventMessage = "\(t.name) 完成了任务"
                completedEventSerial &+= 1
                if settings.notifyEnabled(for: skey) {
                    notify(tool: t.name, key: t.key, finished: titles.map { $0.isEmpty ? "(任务)" : $0 })
                }
            }
            missingRounds[t.key] = missing
            var newTracked = current.merging(prev.filter { current[$0.key] == nil }) { new, _ in new }
            for id in finished { newTracked.removeValue(forKey: id) }
            trackedBusy[t.key] = newTracked
        }
    }

    private func notify(tool: String, key: String, finished: [String]) {
        let content = UNMutableNotificationContent()
        content.title = "\(tool) 进入空闲"
        var body = "已完成：" + finished.joined(separator: "、")
        if body.count > 120 { body = String(body.prefix(119)) + "…" }
        content.body = body
        content.sound = .default
        content.userInfo = ["tool": key]  // 点击通知时据此跳转对应 App / 宿主终端
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        ) { error in
            // 系统拒绝投递（未授权等）时留下日志，不再静默吞掉
            if let error { NSLog("灵眸：通知投递失败：\(error.localizedDescription)") }
        }
    }
}

// MARK: - 通知点击路由：跳到对应工具的 App 或宿主终端

/// "任务完成"通知被点击后的跳转规则：
/// - App 型工具（ZCode / Codex App / Kimi Work）激活对应应用，未运行则从 /Applications 拉起；
/// - CLI 型工具（Codex CLI / Kimi Code）回到跑着该进程的宿主终端——沿进程父链向上
///   找最近的 regular GUI 应用，编辑器内置终端（VS Code/Cursor）里的会话也能回到正确窗口。
/// 找不到宿主（CLI 已退出，或跑在 tmux 等脱离终端的服务端下）时不动作，保持默认行为。
enum NotificationRouter {
    /// 与 collector 的 Codex CLI 判定同一套排除串：ChatGPT/Codex App 与编辑器
    /// 扩展托管的 codex app-server / mcp-server 不算终端会话。
    private static let hostedCodexMarks = ["ChatGPT.app/", "Codex.app/", "app-server", "mcp-server"]

    static func openDestination(forToolKey key: String) {
        DispatchQueue.main.async {
            switch key {
            case "zcode":
                if activateRunningApp(named: ["ZCode"]) { return }
                if let terminal = hostTerminal(of: "zcode-cli") { activate(terminal); return }
                openApplication(bundleID: "dev.zcode.app", path: "/Applications/ZCode.app")
            case "codex-ide":
                // Codex 桌面体验可能跑在 Codex.app 或 ChatGPT.app 里，激活正在运行的那个
                if activateRunningApp(named: ["Codex", "ChatGPT"]) { return }
                openApplication(bundleID: "com.openai.codex", path: "/Applications/Codex.app")
            case "kimi-work":
                if activateRunningApp(named: ["Kimi"]) { return }
                openApplication(bundleID: nil, path: "/Applications/Kimi.app")
            case "codex-cli":
                if let terminal = hostTerminal(of: "codex", excluding: hostedCodexMarks) {
                    activate(terminal)
                }
            case "kimi":
                if let terminal = hostTerminal(of: "kimi") { activate(terminal) }
            case "dsh":
                // dsh 是浏览器里的 web 端，直接打开页面
                NSWorkspace.shared.open(URL(string: "http://127.0.0.1:3080/")!)
            default:
                break
            }
        }
    }

    private static func activateRunningApp(named names: [String]) -> Bool {
        let running = NSWorkspace.shared.runningApplications
        for name in names {
            if let app = running.first(where: {
                $0.activationPolicy == .regular && $0.localizedName == name
            }) {
                activate(app)
                return true
            }
        }
        return false
    }

    private static func activate(_ app: NSRunningApplication) {
        if #available(macOS 14, *) {
            app.activate()
        } else {
            app.activate(options: [])
        }
    }

    /// 未运行时拉起。Codex.app 与 ChatGPT.app 的 bundle id 同为 com.openai.codex，
    /// 按 bundle id 解析可能命中另一个，所以优先固定路径，找不到再交给 LaunchServices。
    private static func openApplication(bundleID: String?, path: String) {
        if FileManager.default.fileExists(atPath: path) {
            NSWorkspace.shared.openApplication(
                at: URL(fileURLWithPath: path), configuration: NSWorkspace.OpenConfiguration())
            return
        }
        if let bundleID,
            let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
        {
            NSWorkspace.shared.openApplication(
                at: url, configuration: NSWorkspace.OpenConfiguration())
        }
    }

    /// 跑着指定 CLI 进程的宿主 GUI 应用：按可执行名筛出目标进程，再沿父进程链
    /// 向上找最近的 regular App（终端或编辑器）。进程匹配语义与 collector 的
    /// CLI 判定一致，避免误把 App/无头服务托管的进程当作终端会话。
    private static func hostTerminal(
        of processName: String, excluding: [String] = []
    ) -> NSRunningApplication? {
        guard let lines = psLines() else { return nil }
        let appByPid = Dictionary(
            NSWorkspace.shared.runningApplications
                .filter { $0.activationPolicy == .regular }
                .map { ($0.processIdentifier, $0) },
            uniquingKeysWith: { first, _ in first })
        let parents = Dictionary(
            lines.map { ($0.pid, $0.ppid) }, uniquingKeysWith: { first, _ in first })
        for line in lines where isCLI(line.args, named: processName, excluding: excluding) {
            var cursor = line.ppid
            while cursor > 1 {
                if let app = appByPid[cursor] { return app }
                cursor = parents[cursor] ?? 0
            }
        }
        return nil
    }

    /// 与 collector ProcessSupport.count 同语义：剥掉前导环境变量赋值后按可执行
    /// 文件名匹配；整行含排除串（如 app-server 托管进程）则跳过。
    private static func isCLI(_ args: String, named name: String, excluding: [String]) -> Bool {
        var tokens = args.split(separator: " ").map(String.init)
        while let first = tokens.first, first.contains("=") && !first.hasPrefix("/") {
            tokens.removeFirst()
        }
        guard let executable = tokens.first,
            URL(fileURLWithPath: executable).lastPathComponent == name,
            !excluding.contains(where: args.contains)
        else { return false }
        return true
    }

    private static func psLines() -> [(pid: pid_t, ppid: pid_t, args: String)]? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-eo", "pid=,ppid=,args="]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        var lines: [(pid: pid_t, ppid: pid_t, args: String)] = []
        for raw in String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline) {
            let fields = raw.split(separator: " ", maxSplits: 2).map(String.init)
            guard fields.count == 3, let pid = Int32(fields[0]), let ppid = Int32(fields[1]) else {
                continue
            }
            lines.append((pid, ppid, fields[2]))
        }
        return lines
    }
}
