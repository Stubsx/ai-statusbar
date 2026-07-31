import Cocoa
import SwiftUI
import UserNotifications

// MARK: - 数据模型（对应 ai_status.py --json 的输出）

struct ToolStatus: Codable {
    let key: String
    let letter: String
    let name: String
    let state: String          // busy / idle / off
    let busyCount: Int
    let busyTitles: [String]
    let detail: String
    let latestTitle: String?
    let latestAge: String?
}

struct UsageEntry: Codable {
    let input: Int
    let output: Int
    let cache: Int
}

struct HeatDay: Codable {
    let date: String
    let total: Int
    let future: Bool
}

struct UsageData: Codable {
    let date: String
    let tools: [String: UsageEntry]
    let total: UsageEntry
    let heatmap: [HeatDay]?
    let heatmax: Int?
}

struct StatusData: Codable {
    let updatedAt: String
    let tools: [ToolStatus]
    let usage: UsageData?
}

extension Notification.Name {
    static let statusUpdated = Notification.Name("statusUpdated")
}

// MARK: - 设置（持久化到 ~/.ai-statusbar/settings.json，与采集端共享）

final class SettingsStore: ObservableObject {
    static let tools = [("codex", "Codex"), ("kimi", "Kimi Code"), ("claude", "Claude Code"),
                        ("hermes", "Hermes"), ("zcode", "ZCode")]
    static let busyOptions = [60, 180, 300, 600, 900, 1800]
    static let offlineOptions: [(String, Int)] = [("1 小时", 3600), ("2 小时", 7200), ("3 小时", 10800),
                                                  ("6 小时", 21600), ("12 小时", 43200), ("从不", 0)]

    @Published var defaultSec = 300 { didSet { save() } }
    @Published var perTool: [String: Int] = [:] { didSet { save() } }
    @Published var offlineAfterSec = 10800 { didSet { save() } }
    @Published var notifyEnabled = true { didSet { save() } }
    @Published var notifyTools: [String: Bool] = [:] { didSet { save() } }

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
    }

    private func save() {
        let obj: [String: Any] = [
            "default_busy_sec": defaultSec,
            "per_tool": perTool,
            "offline_after_sec": offlineAfterSec,
            "notify": ["enabled": notifyEnabled, "tools": notifyTools],
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: obj, options: .prettyPrinted) else { return }
        try? FileManager.default.createDirectory(atPath: NSHomeDirectory() + "/.ai-statusbar",
                                                 withIntermediateDirectories: true)
        try? data.write(to: URL(fileURLWithPath: path))
    }
}

// MARK: - 状态采集

final class StatusStore: ObservableObject {
    @Published var data: StatusData?
    let scriptPath: String
    let settings: SettingsStore
    private var timer: Timer?
    private var prevBusy: [String: [String]] = [:]  // 上一轮各工具的忙碌任务，用于检测「工作中→空闲」

    init(scriptPath: String, settings: SettingsStore) {
        self.scriptPath = scriptPath
        self.settings = settings
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func start() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    func refresh() {
        let path = scriptPath
        DispatchQueue.global(qos: .userInitiated).async {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            p.arguments = ["python3", path, "--json"]
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = FileHandle.nullDevice
            guard (try? p.run()) != nil else { return }
            let raw = pipe.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            guard let decoded = try? decoder.decode(StatusData.self, from: raw) else { return }
            DispatchQueue.main.async {
                self.data = decoded
                self.checkTransitions(decoded)
                NotificationCenter.default.post(name: .statusUpdated, object: nil)
            }
        }
    }

    /// 某工具从「工作中」转为空闲/未运行 → 已完成消失的忙碌任务发系统通知
    private func checkTransitions(_ decoded: StatusData) {
        for t in decoded.tools {
            let prev = prevBusy[t.key] ?? []
            let finished = prev.filter { !t.busyTitles.contains($0) }
            let skey = SettingsStore.settingKey(for: t.key)
            if !finished.isEmpty && settings.notifyEnabled(for: skey) {
                notify(tool: t.name, finished: finished)
            }
            prevBusy[t.key] = t.busyTitles
        }
    }

    private func notify(tool: String, finished: [String]) {
        let content = UNMutableNotificationContent()
        content.title = "\(tool) 进入空闲"
        var body = "已完成：" + finished.joined(separator: "、")
        if body.count > 120 { body = String(body.prefix(119)) + "…" }
        content.body = body
        content.sound = .default
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }
}

// MARK: - 卡片背景：非液态玻璃系统（macOS 15 及以下）的回退材质
// macOS 26+ 由 AppKit 的 NSGlassEffectView 提供官方液态玻璃，不走这里

struct GlassCard: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(.ultraThinMaterial)
                    .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(Color.primary.opacity(0.12)))
                    .shadow(color: .black.opacity(0.4), radius: 16, y: 8)
            )
    }
}

/// bare=true 时背景由外层 NSGlassEffectView 提供，SwiftUI 不再画任何背景
struct ConditionalGlass: ViewModifier {
    let bare: Bool
    func body(content: Content) -> some View {
        if bare {
            content
        } else {
            content.modifier(GlassCard())
        }
    }
}

// MARK: - 可拖动的 HostingView：让 isMovableByWindowBackground 生效（原生拖动，零抖动）

final class DraggableHostingView<Content: View>: NSHostingView<Content> {
    override var mouseDownCanMoveWindow: Bool { true }
}

// MARK: - 桌面浮窗内容

struct PanelView: View {
    @ObservedObject var store: StatusStore
    var bare = false  // true = 背景由外层 NSGlassEffectView 提供，SwiftUI 不再画背景
    @AppStorage("panelPinned") private var pinned = true
    @AppStorage("panelTab") private var tab = "status"

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Text("AI AGENTS")
                    .font(.system(size: 11, weight: .semibold))
                    .tracking(1)
                    .foregroundColor(.secondary)
                Spacer()
                tabButton("状态", "status")
                tabButton("用量", "usage")
                tabButton("活跃", "heat")
            }
            .padding(.bottom, 8)

            if tab == "heat" {
                heatView
            } else if tab == "usage" {
                usageView
            } else if let tools = store.data?.tools {
                let visible = tools.filter { $0.state != "off" }  // 未运行的不显示
                if visible.isEmpty {
                    Text("全部未运行")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary.opacity(0.7))
                        .padding(.vertical, 4)
                }
                ForEach(visible, id: \.key) { t in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 10) {
                            Circle()
                                .fill(color(for: t.state))
                                .frame(width: 8, height: 8)
                                .shadow(color: t.state == "busy" ? color(for: t.state) : .clear, radius: 3)
                            Text(t.name)
                                .font(.system(size: 13, weight: .medium))
                            Spacer()
                            Text(t.state == "busy" ? label(for: t.state) : "\(label(for: t.state)) · \(t.detail)")
                                .font(.system(size: 11))
                                .foregroundColor(.secondary)
                            if t.state == "busy" {
                                Text("\(t.busyCount)")
                                    .font(.system(size: 11, weight: .bold))
                                    .foregroundColor(color(for: "busy"))
                            }
                        }
                        .padding(.vertical, 4)

                        ForEach(t.busyTitles, id: \.self) { title in
                            Text("▶ \(title)")
                                .font(.system(size: 11))
                                .foregroundColor(Color(red: 0.19, green: 0.82, blue: 0.35).opacity(0.85))
                                .lineLimit(1)
                                .truncationMode(.tail)
                                .padding(.leading, 18)
                        }
                        if t.busyTitles.isEmpty, let latest = t.latestTitle {
                            Text("最近：\(latest) · \(t.latestAge ?? "")")
                                .font(.system(size: 10))
                                .foregroundColor(.secondary.opacity(0.7))
                                .lineLimit(1)
                                .truncationMode(.tail)
                                .padding(.leading, 18)
                                .padding(.bottom, 4)
                        }
                    }
                }
            } else {
                Text("加载中…")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 10)
        .frame(width: 300)  // 固定宽度，长标题自动省略号
        .modifier(ConditionalGlass(bare: bare))
        .contextMenu {
            Button(pinned ? "取消置顶" : "置顶") {
                pinned.toggle()
                applyLevel()
            }
            Divider()
            Button("退出 AIStatusBar") { NSApp.terminate(nil) }
        }
        .onAppear { applyLevel() }
    }

    private func tabButton(_ title: String, _ id: String) -> some View {
        Button(action: { tab = id }) {
            Text(title)
                .font(.system(size: 10, weight: tab == id ? .semibold : .regular))
                .foregroundColor(tab == id ? Color.primary : Color.secondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 3)
                .background(Capsule().fill(tab == id ? Color.primary.opacity(0.16) : Color.primary.opacity(0.06)))
        }
        .buttonStyle(.plain)
    }

    private var usageView: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let u = store.data?.usage {
                HStack {
                    Text("今日用量 · \(u.date)")
                        .font(.system(size: 11, weight: .semibold))
                    Spacer()
                    Text("输入 / 缓存 / 输出")
                        .font(.system(size: 9))
                        .foregroundColor(.secondary.opacity(0.7))
                }
                .foregroundColor(.secondary)
                .padding(.bottom, 4)
                usageRow("总计", u.total, bold: true)
                Divider().background(Color.primary.opacity(0.1))
                ForEach(["codex", "kimi", "claude", "zcode", "hermes"], id: \.self) { key in
                    if let e = u.tools[key] {
                        usageRow(usageName(key), e, bold: false)
                    }
                }
            } else {
                Text("统计中…（首次全量索引约需几秒）")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
        }
    }

    private func usageRow(_ name: String, _ e: UsageEntry, bold: Bool) -> some View {
        HStack {
            Text(name)
                .font(.system(size: 12, weight: bold ? .semibold : .medium))
                .foregroundColor(bold ? Color.primary : Color.primary.opacity(0.8))
            Spacer()
            Text("\(fmt(e.input)) / \(fmt(e.cache)) / \(fmt(e.output))")
                .font(.system(size: 11, weight: bold ? .semibold : .regular).monospacedDigit())
                .foregroundColor(bold ? Color.primary.opacity(0.9) : Color.secondary)
        }
        .padding(.vertical, 4)
    }

    // MARK: 活跃热力图（GitHub 风格：列=周，行=周一~周日）

    @State private var hoveredDay: HeatDay? = nil

    private var heatView: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let h = store.data?.usage?.heatmap, !h.isEmpty {
                let heatmax = store.data?.usage?.heatmax ?? 0
                let heatmin = h.filter { $0.total > 0 }.map { $0.total }.min() ?? 0
                let cols = h.count / 7
                // 网格：固定尺寸方块，统一填充样式保证排列均匀
                HStack(spacing: 3) {
                    ForEach(0..<cols, id: \.self) { c in
                        VStack(spacing: 3) {
                            ForEach(0..<7, id: \.self) { r in
                                let day = h[c * 7 + r]
                                RoundedRectangle(cornerRadius: 3, style: .continuous)
                                    .fill(heatColor(day: day, min: heatmin, max: heatmax))
                                    .frame(width: 15, height: 15)
                                    .onHover { inside in
                                        hoveredDay = inside ? day : nil
                                    }
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .center)

                // 底部信息行：hover 显示当天详情，否则显示图例（高度固定不跳动）
                HStack {
                    if let d = hoveredDay {
                        Text("\(d.date) · \(fmt(d.total)) tokens")
                            .font(.system(size: 10, weight: .medium).monospacedDigit())
                            .foregroundColor(.secondary)
                    } else {
                        Text("较少")
                            .font(.system(size: 9))
                            .foregroundColor(.secondary.opacity(0.7))
                        RoundedRectangle(cornerRadius: 2, style: .continuous)
                            .fill(Color.primary.opacity(0.1))
                            .frame(width: 9, height: 9)
                        RoundedRectangle(cornerRadius: 4.5, style: .continuous)
                            .fill(LinearGradient(
                                colors: [Color.blue.opacity(0.15), Color.blue],
                                startPoint: .leading, endPoint: .trailing))
                            .frame(width: 36, height: 9)
                        Text("较多")
                            .font(.system(size: 9))
                            .foregroundColor(.secondary.opacity(0.7))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .center)
                .frame(height: 14)
            } else {
                Text("统计中…")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
        }
        .padding(.top, 2)
    }

    /// 连续渐变：0 = 浅灰，非零按对数归一化连续映射蓝色透明度（不分档）
    private func heatColor(day: HeatDay, min heatmin: Int, max heatmax: Int) -> Color {
        if day.future { return Color.clear }
        if day.total <= 0 || heatmax <= 0 { return Color.primary.opacity(0.1) }
        return Color.blue.opacity(0.15 + 0.85 * heatRatio(day.total, min: heatmin, max: heatmax))
    }

    /// 以「最小非零日」为下界的对数归一化，输出 0~1
    private func heatRatio(_ v: Int, min minV: Int, max maxV: Int) -> Double {
        let lo = log(Double(max(minV, 1))), hi = log(Double(maxV))
        if hi <= lo { return 1 }
        return min(1, max(0, (log(Double(v)) - lo) / (hi - lo)))
    }

    private func usageName(_ key: String) -> String {
        ["codex": "Codex", "kimi": "Kimi Code", "claude": "Claude Code", "zcode": "ZCode", "hermes": "Hermes"][key] ?? key
    }

    private func fmt(_ n: Int) -> String {
        if n >= 1_000_000 { return String(format: "%.1fM", Double(n) / 1_000_000) }
        if n >= 10_000 { return String(format: "%.0fK", Double(n) / 1_000) }
        if n >= 1_000 { return String(format: "%.1fK", Double(n) / 1_000) }
        return "\(n)"
    }

    private func applyLevel() {
        guard let w = NSApp.windows.first(where: { $0.identifier?.rawValue == "AIStatusPanel" }) as? NSPanel else { return }
        w.isFloatingPanel = pinned
        w.level = pinned ? .floating : .normal
    }

    private func color(for state: String) -> Color {
        switch state {
        case "busy": return Color(red: 0.19, green: 0.82, blue: 0.35)
        case "idle": return Color(red: 1.0, green: 0.84, blue: 0.04)
        default: return Color(white: 0.39)
        }
    }

    private func label(for state: String) -> String {
        switch state {
        case "busy": return "工作中"
        case "idle": return "空闲"
        default: return "未运行"
        }
    }
}

// MARK: - 设置窗口（macOS 26 风格：隐藏标题栏 + 卡片分组）

struct SettingsView: View {
    @ObservedObject var settings: SettingsStore
    @State private var notifyDiag = ""

    var body: some View {
        VStack(spacing: 16) {
            Text("设置")
                .font(.system(size: 20, weight: .bold))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 22)
                .padding(.top, 34)  // 给红绿灯按钮留位

            // 空闲判定时间
            card(title: "空闲判定时间", icon: "clock", subtitle: "无活动多久后算空闲") {
                row("统一设置") {
                    valuePicker($settings.defaultSec,
                                options: SettingsStore.busyOptions.map { (SettingsStore.labelSec($0), $0) })
                }
                divider
                ForEach(Array(SettingsStore.tools.enumerated()), id: \.offset) { idx, tool in
                    row(tool.1) {
                        valuePicker(perToolBinding(tool.0),
                                    options: [("跟随统一", 0)] + SettingsStore.busyOptions.map { (SettingsStore.labelSec($0), $0) })
                    }
                    if idx < SettingsStore.tools.count - 1 { divider }
                }
            }

            // 离线判定
            card(title: "离线判定", icon: "moon.zzz", subtitle: "进程在但无活动，超过后按未运行处理") {
                row("无活动超过") {
                    valuePicker($settings.offlineAfterSec, options: SettingsStore.offlineOptions)
                }
            }

            // 通知提醒
            card(title: "通知提醒", icon: "bell.badge", subtitle: "任务完成（工作中 → 空闲）时推送") {
                row("开启提醒") {
                    Toggle("", isOn: $settings.notifyEnabled)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.small)
                }
                divider
                ForEach(Array(SettingsStore.tools.enumerated()), id: \.offset) { idx, tool in
                    row(tool.1) {
                        Toggle("", isOn: notifyBinding(tool.0))
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .controlSize(.small)
                    }
                    .opacity(settings.notifyEnabled ? 1 : 0.4)
                    if idx < SettingsStore.tools.count - 1 { divider }
                }
                divider
                HStack(spacing: 10) {
                    Button("发送测试通知", action: testNotify)
                        .controlSize(.small)
                    if !notifyDiag.isEmpty {
                        Text(notifyDiag)
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                            .lineLimit(2)
                    }
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }

            Spacer(minLength: 0)
        }
        .padding(.bottom, 18)
        .frame(width: 470)
    }

    // MARK: 组件

    private var divider: some View {
        Divider().padding(.leading, 12).opacity(0.5)
    }

    @ViewBuilder
    private func card<C: View>(title: String, icon: String, subtitle: String,
                               @ViewBuilder content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .semibold))
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                Text("· " + subtitle)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
            .foregroundColor(.primary.opacity(0.8))
            .padding(.horizontal, 4)

            VStack(spacing: 0) { content() }
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.primary.opacity(0.045))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(Color.primary.opacity(0.06), lineWidth: 0.5)
                )
        }
        .padding(.horizontal, 20)
    }

    private func row<C: View>(_ title: String, @ViewBuilder control: () -> C) -> some View {
        HStack {
            Text(title)
                .font(.system(size: 13))
            Spacer()
            control()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
    }

    private func valuePicker(_ selection: Binding<Int>, options: [(String, Int)]) -> some View {
        Picker("", selection: selection) {
            ForEach(options, id: \.1) { label, sec in
                Text(label).tag(sec)
            }
        }
        .labelsHidden()
        .pickerStyle(.menu)
        .controlSize(.small)
        .frame(width: 108)
    }

    // MARK: 动作

    private func testNotify() {
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { s in
            let statusText = ["未请求过", "已被拒绝", "已允许", "临时允许", "未知"][min(s.authorizationStatus.rawValue, 4)]
            if s.authorizationStatus == .denied {
                DispatchQueue.main.async {
                    self.notifyDiag = "授权被拒绝（系统设置→通知→AIStatusBar 开启）"
                }
                return
            }
            center.requestAuthorization(options: [.alert, .sound]) { _, err in
                if let err = err {
                    DispatchQueue.main.async { self.notifyDiag = "授权请求失败：\(err.localizedDescription)" }
                    return
                }
                let content = UNMutableNotificationContent()
                content.title = "AIStatusBar 测试通知"
                content.body = "看到这条说明通知链路正常"
                content.sound = .default
                center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)) { err in
                    DispatchQueue.main.async {
                        self.notifyDiag = err.map { "发送失败：\($0.localizedDescription)" }
                            ?? "已发送（\(statusText)）"
                    }
                }
            }
        }
    }

    private func perToolBinding(_ key: String) -> Binding<Int> {
        Binding(
            get: { self.settings.perTool[key] ?? 0 },
            set: { v in
                if v == 0 { self.settings.perTool.removeValue(forKey: key) }
                else { self.settings.perTool[key] = v }
            }
        )
    }

    private func notifyBinding(_ key: String) -> Binding<Bool> {
        Binding(
            get: { self.settings.notifyTools[key] ?? true },
            set: { self.settings.notifyTools[key] = $0 }
        )
    }
}

// MARK: - AppDelegate

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private var panel: NSPanel!
    private var hosting: DraggableHostingView<PanelView>!
    private var store: StatusStore!
    private let settings = SettingsStore()
    private var settingsWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let scriptPath = Bundle.main.path(forResource: "ai_status", ofType: "py")
            ?? (NSHomeDirectory() + "/Desktop/未命名文件夹/swiftbar-plugins/ai_status.py")
        store = StatusStore(scriptPath: scriptPath, settings: settings)

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "AI …"
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        buildPanel()
        store.start()
        NotificationCenter.default.addObserver(self, selector: #selector(onStatusUpdated),
                                               name: .statusUpdated, object: nil)
    }

    // MARK: 菜单栏标题

    /// 菜单栏富文本徽标：字母(系统色) + 小圆点(状态色) + 任务数
    private func badgeTitle(_ tools: [ToolStatus]) -> NSAttributedString {
        let out = NSMutableAttributedString()
        let letterAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .medium),
        ]
        for (i, t) in tools.enumerated() {
            out.append(NSAttributedString(string: t.letter, attributes: letterAttrs))
            let dotColor: NSColor
            switch t.state {
            case "busy": dotColor = .systemGreen
            case "idle": dotColor = .systemYellow
            default: dotColor = .systemGray
            }
            out.append(NSAttributedString(string: "●", attributes: [
                .font: NSFont.systemFont(ofSize: 7, weight: .bold),
                .foregroundColor: dotColor,
                .baselineOffset: 2.5,
                .kern: -1,
            ]))
            if t.state == "busy" {
                out.append(NSAttributedString(string: "\(t.busyCount)", attributes: [
                    .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .bold),
                    .foregroundColor: NSColor.systemGreen,
                ]))
            }
            if i < tools.count - 1 {
                out.append(NSAttributedString(string: "  ", attributes: letterAttrs))
            }
        }
        return out
    }

    @objc private func onStatusUpdated() {
        guard let data = store.data else { return }
        let visible = data.tools.filter { $0.state != "off" }
        // 全部未运行时保留一个占位徽标，保证菜单入口还在
        statusItem.button?.attributedTitle = visible.isEmpty
            ? badgeTitle([ToolStatus(key: "_", letter: "AI", name: "", state: "off",
                                     busyCount: 0, busyTitles: [], detail: "",
                                     latestTitle: nil, latestAge: nil)])
            : badgeTitle(visible)

        // 浮窗尺寸跟随内容
        hosting.layout()
        let size = hosting.fittingSize
        if abs(panel.frame.height - size.height) > 1 || abs(panel.frame.width - size.width) > 1 {
            var f = panel.frame
            f.origin.y += f.size.height - size.height  // 保持顶边不动
            f.size = size
            panel.setFrame(f, display: true)
        }
    }

    private func mark(_ state: String) -> String {
        switch state {
        case "busy": return "🟢"
        case "idle": return "🟡"
        default: return "⚪️"
        }
    }

    /// 标题限宽，超长截断加省略号
    private func truncate(_ s: String, _ maxChars: Int = 40) -> String {
        s.count > maxChars ? String(s.prefix(maxChars - 1)) + "…" : s
    }

    // MARK: 菜单

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let label = ["busy": "工作中", "idle": "空闲", "off": "未运行"]
        if let data = store.data {
            let visible = data.tools.filter { $0.state != "off" }
            if visible.isEmpty {
                let empty = NSMenuItem(title: "全部未运行", action: nil, keyEquivalent: "")
                empty.isEnabled = false
                menu.addItem(empty)
                menu.addItem(.separator())
            }
            for t in visible {
                let header = NSMenuItem(title: "\(mark(t.state)) \(t.name)：\(label[t.state] ?? t.state)（\(t.detail)）",
                                        action: nil, keyEquivalent: "")
                header.isEnabled = false
                menu.addItem(header)
                for title in t.busyTitles.prefix(3) {
                    let item = NSMenuItem(title: "▶ \(truncate(title))", action: nil, keyEquivalent: "")
                    item.isEnabled = false
                    item.attributedTitle = NSAttributedString(string: item.title, attributes: [
                        .font: NSFont.systemFont(ofSize: 11),
                        .foregroundColor: NSColor.systemGreen,
                    ])
                    menu.addItem(item)
                }
                if t.busyTitles.isEmpty, let latest = t.latestTitle {
                    let item = NSMenuItem(title: "最近任务：\(truncate(latest, 34)) · \(t.latestAge ?? "")", action: nil, keyEquivalent: "")
                    item.isEnabled = false
                    item.attributedTitle = NSAttributedString(string: item.title, attributes: [
                        .font: NSFont.systemFont(ofSize: 11),
                        .foregroundColor: NSColor.secondaryLabelColor,
                    ])
                    menu.addItem(item)
                }
                menu.addItem(.separator())
            }
        }
        let settingsItem = NSMenuItem(title: "设置…", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)
        let toggle = NSMenuItem(title: UserDefaults.standard.bool(forKey: "panelVisible") ? "隐藏桌面卡片" : "显示桌面卡片",
                                action: #selector(togglePanel), keyEquivalent: "p")
        toggle.target = self
        menu.addItem(toggle)
        let pinned = UserDefaults.standard.object(forKey: "panelPinned") == nil
            ? true : UserDefaults.standard.bool(forKey: "panelPinned")
        let pin = NSMenuItem(title: "置顶桌面卡片", action: #selector(togglePin), keyEquivalent: "t")
        pin.target = self
        pin.state = pinned ? .on : .off
        menu.addItem(pin)
        let refresh = NSMenuItem(title: "刷新", action: #selector(doRefresh), keyEquivalent: "r")
        refresh.target = self
        menu.addItem(refresh)
        menu.addItem(.separator())
        let legend = NSMenuItem(title: "C=Codex App  X=Codex CLI  K=Kimi  L=Claude  H=Hermes  Z=ZCode", action: nil, keyEquivalent: "")
        legend.isEnabled = false
        legend.attributedTitle = NSAttributedString(string: legend.title, attributes: [
            .font: NSFont.systemFont(ofSize: 10),
            .foregroundColor: NSColor.secondaryLabelColor,
        ])
        menu.addItem(legend)
        let quit = NSMenuItem(title: "退出", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
    }

    // MARK: 桌面浮窗

    private func buildPanel() {
        // macOS 26+：用 AppKit 官方液态玻璃 NSGlassEffectView 做容器
        let systemGlass: Bool
        if #available(macOS 26.0, *) { systemGlass = true } else { systemGlass = false }
        hosting = DraggableHostingView(rootView: PanelView(store: store, bare: systemGlass))
        hosting.wantsLayer = true
        hosting.layer?.backgroundColor = NSColor.clear.cgColor  // 防止透明窗口边缘泛灰
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 320, height: 200),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.identifier = NSUserInterfaceItemIdentifier("AIStatusPanel")
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView(frame: NSRect(x: 0, y: 0, width: 320, height: 200))
            glass.cornerRadius = 18
            glass.contentView = hosting
            panel.contentView = glass
        } else {
            panel.contentView = hosting
        }
        let pinned = UserDefaults.standard.object(forKey: "panelPinned") == nil
            ? true : UserDefaults.standard.bool(forKey: "panelPinned")
        panel.isFloatingPanel = pinned
        panel.level = pinned ? .floating : .normal
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.isMovableByWindowBackground = true  // 原生拖动：系统处理，不抖不丢帧
        panel.acceptsMouseMovedEvents = true    // 保证热力图 hover 生效
        // 拖动结束（含实时拖动过程中）持久化位置
        NotificationCenter.default.addObserver(forName: NSWindow.didMoveNotification,
                                               object: panel, queue: .main) { [weak self] _ in
            guard let f = self?.panel.frame else { return }
            UserDefaults.standard.set(NSStringFromPoint(f.origin), forKey: "panelOrigin")
        }

        hosting.layout()
        panel.setContentSize(hosting.fittingSize)

        if let saved = UserDefaults.standard.string(forKey: "panelOrigin") {
            panel.setFrameOrigin(NSPointFromString(saved))
        } else if let screen = NSScreen.main {
            let vf = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x: vf.minX + 24, y: vf.maxY - panel.frame.height - 24))
        }

        let visible = UserDefaults.standard.object(forKey: "panelVisible") == nil
            ? true : UserDefaults.standard.bool(forKey: "panelVisible")
        if visible {
            panel.orderFront(nil)
        }
    }

    @objc private func openSettings() {
        if settingsWindow == nil {
            let w = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 470, height: 640),
                styleMask: [.titled, .closable, .fullSizeContentView],
                backing: .buffered, defer: false)
            w.title = "AIStatusBar 设置"
            w.titlebarAppearsTransparent = true
            w.titleVisibility = .hidden
            w.isMovableByWindowBackground = true
            w.contentView = NSHostingView(rootView: SettingsView(settings: settings))
            w.isReleasedWhenClosed = false
            w.center()
            settingsWindow = w
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    @objc private func togglePanel() {
        let show = !panel.isVisible
        UserDefaults.standard.set(show, forKey: "panelVisible")
        if show { panel.orderFront(nil) } else { panel.orderOut(nil) }
    }

    @objc private func togglePin() {
        let current = UserDefaults.standard.object(forKey: "panelPinned") == nil
            ? true : UserDefaults.standard.bool(forKey: "panelPinned")
        let pinned = !current
        UserDefaults.standard.set(pinned, forKey: "panelPinned")
        panel.isFloatingPanel = pinned
        panel.level = pinned ? .floating : .normal
        if pinned {
            panel.orderFront(nil)  // 置顶时顺手提到最前，避免找不到
        }
    }

    @objc private func doRefresh() {
        store.refresh()
    }
}

// MARK: - 入口

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)  // 无 Dock 图标，纯菜单栏 App
app.run()
