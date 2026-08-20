import Cocoa
import SwiftUI
import UserNotifications
import ScreenCaptureKit
import CryptoKit

// MARK: - 图标规范（与 ZSpaceMonitor 对齐）
// 运行时图标一律用 SF Symbol 程序化绘制 + 语义状态色，
// 不用 emoji 或 ●/▶ 等文本字符（渲染随系统字体漂移、明暗外观下不可控）。
// App 图标资产（AppIcon.icns / iconset）的规范见 ../icons/README.md。

extension NSColor {
    /// 三态语义色：busy=绿 idle=黄 off=灰。
    /// 菜单栏徽标、下拉菜单、面板共用同一映射，避免各处硬编码 RGB 后失配。
    static func toolStatusColor(_ state: String) -> NSColor {
        switch state {
        case "busy": return .systemGreen
        case "idle": return .systemYellow
        default: return .systemGray
        }
    }
}

/// 生成带颜色的 SF Symbol 图标（用于菜单行 NSMenuItem.image）。
/// 先绘制符号作为 alpha 蒙版，再用 sourceAtop 着色，保持背景透明。
func symbol(_ name: String, color: NSColor = .secondaryLabelColor,
            size: CGFloat = 13, weight: NSFont.Weight = .regular) -> NSImage? {
    let cfg = NSImage.SymbolConfiguration(pointSize: size, weight: weight)
    guard let base = NSImage(systemSymbolName: name, accessibilityDescription: nil) else { return nil }
    let src = base.withSymbolConfiguration(cfg) ?? base

    // 创建位图，固定 2x retina 尺寸保证菜单渲染稳定
    let scale: CGFloat = 2
    let canvasSize = NSSize(width: ceil(src.size.width), height: ceil(src.size.height))
    let pxW = Int(canvasSize.width * scale)
    let pxH = Int(canvasSize.height * scale)
    guard let bmp = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pxW, pixelsHigh: pxH,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
        isPlanar: false, colorSpaceName: .deviceRGB,
        bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
    // NSBitmapImageRep 默认以像素作为逻辑尺寸；显式设为 point 尺寸，
    // 否则 2x Retina 位图会把 SF Symbol 显示成正常大小的一半。
    bmp.size = canvasSize
    let out = NSImage(size: canvasSize)
    out.addRepresentation(bmp)

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bmp)

    // 先画符号建立透明蒙版，再把颜色 sourceAtop 到符号区域。
    // 若先填整张位图，透明背景也会保留下来，菜单中就会显示成色块。
    let bounds = NSRect(origin: .zero, size: canvasSize)
    src.draw(in: bounds,
             from: .zero, operation: .sourceOver, fraction: 1.0)
    color.set()
    bounds.fill(using: .sourceAtop)

    NSGraphicsContext.restoreGraphicsState()
    out.isTemplate = false
    return out
}

// MARK: - 数据模型（对应 lingmou-collector --json 的输出）

struct BusyItem: Codable, Hashable {
    let id: String
    let title: String
}

struct QuotaComponent: Codable, Hashable {
    let key: String
    let label: String
    let usedPercent: Double
}

struct QuotaWindow: Codable, Hashable {
    let kind: String
    let label: String
    let usedPercent: Double
    let resetsAt: Int
    let windowMinutes: Int?
    let components: [QuotaComponent]?
}

struct ToolQuota: Codable {
    let plan: String?
    let windows: [QuotaWindow]
    let updatedAt: Int
    let notice: String?
}

struct ToolStatus: Codable {
    let key: String
    let letter: String
    let name: String
    let state: String          // busy / idle / off
    let busyCount: Int
    let busyItems: [BusyItem]
    let detail: String
    let latestTitle: String?
    let latestAge: String?
    let quota: ToolQuota?
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

struct UsageRange: Codable {
    let tools: [String: UsageEntry]
    let total: UsageEntry
}

struct UsageData: Codable {
    let date: String
    let tools: [String: UsageEntry]
    let total: UsageEntry
    let heatmap: [HeatDay]?
    let heatmax: Int?
    let weekly: UsageRange?   // 近七日（含今日）；旧版 JSON 无此字段时为 nil
    let monthly: UsageRange?  // 近30日（含今日）
}

struct UsageSyncSource: Codable {
    let device: String
    let name: String
    let updatedAt: TimeInterval
    let days: Int
}

struct UsageSyncStatus: Codable {
    let enabled: Bool
    let dir: String?
    let device: String
    let name: String
    let sources: [UsageSyncSource]?
}

struct StatusData: Codable {
    let updatedAt: String
    let tools: [ToolStatus]
    let usage: UsageData?
    /// 合并同步目录所有设备后的用量/热力图；usage 恒为本机数据
    let usageMerged: UsageData?
    let sync: UsageSyncStatus?
}

extension Notification.Name {
    static let statusUpdated = Notification.Name("statusUpdated")
}

// MARK: - 设置（持久化到 ~/.ai-statusbar/settings.json，与采集端共享）

final class SettingsStore: ObservableObject {
    static let tools = [("codex", "Codex"), ("kimi", "Kimi Code"), ("kimi-work", "Kimi Work"),
                        ("claude", "Claude Code"), ("hermes", "Hermes"), ("zcode", "ZCode")]
    static let busyOptions = [60, 180, 300, 600, 900, 1800]
    static let offlineOptions: [(String, Int)] = [("1 小时", 3600), ("2 小时", 7200), ("3 小时", 10800),
                                                  ("6 小时", 21600), ("12 小时", 43200), ("从不", 0)]

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
    @Published var onlineQuota = true { didSet { save() } }
    /// 用量同步：多设备通过共享目录汇总用量/活跃；空目录 = iCloud Drive 默认目录
    @Published var usageSyncEnabled = false { didSet { save() } }
    @Published var usageSyncDir = "" { didSet { save() } }

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
        if let v = obj["online_quota"] as? Bool { onlineQuota = v }
        if let s = obj["usage_sync"] as? [String: Any] {
            if let v = s["enabled"] as? Bool { usageSyncEnabled = v }
            if let v = s["dir"] as? String { usageSyncDir = v }
        }
    }

    private func save() {
        let obj: [String: Any] = [
            "default_busy_sec": defaultSec,
            "per_tool": perTool,
            "offline_after_sec": offlineAfterSec,
            "notify": ["enabled": notifyEnabled, "tools": notifyTools],
            "show_dock_icon": showDockIcon,
            "online_quota": onlineQuota,
            "usage_sync": ["enabled": usageSyncEnabled, "dir": usageSyncDir],
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
            p.arguments = ["--json"]
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
                    notify(tool: t.name, finished: titles.map { $0.isEmpty ? "(任务)" : $0 })
                }
            }
            missingRounds[t.key] = missing
            var newTracked = current.merging(prev.filter { current[$0.key] == nil }) { new, _ in new }
            for id in finished { newTracked.removeValue(forKey: id) }
            trackedBusy[t.key] = newTracked
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

    // 右键菜单构建回调：由 AppDelegate 注入，读运行时置顶状态构建菜单。
    var contextMenuBuilder: (() -> NSMenu)?

    // AppKit 在右键派发早期调用本方法，覆盖整个 hosting view 区域，
    // 不受 SwiftUI .contextMenu 命中测试限制——空白处也能弹菜单。
    override func menu(for event: NSEvent) -> NSMenu? {
        contextMenuBuilder?()
    }
}

// MARK: - 桌面浮窗内容

struct PanelView: View {
    @ObservedObject var store: StatusStore
    @Environment(\.colorScheme) private var colorScheme
    var bare = false  // true = 背景由外层 NSGlassEffectView 提供，SwiftUI 不再画背景
    @AppStorage("panelPinned") private var pinned = true
    @AppStorage("panelTab") private var tab = "status"
    /// 用量/活跃的统计范围：all=全部同步设备（默认） local=仅本机
    @AppStorage("usageScope") private var usageScope = "all"
    /// 用量时间范围：today=今日（默认） 7d=近七日 30d=近30日
    @AppStorage("usageRange") private var usageRange = "today"

    /// 当前展示的用量数据：开启同步且选择"全部"时用合并视图，否则本机
    private var usageForDisplay: UsageData? {
        if usageScope == "all", let merged = store.data?.usageMerged { return merged }
        return store.data?.usage
    }

    private var syncAvailable: Bool { store.data?.usageMerged != nil }

    /// 本机/全部 切换（仅开启同步后出现）；默认"全部"
    @ViewBuilder
    private var scopeSwitch: some View {
        if syncAvailable {
            HStack(spacing: 0) {
                scopeButton("全部", tag: "all")
                scopeButton("本机", tag: "local")
            }
            .background(Capsule().fill(Color.primary.opacity(0.08)))
            .clipShape(Capsule())
        }
    }

    private func scopeButton(_ title: String, tag: String) -> some View {
        segmentButton(title, tag: tag, selection: $usageScope)
    }

    /// 用量时间范围切换：今日 / 近七日 / 近30日（近七日、近30日窗口均含今日）
    private var rangeSwitch: some View {
        HStack(spacing: 0) {
            rangeButton("今日", tag: "today")
            rangeButton("近七日", tag: "7d")
            rangeButton("近30日", tag: "30d")
        }
        .background(Capsule().fill(Color.primary.opacity(0.08)))
        .clipShape(Capsule())
    }

    private func rangeButton(_ title: String, tag: String) -> some View {
        segmentButton(title, tag: tag, selection: $usageRange)
    }

    /// 分段切换按钮的统一样式，scopeSwitch 与 rangeSwitch 共用
    private func segmentButton(
        _ title: String, tag: String, selection: Binding<String>
    ) -> some View {
        Button(action: { selection.wrappedValue = tag }) {
            Text(title)
                .font(.system(size: 9, weight: selection.wrappedValue == tag ? .semibold : .regular))
                .foregroundColor(selection.wrappedValue == tag ? Color.primary : Color.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 2)
                .background(
                    Capsule().fill(selection.wrappedValue == tag ? Color.primary.opacity(0.12) : .clear))
        }
        .buttonStyle(.plain)
    }

    /// 当前所选时间范围的分工具用量；旧版 JSON 无聚合字段时返回 nil 走"统计中"分支
    private var rangeEntries: (tools: [String: UsageEntry], total: UsageEntry)? {
        guard let u = usageForDisplay else { return nil }
        switch usageRange {
        case "7d": return u.weekly.map { ($0.tools, $0.total) }
        case "30d": return u.monthly.map { ($0.tools, $0.total) }
        default: return (u.tools, u.total)
        }
    }

    /// 时间范围的日期说明：今日显示当天，近七日/近30日显示起止区间
    private var rangeSubtitle: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "M月d日"
        let today = Date()
        guard usageRange != "today" else {
            return usageForDisplay?.date ?? formatter.string(from: today)
        }
        let span = usageRange == "7d" ? 6 : 29
        guard let start = Calendar.current.date(byAdding: .day, value: -span, to: today) else {
            return formatter.string(from: today)
        }
        return "\(formatter.string(from: start)) ~ \(formatter.string(from: today))"
    }

    /// 合并视图的来源摘要：N 台设备 · 最近更新时间，靠右下角展示
    @ViewBuilder
    private var syncSummary: some View {
        if usageScope == "all", let s = store.data?.sync, s.enabled {
            let latest = s.sources?.map(\.updatedAt).max() ?? 0
            Text("\(s.sources?.count ?? 1) 台设备 · 最近更新 \(latest > 0 ? timeHM(latest) : "—")")
                .font(.system(size: 9).monospacedDigit())
                .foregroundColor(.secondary.opacity(0.7))
                .padding(.top, 2)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }

    private func timeHM(_ timestamp: TimeInterval) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: Date(timeIntervalSince1970: timestamp))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Text("灵眸")
                    .font(.system(size: 11, weight: .semibold))
                    .tracking(1)
                    .foregroundColor(.secondary)
                Spacer()
                tabButton("状态", "status")
                tabButton("用量", "usage")
                tabButton("活跃", "heat")
                tabButton("配额", "quota")
            }
            .padding(.bottom, 8)

            if tab == "heat" {
                heatView
            } else if tab == "usage" {
                usageView
            } else if tab == "quota" {
                quotaView
            } else if let error = store.collectorError {
                Text(error)
                    .font(.system(size: 11))
                    .foregroundColor(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.vertical, 4)
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

                        ForEach(t.busyItems, id: \.id) { item in
                            HStack(spacing: 4) {
                                Image(systemName: "play.fill")
                                    .font(.system(size: 8, weight: .bold))
                                    .foregroundColor(color(for: "busy").opacity(0.85))
                                Text(item.title)
                                    .font(.system(size: 11))
                                    .foregroundColor(color(for: "busy").opacity(0.85))
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                            }
                            .padding(.leading, 18)
                        }
                        if t.busyItems.isEmpty, let latest = t.latestTitle {
                            HStack(spacing: 4) {
                                Image(systemName: "clock")
                                    .font(.system(size: 8))
                                    .foregroundColor(.secondary.opacity(0.7))
                                Text("最近：\(latest) · \(t.latestAge ?? "")")
                                    .font(.system(size: 10))
                                    .foregroundColor(.secondary.opacity(0.7))
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                            }
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
            if let entries = rangeEntries {
                HStack {
                    rangeSwitch
                    Spacer()
                    if syncAvailable {
                        scopeSwitch
                    } else {
                        Text("输入 / 缓存 / 输出")
                            .font(.system(size: 9))
                            .foregroundColor(.secondary.opacity(0.7))
                    }
                }
                Text(rangeSubtitle)
                    .font(.system(size: 9).monospacedDigit())
                    .foregroundColor(.secondary.opacity(0.7))
                    .padding(.top, 3)
                    .padding(.bottom, 5)
                usageRow("总计", entries.total, bold: true)
                Divider().background(Color.primary.opacity(0.1))
                ForEach(["codex", "kimi", "kimi-work", "claude", "zcode", "hermes"], id: \.self) { key in
                    if let e = entries.tools[key] {
                        usageRow(usageName(key), e, bold: false)
                    }
                }
                syncSummary
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

    // MARK: 配额（限额统计）

    private var quotaView: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let tools = store.data?.tools {
                // Codex App/CLI 共享同一配额，合并为一张卡片
                let withQuota = tools.filter { $0.quota != nil && $0.key != "codex-cli" }
                if withQuota.isEmpty {
                    Text("未检测到限额数据")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary.opacity(0.6))
                        .padding(.vertical, 4)
                }
                ForEach(withQuota, id: \.key) { t in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            Text(t.key == "codex-ide" ? "Codex" :
                                 t.name)
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundColor(.primary.opacity(0.9))
                            if let plan = t.quota?.plan, !plan.isEmpty {
                                Text(plan)
                                    .font(.system(size: 9, weight: .medium))
                                    .foregroundColor(.secondary)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Capsule().fill(Color.primary.opacity(0.08)))
                            }
                            Spacer()
                        }
                        if let notice = t.quota?.notice, !notice.isEmpty {
                            HStack(alignment: .top, spacing: 5) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .font(.system(size: 9))
                                    .foregroundColor(.orange)
                                Text(notice)
                                    .font(.system(size: 10))
                                    .foregroundColor(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .padding(.vertical, 2)
                        }
                        ForEach(t.quota?.windows ?? [], id: \.label) { w in
                            if w.kind == "month", !(w.components ?? []).isEmpty {
                                monthlyQuotaRow(w)
                            } else {
                                quotaRow(w)
                            }
                        }
                    }
                }
            } else {
                Text("加载中…")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
        }
    }

    private func quotaRow(_ w: QuotaWindow) -> some View {
        let used = min(max(w.usedPercent, 0), 100) / 100
        let elapsed = timeElapsedFraction(w)
        return VStack(alignment: .leading, spacing: 3) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.08))
                    Capsule().fill(quotaColor(w.usedPercent))
                        .frame(width: max(4, geo.size.width * CGFloat(used)))
                    if let elapsed {
                        timeCursor(elapsed, width: geo.size.width)
                    }
                }
            }
            .frame(height: 6)
            Text("\(w.label) · 已用 \(Int(w.usedPercent.rounded()))% · \(quotaResetText(w.resetsAt))")
                .font(.system(size: 10).monospacedDigit())
                .foregroundColor(.secondary)
        }
        .padding(.bottom, 2)
    }

    /// Kimi 月度额度：两段宽度均按整月额度计算，直观看出网页 Kimi 与 Code 的构成。
    private func monthlyQuotaRow(_ w: QuotaWindow) -> some View {
        let components = w.components ?? []
        let elapsed = timeElapsedFraction(w)
        return VStack(alignment: .leading, spacing: 3) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.08))
                    HStack(spacing: 0) {
                        ForEach(components, id: \.key) { component in
                            Rectangle()
                                .fill(monthlyComponentColor(component.key))
                                .frame(width: geo.size.width * CGFloat(
                                    min(max(component.usedPercent, 0), 100) / 100))
                        }
                    }
                    .clipShape(Capsule())
                    if let elapsed {
                        timeCursor(elapsed, width: geo.size.width)
                    }
                }
            }
            .frame(height: 6)
            Text("\(w.label) · 已用 \(String(format: "%.1f", w.usedPercent))% · \(quotaResetText(w.resetsAt))")
                .font(.system(size: 10).monospacedDigit())
                .foregroundColor(.secondary)
            HStack(spacing: 10) {
                ForEach(components, id: \.key) { component in
                    HStack(spacing: 4) {
                        Circle()
                            .fill(monthlyComponentColor(component.key))
                            .frame(width: 6, height: 6)
                        Text("\(component.label) \(String(format: "%.1f", component.usedPercent))%")
                            .font(.system(size: 9).monospacedDigit())
                            .foregroundColor(.secondary.opacity(0.85))
                    }
                }
            }
        }
        .padding(.bottom, 2)
    }

    /// 时间游标：当前时刻在配额窗口时间轴上的位置（0~1）。
    /// 窗口起点 = 重置时间 - 窗口时长（月度按对日推算）；无时长或不在窗口内时不显示。
    private func timeElapsedFraction(_ w: QuotaWindow) -> Double? {
        guard let minutes = w.windowMinutes, minutes > 0, w.resetsAt > 0 else { return nil }
        let span = TimeInterval(minutes) * 60
        let fraction = (Date().timeIntervalSince1970 - (TimeInterval(w.resetsAt) - span)) / span
        guard fraction >= 0, fraction <= 1 else { return nil }
        return fraction
    }

    /// 游标本体：2pt 竖线与进度条同高（6pt），完全落在条内，
    /// 不改变条的粗细与行距，深浅色自适应。
    private func timeCursor(_ fraction: Double, width: CGFloat) -> some View {
        Capsule()
            .fill(Color.primary.opacity(0.9))
            .frame(width: 2, height: 6)
            .offset(x: width * CGFloat(fraction) - 1)
    }

    private func monthlyComponentColor(_ key: String) -> Color {
        key == "code"
            ? Color(red: 0.19, green: 0.82, blue: 0.58)
            : Color(red: 0.48, green: 0.38, blue: 0.96)
    }

    /// 按用量升档着色：低用量绿、中等黄、逼近上限红（与状态语义色同源）
    private func quotaColor(_ usedPercent: Double) -> Color {
        switch usedPercent {
        case ..<50: return Color(NSColor.systemGreen)
        case ..<80: return Color(NSColor.systemYellow)
        default: return Color(NSColor.systemRed)
        }
    }

    private func quotaResetText(_ ts: Int) -> String {
        guard ts > 0 else { return "重置时间未知" }
        let date = Date(timeIntervalSince1970: TimeInterval(ts))
        let f = DateFormatter()
        if date.timeIntervalSinceNow > 86400 {
            f.dateFormat = "M月d日"
        } else {
            f.dateFormat = "HH:mm"
        }
        return f.string(from: date) + " 重置"
    }

    // MARK: 活跃热力图（GitHub 风格：列=周，行=周一~周日）

    @State private var hoveredDay: HeatDay? = nil

    /// 热力图覆盖的周数（列数），供未开同步时的标题行图例使用
    private var heatWeekCount: Int {
        (usageForDisplay?.heatmap ?? []).count / 7
    }

    private var heatView: some View {
        VStack(alignment: .leading, spacing: 8) {
            // 标题行常驻：未开同步时右侧显示周数图例，与用量页行结构对称，
            // 保证「全部/本机」切换在两页出现在同一槽位
            HStack {
                Text("活跃热力")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.secondary)
                Spacer()
                if syncAvailable {
                    scopeSwitch
                } else if heatWeekCount > 0 {
                    Text("近 \(heatWeekCount) 周")
                        .font(.system(size: 9))
                        .foregroundColor(.secondary.opacity(0.7))
                }
            }
            if let h = usageForDisplay?.heatmap, !h.isEmpty {
                let thresholds = heatThresholds(h)
                let today = todayKey
                let cols = h.count / 7
                // 网格：固定尺寸方块，统一填充样式保证排列均匀
                HStack(spacing: 3) {
                    ForEach(0..<cols, id: \.self) { c in
                        VStack(spacing: 3) {
                            ForEach(0..<7, id: \.self) { r in
                                let day = h[c * 7 + r]
                                RoundedRectangle(cornerRadius: 3, style: .continuous)
                                    .fill(heatColor(day: day, thresholds: thresholds))
                                    .frame(width: 15, height: 15)
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                                            .stroke(heatStroke(day: day, today: today),
                                                    lineWidth: 1)
                                    )
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
                        let level = heatLevel(d.total, thresholds: thresholds)
                        Text(d.total > 0
                             ? "\(d.date) · \(fmt(d.total)) tokens · \(level)/5"
                             : "\(d.date) · 无活动")
                            .font(.system(size: 10, weight: .medium).monospacedDigit())
                            .foregroundColor(.secondary)
                    } else {
                        Text("较少")
                            .font(.system(size: 9))
                            .foregroundColor(.secondary.opacity(0.7))
                        RoundedRectangle(cornerRadius: 2, style: .continuous)
                            .fill(Color.clear)
                            .frame(width: 9, height: 9)
                            .overlay(
                                RoundedRectangle(cornerRadius: 2, style: .continuous)
                                    .stroke(Color.primary.opacity(colorScheme == .dark ? 0.18 : 0.14),
                                            lineWidth: 1)
                            )
                        HStack(spacing: 2) {
                            ForEach(heatPalette.indices, id: \.self) { level in
                                RoundedRectangle(cornerRadius: 2, style: .continuous)
                                    .fill(heatPalette[level])
                                    .frame(width: 9, height: 9)
                            }
                        }
                        Text("较多")
                            .font(.system(size: 9))
                            .foregroundColor(.secondary.opacity(0.7))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .center)
                .frame(height: 14)
                syncSummary
            } else {
                Text("统计中…")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
        }
    }

    /// 未来日 = 全透明；无活动日 = 不填充（由 heatStroke 画淡描边"空槽"，
    /// 与任何有色级别结构性区分）；非零日按近十周五分位数分五级，避免极端值压缩色差。
    private func heatColor(day: HeatDay, thresholds: [Int]) -> Color {
        if day.future || day.total <= 0 { return Color.clear }
        return heatPalette[heatLevel(day.total, thresholds: thresholds) - 1]
    }

    /// 今天 = 主色描边；无活动日 = 淡描边空槽；其余无描边。
    private func heatStroke(day: HeatDay, today: String) -> Color {
        if day.date == today && !day.future { return Color.primary.opacity(0.8) }
        if !day.future && day.total <= 0 {
            return Color.primary.opacity(colorScheme == .dark ? 0.18 : 0.14)
        }
        return Color.clear
    }

    private func heatLevel(_ value: Int, thresholds: [Int]) -> Int {
        guard value > 0 else { return 0 }
        return min(5, 1 + thresholds.filter { value > $0 }.count)
    }

    private func heatThresholds(_ days: [HeatDay]) -> [Int] {
        let values = days.filter { !$0.future && $0.total > 0 }.map(\.total).sorted()
        guard let only = values.first else { return [] }
        guard values.count > 1 else { return Array(repeating: only, count: 4) }
        return [0.2, 0.4, 0.6, 0.8].map { percentile in
            let position = Double(values.count - 1) * percentile
            let lower = Int(position.rounded(.down))
            let upper = Int(position.rounded(.up))
            let fraction = position - Double(lower)
            return Int((Double(values[lower]) * (1 - fraction)
                        + Double(values[upper]) * fraction).rounded())
        }
    }

    /// 两种模式统一原则："无活动"是描边空槽，L1 起就是清晰可辨的蓝。
    /// 浅色：饱和度与深度同步递增（白底上越深越强）。
    /// 深色：以不透明度递增为主——低档是高透明的浅暗蓝、近乎融进背板，
    /// 档位越高越实越亮，峰值是最高饱和的电蓝；两个模式的信号因此统一为
    /// "离背板越远越活跃"，面板外观自适应翻转时深浅含义不再反转。
    private var heatPalette: [Color] {
        if colorScheme == .dark {
            return [
                Color(hue: 214.0 / 360, saturation: 0.90, brightness: 0.90).opacity(0.25),
                Color(hue: 210.0 / 360, saturation: 0.92, brightness: 0.92).opacity(0.42),
                Color(hue: 205.0 / 360, saturation: 0.94, brightness: 0.95).opacity(0.60),
                Color(hue: 198.0 / 360, saturation: 0.95, brightness: 0.97).opacity(0.80),
                Color(hue: 192.0 / 360, saturation: 0.95, brightness: 0.98),
            ]
        }
        return [
            Color(hue: 213.0 / 360, saturation: 0.22, brightness: 1.00),
            Color(hue: 211.0 / 360, saturation: 0.42, brightness: 0.99),
            Color(hue: 209.0 / 360, saturation: 0.62, brightness: 0.95),
            Color(hue: 206.0 / 360, saturation: 0.82, brightness: 0.88),
            Color(hue: 202.0 / 360, saturation: 0.95, brightness: 0.78),
        ]
    }

    private var todayKey: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: Date())
    }

    private func usageName(_ key: String) -> String {
        ["codex": "Codex", "kimi": "Kimi Code", "kimi-work": "Kimi Work", "claude": "Claude Code", "zcode": "ZCode", "hermes": "Hermes"][key] ?? key
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
        // 取消置顶时去掉全屏悬浮/跨 Space 行为，否则仍浮在全屏 App 之上
        w.collectionBehavior = pinned ? [.canJoinAllSpaces, .fullScreenAuxiliary] : []
    }

    private func color(for state: String) -> Color {
        Color(NSColor.toolStatusColor(state))
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
    @ObservedObject var store: StatusStore  // 同步来源状态来自最新一次采集
    @ObservedObject var settings: SettingsStore
    @State private var showOnlineQuotaAlert = false
    @State private var showAdaptiveAlert = false
    @State private var perToolBusyExpanded = false
    @AppStorage("desktopPresentationMode") private var desktopPresentationMode = "card"
    @AppStorage("panelAppearanceMode") private var appearanceMode = "system"

    private func chooseSyncDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.message = "选择用量同步目录；所有设备选择同一个目录即可汇总"
        let current = settings.usageSyncDir
        if !current.isEmpty {
            panel.directoryURL = URL(fileURLWithPath: current)
        } else {
            let home = NSHomeDirectory()
                + "/Library/Mobile Documents/com~apple~CloudDocs"
            if FileManager.default.fileExists(atPath: home) {
                panel.directoryURL = URL(fileURLWithPath: home)
            }
        }
        if panel.runModal() == .OK, let url = panel.url {
            settings.usageSyncDir = url.path
        }
    }

    private func timeHM(_ timestamp: TimeInterval) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: Date(timeIntervalSince1970: timestamp))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header

                section("状态判定") {
                    settingRow("进入空闲前无活动时长",
                               detail: "任务结束后超过该时长仍无新活动，则显示空闲") {
                        valuePicker($settings.defaultSec,
                                    options: SettingsStore.busyOptions.map { (SettingsStore.labelSec($0), $0) })
                    }
                    divider
                    perToolBusyDisclosure
                    divider
                    settingRow("长时间无活动视为离线",
                               detail: "进程仍在但持续无活动，超过该时长按未运行显示") {
                        valuePicker($settings.offlineAfterSec, options: SettingsStore.offlineOptions)
                    }
                }

                section("外观") {
                    settingRow("桌面显示", detail: "桌宠会根据 AI 工具状态切换动作") {
                        modePicker($desktopPresentationMode, options: [
                            ("桌面卡片", "card"), ("桌面宠物", "pet"), ("隐藏", "hidden"),
                        ])
                    }
                    divider
                    settingRow("面板配色", detail: "背景自适应按面板下方明暗自动反差") {
                        modePicker(appearanceModeBinding, options: [
                            ("跟随系统", "system"), ("浅色", "light"),
                            ("深色", "dark"), ("背景自适应", "adaptive"),
                        ])
                    }
                    .alert("需要录屏权限", isPresented: $showAdaptiveAlert) {
                        Button("取消", role: .cancel) {}
                        Button("同意并授权") {
                            appearanceMode = "adaptive"
                            (NSApp.delegate as? AppDelegate)?.requestScreenCaptureAccessIfNeeded()
                        }
                    } message: {
                        Text("背景自适应需要截取面板正下方一小块屏幕区域来判断明暗，因此需要录屏权限。截图只在内存中计算，不会保存或上传。")
                    }
                    divider
                    settingRow("在 Dock 中显示图标", detail: "默认仅驻留菜单栏") {
                        toggle($settings.showDockIcon)
                    }
                }

                section("数据") {
                    // 联网配额默认开启，只向各工具自己的厂商接口发送对应令牌。
                    settingRow("查询账号配额",
                               detail: "读取本地登录令牌，仅发送到对应厂商的配额接口") {
                        toggle(onlineQuotaBinding)
                    }
                    .alert("启用联网配额？", isPresented: $showOnlineQuotaAlert) {
                        Button("取消", role: .cancel) {}
                        Button("启用") { settings.onlineQuota = true }
                    } message: {
                        Text("灵眸会读取各工具的本地登录令牌，并仅发送到对应厂商的 HTTPS 配额接口。令牌不会写入灵眸日志或缓存。")
                    }
                    divider
                    settingRow("用量同步", detail: "多台设备共用一个目录（默认 iCloud Drive）汇总用量与活跃") {
                        toggle($settings.usageSyncEnabled)
                    }
                    if settings.usageSyncEnabled {
                        syncDetail
                    }
                }

                section("通知") {
                    settingRow("任务完成时提醒", detail: "工具从工作中转为空闲时推送") {
                        toggle($settings.notifyEnabled)
                    }
                    if settings.notifyEnabled {
                        notifyToolsGrid
                    }
                }

                Spacer(minLength: 2)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 20)
        }
        .frame(width: 470)
    }

    // MARK: 布局组件

    /// 顶部标识区：红绿灯按钮下方，复用 App 图标 + 名称 + 版本。
    private var header: some View {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString")
            as? String ?? ""
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
        return HStack(spacing: 12) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 34, height: 34)
            VStack(alignment: .leading, spacing: 2) {
                Text("灵眸")
                    .font(.system(size: 17, weight: .semibold))
                Text(version.isEmpty ? "设置" : "v\(version)（构建 \(build)）")
                    .font(.system(size: 10).monospacedDigit())
                    .foregroundColor(.secondary)
            }
            Spacer()
        }
        .padding(.top, 34)  // 给红绿灯按钮留位
    }

    /// 分区：小节标签 + 统一的圆角分组容器（替代旧的一事一卡，消解卡片标题噪音）
    private func section<Content: View>(_ title: String,
                                        @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.secondary.opacity(0.9))
                .padding(.leading, 2)
            VStack(spacing: 0) { content() }
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.primary.opacity(0.045)))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(Color.primary.opacity(0.07), lineWidth: 0.5))
        }
    }

    /// 统一行：左侧文案作为一个整体，右侧控件放入固定宽度的尾部区域。
    /// 这样下拉框与开关的右边缘一致，并且都相对标题+说明的整行垂直居中。
    private func settingRow<Control: View>(_ title: String, detail: String? = nil,
                                           @ViewBuilder control: () -> Control) -> some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 12.5, weight: .medium))
                if let detail {
                    Text(detail)
                        .font(.system(size: 10))
                        .foregroundColor(.secondary.opacity(0.85))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            control()
                .frame(width: 128, alignment: .trailing)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var divider: some View {
        Divider().padding(.leading, 14).opacity(0.5)
    }

    private func toggle(_ binding: Binding<Bool>) -> some View {
        Toggle("", isOn: binding)
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.regular)
    }

    /// 按工具自定义空闲时长：次级配置默认折叠，避免主导航被 6 行选择器淹没
    private var perToolBusyDisclosure: some View {
        DisclosureGroup(isExpanded: $perToolBusyExpanded) {
            VStack(spacing: 0) {
                ForEach(Array(SettingsStore.tools.enumerated()), id: \.offset) { idx, tool in
                    HStack {
                        Text(tool.1)
                            .font(.system(size: 12))
                            .foregroundColor(.primary.opacity(0.85))
                        Spacer()
                        valuePicker(perToolBinding(tool.0),
                                    options: [("跟随统一", 0)] + SettingsStore.busyOptions.map { (SettingsStore.labelSec($0), $0) })
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                    if idx < SettingsStore.tools.count - 1 {
                        Divider().padding(.leading, 14).opacity(0.4)
                    }
                }
            }
            .padding(.top, 2)
            .padding(.bottom, 4)
        } label: {
            Text(perToolBusyExpanded ? "收起按工具的自定义" : "按工具自定义空闲时长")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.accentColor.opacity(0.85))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    /// 通知工具清单：开启后以两列网格紧凑呈现
    private var notifyToolsGrid: some View {
        VStack(spacing: 0) {
            divider
            LazyVGrid(
                columns: [GridItem(.flexible(), spacing: 0), GridItem(.flexible(), spacing: 0)],
                alignment: .leading, spacing: 0
            ) {
                ForEach(Array(SettingsStore.tools.enumerated()), id: \.offset) { _, tool in
                    HStack {
                        Text(tool.1)
                            .font(.system(size: 11.5))
                            .foregroundColor(.primary.opacity(0.85))
                        Spacer()
                        toggle(notifyBinding(tool.0))
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 5)
                }
            }
            Text("仅为勾选的工具推送提醒")
                .font(.system(size: 10))
                .foregroundColor(.secondary.opacity(0.75))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14)
                .padding(.top, 3)
                .padding(.bottom, 8)
        }
    }

    /// 用量同步展开详情：目录选择、各设备来源与隐私说明
    private var syncDetail: some View {
        VStack(alignment: .leading, spacing: 0) {
            divider
            VStack(alignment: .leading, spacing: 9) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 10) {
                        Text("同步目录")
                            .font(.system(size: 11.5, weight: .medium))
                        Spacer(minLength: 10)
                        Button("选择…", action: chooseSyncDirectory)
                            .font(.system(size: 11))
                            .controlSize(.small)
                    }
                    Text(settings.usageSyncDir.isEmpty
                         ? "iCloud Drive/灵眸（默认）"
                         : settings.usageSyncDir)
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                if let sources = store.data?.sync?.sources, !sources.isEmpty {
                    VStack(spacing: 5) {
                        ForEach(Array(sources.enumerated()), id: \.offset) { _, source in
                            HStack(spacing: 6) {
                                Image(systemName: source.device == store.data?.sync?.device
                                      ? "macbook" : "desktopcomputer")
                                    .font(.system(size: 10))
                                    .foregroundColor(.secondary)
                                Text(source.name
                                     + (source.device == store.data?.sync?.device ? "（本机）" : ""))
                                    .font(.system(size: 10.5))
                                Spacer()
                                Text(source.updatedAt > 0
                                     ? "\(timeHM(source.updatedAt)) · \(source.days) 天"
                                     : "尚未导出")
                                    .font(.system(size: 10).monospacedDigit())
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                    .padding(.top, 2)
                } else {
                    Text("等待首次采集导出…（目录不可用时静默保持本机统计）")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary.opacity(0.8))
                }
                Text("仅同步日期、工具名与 token 计数，不含任务内容；每台设备只写自己的文件")
                    .font(.system(size: 9.5))
                    .foregroundColor(.secondary.opacity(0.7))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
        }
    }

    private func valuePicker(_ selection: Binding<Int>, options: [(String, Int)]) -> some View {
        Picker("", selection: selection) {
            ForEach(options, id: \.1) { label, sec in
                Text(label).tag(sec)
            }
        }
        .labelsHidden()
        .pickerStyle(.menu)
        .controlSize(.regular)
        .frame(width: 128, alignment: .trailing)
    }

    /// valuePicker 的 String 版本（外观模式等字符串枚举设置用）
    private func modePicker(_ selection: Binding<String>, options: [(String, String)]) -> some View {
        Picker("", selection: selection) {
            ForEach(options, id: \.1) { label, mode in
                Text(label).tag(mode)
            }
        }
        .labelsHidden()
        .pickerStyle(.menu)
        .controlSize(.regular)
        .frame(width: 128, alignment: .trailing)
    }

    // MARK: 动作

    /// 面板配色绑定：选"背景自适应"且未授权时不直接写入，先弹说明；
    /// 用户确认后才写入模式并触发系统授权框（见 row 上的 alert）。
    private var appearanceModeBinding: Binding<String> {
        Binding(
            get: { appearanceMode },
            set: { mode in
                if mode == "adaptive", !CGPreflightScreenCaptureAccess() {
                    showAdaptiveAlert = true
                } else {
                    appearanceMode = mode
                }
            }
        )
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

    /// 开启前先说明 Kimi App 依赖；关闭不需要二次确认。
    private var onlineQuotaBinding: Binding<Bool> {
        Binding(
            get: { settings.onlineQuota },
            set: { enabled in
                if enabled { showOnlineQuotaAlert = true }
                else { settings.onlineQuota = false }
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
    private var petPanel: NSPanel!
    private var petHosting: DraggableHostingView<PetView>!
    private var glassView: NSView?  // macOS 26+ 的 NSGlassEffectView（用 NSView 声明避开可用性注解）
    private var store: StatusStore!
    private let settings = SettingsStore()
    private var settingsWindow: NSWindow?
    private var activityToken: NSObjectProtocol?  // App Nap 防护 token，app 生命周期内持有
    private var fullscreenAutoHidden = false  // 当前是否因检测到全屏 App 而自动隐藏（区别于用户手动隐藏）
    private var fullscreenAutoHideSuppressed = false  // 用户在全屏期间手动重新显示后，本次会话内不再自动隐藏
    private var petDetailsExpanded = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        let collectorPath = Bundle.main.path(forResource: "lingmou-collector", ofType: nil)
        store = StatusStore(collectorPath: collectorPath, settings: settings)

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "AI …"
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        buildPanel()
        buildPetPanel()
        applyDesktopPresentationMode()
        store.start()
        NotificationCenter.default.addObserver(self, selector: #selector(onStatusUpdated),
                                               name: .statusUpdated, object: nil)
        // 防止 macOS 把后台菜单栏 app 的定时器节流（App Nap），保住 3 秒背景采样
        activityToken = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .suddenTerminationDisabled, .automaticTerminationDisabled],
            reason: "面板背景采样定时器")
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
            let dotColor = NSColor.toolStatusColor(t.state)
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
                                     busyCount: 0, busyItems: [], detail: "",
                                     latestTitle: nil, latestAge: nil, quota: nil)])
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

    // MARK: 面板配色跟随背景

    private var requestedCaptureAccess = false  // 每次启动只请求一次录屏权限

    /// 录屏授权弹框的去重键：当前签名证书的 SHA-1。
    /// TCC 授权跟随签名身份——换了证书（或 ad-hoc 重建）后系统视为新 app，会重新弹框；
    /// 对比"上次弹框时的证书哈希"，保证每个签名身份只自动弹一次，而不是每次启动都弹。
    /// ad-hoc 签名取不到证书链，统一归为 "adhoc"：宁可少弹，需要授权时走设置里的引导。
    private var capturePromptSignerKey: String {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return "unknown" }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return "unknown" }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let certs = (info as? [String: Any])?[kSecCodeInfoCertificates as String] as? [SecCertificate],
              let leaf = certs.first else { return "adhoc" }
        let der = SecCertificateCopyData(leaf) as Data
        return Insecure.SHA1.hash(data: der).map { String(format: "%02x", $0) }.joined()
    }
    private var appearanceCaptureGeneration: UInt = 0  // 丢弃异步返回的过期截图
    private var adaptiveAppearanceName: NSAppearance.Name?  // 滞回区内保持上次自适应判定

    /// 调试日志：往 ~/.ai-statusbar/adapt-debug.log 追加一行（ISO 时间戳 + 消息），异常静默
    private func adaptLog(_ msg: String) {
        guard ProcessInfo.processInfo.environment["LINGMOU_DEBUG"] == "1" else { return }
        let dir = NSHomeDirectory() + "/.ai-statusbar"
        let path = dir + "/adapt-debug.log"
        let line = ISO8601DateFormatter().string(from: Date()) + " " + msg + "\n"
        guard let data = line.data(using: .utf8) else { return }
        do {
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            if !FileManager.default.fileExists(atPath: path) {
                FileManager.default.createFile(atPath: path, contents: nil)
            }
            let fh = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
            fh.seekToEndOfFile()
            fh.write(data)
            try fh.close()
        } catch {}
    }

    /// 面板外观模式：light / dark / system / adaptive（默认 system，跟随系统，不需要录屏权限）。
    /// 旧 Bool 键 panelAdaptiveAppearance 迁移只在这里做：true→adaptive，其余→system。
    private func panelAppearanceMode() -> String {
        if let m = UserDefaults.standard.string(forKey: "panelAppearanceMode") {
            return m
        }
        let legacy = UserDefaults.standard.object(forKey: "panelAdaptiveAppearance") as? Bool
        return legacy == true ? "adaptive" : "system"
    }

    /// 设置里确认启用"背景自适应"后立刻请求录屏权限；已授权则什么都不做。
    /// 系统授权框只在无 TCC 记录时弹一次，已有记录（曾拒绝/启动时已请求过）时静默返回，
    /// 因此延迟复查仍未授权就直接打开"录屏"设置页，保证用户总有地方可以开。
    func requestScreenCaptureAccessIfNeeded() {
        guard !CGPreflightScreenCaptureAccess() else { return }
        requestedCaptureAccess = true
        // 用户在设置里显式开启，允许重新弹框；同时记录签名身份，启动时的自动弹框保持安静
        UserDefaults.standard.set(capturePromptSignerKey, forKey: "capturePromptSigner")
        CGRequestScreenCaptureAccess()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            guard !CGPreflightScreenCaptureAccess(),
                  let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
            else { return }
            NSWorkspace.shared.open(url)
        }
    }

    /// 同步设置 SwiftUI、窗口和玻璃容器。macOS 26 的玻璃只改 appearance 不保证底色有足够反差，
    /// 因此深/浅外观同时给玻璃加方向一致的 tint；system 模式仍保留系统原生无 tint 行为。
    private func setPanelAppearance(_ name: NSAppearance.Name?) {
        let appearance = name.flatMap { NSAppearance(named: $0) }
        if hosting.appearance?.name != name { hosting.appearance = appearance }
        if panel.appearance?.name != name { panel.appearance = appearance }
        if glassView?.appearance?.name != name { glassView?.appearance = appearance }
        #if compiler(>=6.2)
        if #available(macOS 26.0, *), let glass = glassView as? NSGlassEffectView {
            switch name {
            case .darkAqua:
                glass.tintColor = NSColor.black.withAlphaComponent(0.25)
                // NSGlassEffectView 的 tint 很克制，白色窗口上仅靠 tint 不足以托住白字；
                // 在内容层后加半透明底色，仍保留玻璃纹理，同时保证文字对比度。
                hosting.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.52).cgColor
            case .aqua:
                glass.tintColor = NSColor.white.withAlphaComponent(0.20)
                hosting.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.50).cgColor
            default:
                glass.tintColor = nil
                hosting.layer?.backgroundColor = NSColor.clear.cgColor
            }
        }
        #endif
    }

    /// 统一入口：按模式应用面板外观。light/dark/system 直写（不发 SCK 请求，开销可忽略）；
    /// adaptive 走背景采样。定时器/拖动/切 app/切 Space/设置变更都调这里。
    /// window→glass/hosting 的 appearance 传导均不可靠，三者都要直写。
    private func applyPanelAppearanceMode() {
        appearanceCaptureGeneration &+= 1
        let generation = appearanceCaptureGeneration
        switch panelAppearanceMode() {
        case "light":
            adaptiveAppearanceName = nil
            setPanelAppearance(.aqua)
        case "dark":
            adaptiveAppearanceName = nil
            setPanelAppearance(.darkAqua)
        case "system":  // 恢复跟随系统
            adaptiveAppearanceName = nil
            setPanelAppearance(nil)
        default:
            adaptPanelAppearance(generation: generation)
        }
    }

    /// adaptive 模式：截取面板正下方区域算平均亮度，亮背景→深色配色，暗背景→浅色配色（反差保证可读）。
    /// CGWindowListCreateImage 在 macOS 15+ 已废弃且静默返回 nil，改用 ScreenCaptureKit。
    /// 采样图保持面板宽高比，避免 ScreenCaptureKit 的透明留边稀释亮度；
    /// 滞回防抖动：>=0.58 深 / <=0.42 浅 / 中间保持上次判定。
    private func adaptPanelAppearance(generation: UInt) {
        guard panel.isVisible else { return }  // 面板不可见直接返回，省电
        // SCScreenshotManager 需要 macOS 14；低版本静默降级（不动 appearance）
        guard #available(macOS 14.0, *) else { return }
        // 无录屏权限：每个签名身份只自动弹一次授权框（TCC 跟随签名证书，
        // 本地构建/下载的 release/CI 产物签名不同时各自是"新 app"，不能每次启动都弹）
        if !CGPreflightScreenCaptureAccess() {
            let prompted = UserDefaults.standard.string(forKey: "capturePromptSigner")
            if !requestedCaptureAccess, prompted != capturePromptSignerKey {
                requestedCaptureAccess = true
                UserDefaults.standard.set(capturePromptSignerKey, forKey: "capturePromptSigner")
                CGRequestScreenCaptureAccess()
                adaptLog("无录屏权限，已弹授权请求（每个签名身份仅自动弹一次），本次采样放弃")
            } else {
                adaptLog("无录屏权限（已申请过，等待授权），跳过本次采样")
            }
            return
        }
        // AppKit 坐标(左下原点) → Quartz 全局坐标(主屏左上原点)
        var rect = panel.frame
        let primaryTop = NSScreen.screens.first?.frame.maxY ?? 0
        rect.origin.y = primaryTop - rect.maxY
        SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: true) { [weak self] content, error in
            guard let self else { return }
            if let error {
                self.adaptLog("SCShareableContent 失败: \(error.localizedDescription)")
                return
            }
            guard let content else { return }
            // 跨屏边缘时选择与面板相交面积最大的显示器，并把采样范围裁进该显示器。
            guard let display = content.displays
                .filter({ $0.frame.intersects(rect) })
                .max(by: {
                    let lhs = $0.frame.intersection(rect)
                    let rhs = $1.frame.intersection(rect)
                    return lhs.width * lhs.height < rhs.width * rhs.height
                })
            else {
                self.adaptLog("找不到相交 display: rect=\(rect) displays=\(content.displays.count)")
                return
            }
            let captureRect = rect.intersection(display.frame)
            guard !captureRect.isNull, captureRect.width > 0, captureRect.height > 0 else { return }
            // 排除自己 app 的窗口，避免采到面板自身
            let own = content.windows.filter {
                $0.owningApplication?.bundleIdentifier == Bundle.main.bundleIdentifier
            }
            let filter = SCContentFilter(display: display, excludingWindows: own)
            let config = SCStreamConfiguration()
            config.sourceRect = captureRect.offsetBy(dx: -display.frame.origin.x,
                                                     dy: -display.frame.origin.y)
            // 24 像素长边已足够判断整体明暗，同时让输出宽高比贴近采样区域。
            let longSide = 24.0
            if captureRect.width >= captureRect.height {
                config.width = Int(longSide)
                config.height = max(1, Int((longSide * captureRect.height / captureRect.width).rounded()))
            } else {
                config.height = Int(longSide)
                config.width = max(1, Int((longSide * captureRect.width / captureRect.height).rounded()))
            }
            // 明确填满目标小图；比例已在上方保持，关闭系统默认留边可避免透明黑边参与统计。
            config.preservesAspectRatio = false
            config.showsCursor = false
            SCScreenshotManager.captureImage(contentFilter: filter, configuration: config) { image, error in
                if let error {
                    self.adaptLog("captureImage 失败: \(error.localizedDescription)")
                    return
                }
                guard let image else { return }
                DispatchQueue.main.async {
                    // 截图异步完成前可能已切换模式/背景，只允许最新请求生效。
                    guard self.appearanceCaptureGeneration == generation,
                          self.panelAppearanceMode() == "adaptive"
                    else { return }
                    self.applyAppearance(for: image)
                }
            }
        }
    }

    /// 把小图转换为 RGBA，忽略透明填充并对预乘 alpha 反算真实颜色。
    /// 对亮度排序后裁掉两端各 10%，降低少量高亮/阴影内容对整张卡片判定的干扰。
    private func backgroundLuminance(for image: CGImage) -> (value: Double, valid: Int, total: Int)? {
        let width = image.width
        let height = image.height
        guard width > 0, height > 0 else { return nil }
        let bytesPerRow = width * 4
        var pixels = [UInt8](repeating: 0, count: bytesPerRow * height)
        let bitmapInfo = CGBitmapInfo.byteOrder32Big.rawValue
            | CGImageAlphaInfo.premultipliedLast.rawValue
        guard let ctx = CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8,
                                  bytesPerRow: bytesPerRow, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: bitmapInfo)
        else { return nil }
        ctx.interpolationQuality = .medium
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        var luminances: [Double] = []
        luminances.reserveCapacity(width * height)
        for i in stride(from: 0, to: pixels.count, by: 4) {
            let alpha = Double(pixels[i + 3]) / 255
            guard alpha >= 0.05 else { continue }  // 透明留边或无内容区域
            // CGContext 输出 premultipliedLast；反预乘后才是屏幕内容自身的颜色。
            let red = min(1, Double(pixels[i]) / 255 / alpha)
            let green = min(1, Double(pixels[i + 1]) / 255 / alpha)
            let blue = min(1, Double(pixels[i + 2]) / 255 / alpha)
            luminances.append(0.2126 * red + 0.7152 * green + 0.0722 * blue)
        }

        let total = width * height
        // 有效内容太少时不猜测，维持当前外观并等待下次采样。
        guard luminances.count >= max(4, total / 8) else { return nil }
        luminances.sort()
        let trim = luminances.count >= 20 ? luminances.count / 10 : 0
        let kept = luminances[trim..<(luminances.count - trim)]
        return (kept.reduce(0, +) / Double(kept.count), luminances.count, total)
    }

    /// 主线程：按背景亮度和滞回阈值切换 hosting/panel/glass 的 appearance。
    private func applyAppearance(for image: CGImage) {
        guard let sample = backgroundLuminance(for: image) else {
            adaptLog("有效背景像素不足，保持现状")
            return
        }
        let lum = sample.value
        let lumStr = String(format: "%.2f", lum)
        // macOS 26 实测：window.appearance 经 NSGlassEffectView 传到 NSHostingView 的链路断了，
        // .preferredColorScheme 动态更新对已渲染的 hosting view 也不生效（仅静态初始值有效）；
        // 唯一直写 hosting.appearance 立即生效（SwiftUI colorScheme 随之翻转），故以它为主通道；
        // window→glass 的传导同样不可靠，glassView 也要直写（玻璃背景明暗），panel.appearance 作副通道
        let appearanceName: NSAppearance.Name
        if lum >= 0.58 {
            appearanceName = .darkAqua
        } else if lum <= 0.42 {
            appearanceName = .aqua
        } else if let previous = adaptiveAppearanceName {
            appearanceName = previous
        } else {
            // 首次进入 adaptive 时不能没有结论；中点只用于首次判定，之后由滞回保持稳定。
            appearanceName = lum >= 0.5 ? .darkAqua : .aqua
        }
        adaptiveAppearanceName = appearanceName
        let changed = hosting.appearance?.name != appearanceName
        // 即使文字外观已相同，也同步一次玻璃 tint/内容底色，覆盖“系统原本就是该外观”的启动场景。
        setPanelAppearance(appearanceName)
        if changed {
            adaptLog("亮度 \(lumStr)（有效 \(sample.valid)/\(sample.total)），切换 \(appearanceName.rawValue)")
        } else {
            adaptLog("亮度 \(lumStr)（有效 \(sample.valid)/\(sample.total)），已是目标外观")
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
                empty.image = symbol("moon.zzz", color: .systemGray, size: 12)
                empty.isEnabled = false
                menu.addItem(empty)
                menu.addItem(.separator())
            }
            for t in visible {
                let header = NSMenuItem(title: "\(t.name)：\(label[t.state] ?? t.state)（\(t.detail)）",
                                        action: nil, keyEquivalent: "")
                header.image = symbol("circle.fill", color: NSColor.toolStatusColor(t.state), size: 10)
                header.isEnabled = false
                menu.addItem(header)
                for busy in t.busyItems.prefix(3) {
                    let item = NSMenuItem(title: truncate(busy.title), action: nil, keyEquivalent: "")
                    item.image = symbol("play.fill", color: .systemGreen, size: 11)
                    item.isEnabled = false
                    item.attributedTitle = NSAttributedString(string: item.title, attributes: [
                        .font: NSFont.systemFont(ofSize: 11),
                        .foregroundColor: NSColor.systemGreen,
                    ])
                    menu.addItem(item)
                }
                if t.busyItems.isEmpty, let latest = t.latestTitle {
                    let item = NSMenuItem(title: "最近任务：\(truncate(latest, 34)) · \(t.latestAge ?? "")", action: nil, keyEquivalent: "")
                    item.image = symbol("clock", color: .secondaryLabelColor, size: 11)
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
        settingsItem.image = symbol("gearshape")
        menu.addItem(settingsItem)
        let desktopItem = NSMenuItem(title: "桌面显示", action: nil, keyEquivalent: "")
        desktopItem.image = symbol("rectangle.on.rectangle")
        let desktopMenu = NSMenu()
        let mode = desktopPresentationMode
        let cardMode = NSMenuItem(title: "桌面卡片", action: #selector(selectCardMode), keyEquivalent: "")
        cardMode.target = self
        cardMode.state = mode == "card" ? .on : .off
        desktopMenu.addItem(cardMode)
        let petMode = NSMenuItem(title: "桌面宠物", action: #selector(selectPetMode), keyEquivalent: "")
        petMode.target = self
        petMode.state = mode == "pet" ? .on : .off
        desktopMenu.addItem(petMode)
        let hiddenMode = NSMenuItem(title: "隐藏", action: #selector(selectHiddenMode), keyEquivalent: "")
        hiddenMode.target = self
        hiddenMode.state = mode == "hidden" ? .on : .off
        desktopMenu.addItem(hiddenMode)
        desktopItem.submenu = desktopMenu
        menu.addItem(desktopItem)
        let pinned = UserDefaults.standard.object(forKey: "panelPinned") == nil
            ? true : UserDefaults.standard.bool(forKey: "panelPinned")
        let pin = NSMenuItem(title: "置顶桌面显示", action: #selector(togglePin), keyEquivalent: "t")
        pin.target = self
        pin.image = symbol("pin")
        pin.state = pinned ? .on : .off
        menu.addItem(pin)
        let fullscreenHide = NSMenuItem(title: "全屏时自动隐藏", action: #selector(toggleAutoHideFullscreen), keyEquivalent: "")
        fullscreenHide.target = self
        fullscreenHide.image = symbol("arrow.up.left.and.arrow.down.right")
        fullscreenHide.state = autoHideInFullscreenEnabled ? .on : .off
        menu.addItem(fullscreenHide)
        let refresh = NSMenuItem(title: "刷新", action: #selector(doRefresh), keyEquivalent: "r")
        refresh.target = self
        refresh.image = symbol("arrow.clockwise")
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
        quit.image = symbol("power", color: .systemRed)
        menu.addItem(quit)
    }

    // MARK: 桌面浮窗

    private func buildPanel() {
        // macOS 26+：用 AppKit 官方液态玻璃 NSGlassEffectView 做容器
        var systemGlass = false
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) { systemGlass = true }
        #endif
        hosting = DraggableHostingView(rootView: PanelView(store: store, bare: systemGlass))
        hosting.wantsLayer = true
        hosting.layer?.backgroundColor = NSColor.clear.cgColor  // 防止透明窗口边缘泛灰
        hosting.layer?.cornerRadius = 18
        hosting.layer?.masksToBounds = true
        // 面板右键菜单：点任意位置（含空白处）都能弹出，复用菜单栏已有的 togglePin 逻辑
        hosting.contextMenuBuilder = { [weak self] in
            self?.buildPanelContextMenu() ?? NSMenu()
        }
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 320, height: 200),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.identifier = NSUserInterfaceItemIdentifier("AIStatusPanel")
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView(frame: NSRect(x: 0, y: 0, width: 320, height: 200))
            glass.cornerRadius = 18
            glass.contentView = hosting
            panel.contentView = glass
            glassView = glass  // 持有引用：window→glass 的 appearance 传导不可靠，需直写
        } else {
            panel.contentView = hosting
        }
        #else
        panel.contentView = hosting
        #endif
        let pinned = UserDefaults.standard.object(forKey: "panelPinned") == nil
            ? true : UserDefaults.standard.bool(forKey: "panelPinned")
        panel.isFloatingPanel = pinned
        panel.level = pinned ? .floating : .normal
        panel.collectionBehavior = pinned ? [.canJoinAllSpaces, .fullScreenAuxiliary] : []
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
            guard let self else { return }
            let f = self.panel.frame
            // 桌宠模式的详情卡位置只是临时跟随，不覆盖独立卡片模式的位置记忆。
            if self.desktopPresentationMode == "card" {
                UserDefaults.standard.set(NSStringFromPoint(f.origin), forKey: "panelOrigin")
            }
            self.applyPanelAppearanceMode()  // 拖动后即时重检（adaptive 模式下重采背景亮度）
        }

        // 面板外观：每 3 秒走一次模式入口（adaptive 模式下检测面板下方亮度）
        let appearanceTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            self?.applyPanelAppearanceMode()
        }
        RunLoop.main.add(appearanceTimer, forMode: .common)
        // 事件驱动补采样：前台 app 切换 / 切 Space 时背景内容大概率变了，即时重检
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] _ in
            self?.applyPanelAppearanceMode()
            self?.updateFullscreenAutoHide()
        }
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.applyPanelAppearanceMode()
            self?.updateFullscreenAutoHide()
        }
        // 全屏自动隐藏：进出原生全屏伴随切 Space 事件可即时响应；网页全屏（不切 Space、
        // 只改窗口尺寸）没有系统通知，靠 1 秒轮询兜底
        let fullscreenTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            self?.updateFullscreenAutoHide()
        }
        RunLoop.main.add(fullscreenTimer, forMode: .common)
        // 设置改动（外观模式切换）立即生效，不等下个 3 秒周期
        NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.applyPanelAppearanceMode()
            self?.applyDesktopPresentationMode()
        }

        hosting.layout()
        panel.setContentSize(hosting.fittingSize)

        restoreCardPanelPosition()

    }

    /// 桌宠使用独立透明窗口，与详情卡片分别保存位置和尺寸。
    /// 这样展开卡片时不会让宠物本身突然缩放或跳位。
    private func buildPetPanel() {
        petHosting = DraggableHostingView(
            rootView: PetView(store: store) { [weak self] in
                self?.togglePetDetails()
            }
        )
        petHosting.wantsLayer = true
        petHosting.layer?.backgroundColor = NSColor.clear.cgColor
        petHosting.contextMenuBuilder = { [weak self] in
            self?.buildPetContextMenu() ?? NSMenu()
        }

        petPanel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 220, height: 270),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        petPanel.identifier = NSUserInterfaceItemIdentifier("AIStatusPetPanel")
        petPanel.contentView = petHosting
        petPanel.backgroundColor = .clear
        petPanel.isOpaque = false
        petPanel.hasShadow = false
        petPanel.hidesOnDeactivate = false
        petPanel.isReleasedWhenClosed = false
        petPanel.isMovableByWindowBackground = true
        petPanel.acceptsMouseMovedEvents = true
        applyWindowLevel(to: petPanel)

        NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification,
            object: petPanel,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            let origin = self.petPanel.frame.origin
            UserDefaults.standard.set(NSStringFromPoint(origin), forKey: "petOrigin")
            if self.petDetailsExpanded && self.desktopPresentationMode == "pet" {
                self.positionDetailsPanelNextToPet()
            }
        }

        petHosting.layout()
        petPanel.setContentSize(petHosting.fittingSize)
        restoreWindowPosition(petPanel, key: "petOrigin") { screen, size in
            NSPoint(
                x: screen.visibleFrame.maxX - size.width - 24,
                y: screen.visibleFrame.minY + 24
            )
        }
    }

    private func restoreWindowPosition(
        _ window: NSWindow,
        key: String,
        defaultOrigin: (NSScreen, NSSize) -> NSPoint
    ) {
        guard let fallbackScreen = NSScreen.main ?? NSScreen.screens.first else { return }
        let saved = UserDefaults.standard.string(forKey: key).map(NSPointFromString)
        let requested = saved ?? defaultOrigin(fallbackScreen, window.frame.size)
        let requestedFrame = NSRect(origin: requested, size: window.frame.size)
        let screen = NSScreen.screens.first(where: { $0.visibleFrame.intersects(requestedFrame) })
            ?? fallbackScreen
        let visible = screen.visibleFrame
        let maxX = max(visible.minX, visible.maxX - window.frame.width)
        let maxY = max(visible.minY, visible.maxY - window.frame.height)
        let clamped = NSPoint(
            x: min(max(requested.x, visible.minX), maxX),
            y: min(max(requested.y, visible.minY), maxY)
        )
        window.setFrameOrigin(clamped)
    }

    private func restoreCardPanelPosition() {
        guard panel != nil else { return }
        restoreWindowPosition(panel, key: "panelOrigin") { screen, size in
            NSPoint(
                x: screen.visibleFrame.minX + 24,
                y: screen.visibleFrame.maxY - size.height - 24
            )
        }
    }

    /// 桌宠模式的详情卡优先放在宠物右侧，空间不足时自动换到左侧，
    /// 并始终限制在宠物所在屏幕的可见区域内。
    private func positionDetailsPanelNextToPet() {
        guard let panel, let petPanel else { return }
        let petFrame = petPanel.frame
        let screen = NSScreen.screens.first(where: { $0.visibleFrame.intersects(petFrame) })
            ?? NSScreen.main
            ?? NSScreen.screens.first
        guard let screen else { return }

        let visible = screen.visibleFrame
        let size = panel.frame.size
        let gap: CGFloat = 14
        let rightX = petFrame.maxX + gap
        let leftX = petFrame.minX - size.width - gap
        let rightFits = rightX + size.width <= visible.maxX
        let leftFits = leftX >= visible.minX

        let requestedX: CGFloat
        if rightFits {
            requestedX = rightX
        } else if leftFits {
            requestedX = leftX
        } else {
            let rightSpace = visible.maxX - petFrame.maxX
            let leftSpace = petFrame.minX - visible.minX
            requestedX = rightSpace >= leftSpace ? rightX : leftX
        }

        let maxX = max(visible.minX, visible.maxX - size.width)
        let maxY = max(visible.minY, visible.maxY - size.height)
        let origin = NSPoint(
            x: min(max(requestedX, visible.minX), maxX),
            y: min(max(petFrame.midY - size.height / 2, visible.minY), maxY)
        )
        panel.setFrameOrigin(origin)
        applyPanelAppearanceMode()
    }

    private var desktopPresentationMode: String {
        let defaults = UserDefaults.standard
        if let mode = defaults.string(forKey: "desktopPresentationMode"),
           ["card", "pet", "hidden"].contains(mode) {
            return mode
        }
        // 旧版只有 panelVisible；首次升级时保留用户原来的显示选择。
        let legacyVisible = defaults.object(forKey: "panelVisible") == nil
            ? true : defaults.bool(forKey: "panelVisible")
        let migrated = legacyVisible ? "card" : "hidden"
        defaults.set(migrated, forKey: "desktopPresentationMode")
        return migrated
    }

    private func setDesktopPresentationMode(_ mode: String) {
        UserDefaults.standard.set(mode, forKey: "desktopPresentationMode")
        applyDesktopPresentationMode()
    }

    private func applyWindowLevel(to window: NSPanel) {
        let pinned = UserDefaults.standard.object(forKey: "panelPinned") == nil
            ? true : UserDefaults.standard.bool(forKey: "panelPinned")
        window.isFloatingPanel = pinned
        window.level = pinned ? .floating : .normal
        window.collectionBehavior = pinned ? [.canJoinAllSpaces, .fullScreenAuxiliary] : []
    }

    private func hideDesktopWindows() {
        panel?.orderOut(nil)
        petPanel?.orderOut(nil)
    }

    private func applyDesktopPresentationMode() {
        guard panel != nil, petPanel != nil else { return }
        let mode = desktopPresentationMode
        let visible = mode != "hidden"
        if (UserDefaults.standard.object(forKey: "panelVisible") as? Bool) != visible {
            UserDefaults.standard.set(visible, forKey: "panelVisible")
        }
        guard !fullscreenAutoHidden else {
            hideDesktopWindows()
            return
        }
        switch mode {
        case "pet":
            petPanel.orderFront(nil)
            if petDetailsExpanded {
                positionDetailsPanelNextToPet()
                panel.orderFront(nil)
            } else {
                panel.orderOut(nil)
            }
        case "hidden":
            petDetailsExpanded = false
            hideDesktopWindows()
        default:
            petDetailsExpanded = false
            petPanel.orderOut(nil)
            restoreCardPanelPosition()
            panel.orderFront(nil)
        }
    }

    @objc private func selectCardMode() { setDesktopPresentationMode("card") }
    @objc private func selectPetMode() { setDesktopPresentationMode("pet") }
    @objc private func selectHiddenMode() { setDesktopPresentationMode("hidden") }

    @objc private func togglePetDetails() {
        guard desktopPresentationMode == "pet" else { return }
        petDetailsExpanded.toggle()
        if petDetailsExpanded {
            positionDetailsPanelNextToPet()
            panel.orderFront(nil)
        } else {
            panel.orderOut(nil)
        }
    }

    @objc private func openSettings() {
        if settingsWindow == nil {
            let w = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 470, height: 640),
                styleMask: [.titled, .closable, .fullSizeContentView],
                backing: .buffered, defer: false)
            w.title = "灵眸 设置"
            w.titlebarAppearsTransparent = true
            w.titleVisibility = .hidden
            w.isMovableByWindowBackground = true
            w.contentView = NSHostingView(rootView: SettingsView(store: store, settings: settings))
            w.isReleasedWhenClosed = false
            w.center()
            settingsWindow = w
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    @objc private func togglePin() {
        let current = UserDefaults.standard.object(forKey: "panelPinned") == nil
            ? true : UserDefaults.standard.bool(forKey: "panelPinned")
        let pinned = !current
        UserDefaults.standard.set(pinned, forKey: "panelPinned")
        applyWindowLevel(to: panel)
        applyWindowLevel(to: petPanel)
        if pinned {
            applyDesktopPresentationMode()  // 置顶时顺手提到最前，避免找不到
        }
    }

    // MARK: 全屏自动隐藏

    /// 「全屏时自动隐藏」开关（默认开启），与 panelPinned 一致存 UserDefaults
    private var autoHideInFullscreenEnabled: Bool {
        UserDefaults.standard.object(forKey: "panelAutoHideFullscreen") == nil
            ? true : UserDefaults.standard.bool(forKey: "panelAutoHideFullscreen")
    }

    /// 面板所在屏幕的最前台窗口是否全屏：原生全屏（游戏、⌃⌘F）与浏览器网页全屏（看视频）的
    /// 窗口 bounds 都会覆盖整屏（含菜单栏区域），普通最大化窗口只占 visibleFrame 不会命中。
    /// 只读 layer/bounds/PID、不读窗口标题，无需屏幕录制或辅助功能授权。
    private func panelScreenHasFullscreenApp() -> Bool {
        let referenceFrame = desktopPresentationMode == "pet" ? petPanel?.frame : panel?.frame
        guard desktopPresentationMode != "hidden",
              let panelFrame = referenceFrame,
              let target = (NSScreen.screens.first { $0.frame.intersects(panelFrame) } ?? NSScreen.main)?.frame,
              let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                    kCGNullWindowID) as? [[String: Any]]
        else { return false }
        let myPID = Int(ProcessInfo.processInfo.processIdentifier)
        // 列表按前到后排序，只判定第一个非本进程的普通窗口：后台恰好等于全屏尺寸的
        // 窗口（如虚拟显示器控制窗）不能当成全屏
        for info in list {
            guard let layer = info[kCGWindowLayer as String] as? Int, layer == 0 else { continue }
            guard let ownerPID = info[kCGWindowOwnerPID as String] as? Int, ownerPID != myPID else { continue }
            guard let bounds = info[kCGWindowBounds as String] as? NSDictionary,
                  let frame = CGRect(dictionaryRepresentation: bounds) else { continue }
            // 覆盖整屏即判定全屏（±2pt 容差）；多显示器时只认面板所在的那块屏
            return frame.minX <= target.minX + 2 && frame.minY <= target.minY + 2
                && frame.maxX >= target.maxX - 2 && frame.maxY >= target.maxY - 2
        }
        return false
    }

    /// 全屏状态机：进全屏隐藏（不动桌面显示偏好），退全屏按原偏好恢复；
    /// 用户手动显示优先，不与用户抢
    private func updateFullscreenAutoHide() {
        guard panel != nil, petPanel != nil else { return }
        guard autoHideInFullscreenEnabled else {
            // 开关刚被关掉：撤销仍在生效的自动隐藏，回到永远置顶的旧行为
            fullscreenAutoHideSuppressed = false
            if fullscreenAutoHidden {
                fullscreenAutoHidden = false
                applyDesktopPresentationMode()
            }
            return
        }
        if panelScreenHasFullscreenApp() {
            if (panel.isVisible || petPanel.isVisible) && !fullscreenAutoHideSuppressed {
                fullscreenAutoHidden = true
                hideDesktopWindows()
            }
        } else {
            fullscreenAutoHideSuppressed = false
            if fullscreenAutoHidden {
                fullscreenAutoHidden = false
                applyDesktopPresentationMode()
            }
        }
    }

    @objc private func toggleAutoHideFullscreen() {
        UserDefaults.standard.set(!autoHideInFullscreenEnabled, forKey: "panelAutoHideFullscreen")
        updateFullscreenAutoHide()  // 立即生效：打开且正处全屏马上隐藏，关掉立即恢复
    }

    /// 构建桌面浮窗右键菜单（置顶切换 + 设置 + 退出）。复用 togglePin()/openSettings() 动作，
    /// 与菜单栏下拉的"置顶桌面卡片"、"设置…"项保持同一套逻辑。
    private func buildPanelContextMenu() -> NSMenu {
        let menu = NSMenu()
        if desktopPresentationMode == "pet" {
            let collapseItem = NSMenuItem(
                title: "收起详情卡片",
                action: #selector(togglePetDetails),
                keyEquivalent: "")
            collapseItem.target = self
            menu.addItem(collapseItem)
        } else {
            let petItem = NSMenuItem(
                title: "切换到桌面宠物",
                action: #selector(selectPetMode),
                keyEquivalent: "")
            petItem.target = self
            menu.addItem(petItem)
        }
        menu.addItem(.separator())
        let pinned = UserDefaults.standard.object(forKey: "panelPinned") == nil
            ? true : UserDefaults.standard.bool(forKey: "panelPinned")
        let pinItem = NSMenuItem(
            title: pinned ? "取消置顶" : "置顶",
            action: #selector(togglePin),
            keyEquivalent: "")
        pinItem.target = self
        menu.addItem(pinItem)
        let autoHideItem = NSMenuItem(
            title: "全屏时自动隐藏",
            action: #selector(toggleAutoHideFullscreen),
            keyEquivalent: "")
        autoHideItem.target = self
        autoHideItem.state = autoHideInFullscreenEnabled ? .on : .off
        menu.addItem(autoHideItem)
        let settingsItem = NSMenuItem(
            title: "设置…",
            action: #selector(openSettings),
            keyEquivalent: "")
        settingsItem.target = self
        menu.addItem(settingsItem)
        menu.addItem(.separator())
        let quitItem = NSMenuItem(
            title: "退出灵眸",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "")
        quitItem.target = NSApp
        menu.addItem(quitItem)
        return menu
    }

    private func buildPetContextMenu() -> NSMenu {
        let menu = NSMenu()
        let detailsItem = NSMenuItem(
            title: petDetailsExpanded ? "收起详情卡片" : "展开详情卡片",
            action: #selector(togglePetDetails),
            keyEquivalent: "")
        detailsItem.target = self
        menu.addItem(detailsItem)
        let cardItem = NSMenuItem(
            title: "切换到桌面卡片",
            action: #selector(selectCardMode),
            keyEquivalent: "")
        cardItem.target = self
        menu.addItem(cardItem)
        menu.addItem(.separator())

        let pinned = UserDefaults.standard.object(forKey: "panelPinned") == nil
            ? true : UserDefaults.standard.bool(forKey: "panelPinned")
        let pinItem = NSMenuItem(
            title: pinned ? "取消置顶" : "置顶",
            action: #selector(togglePin),
            keyEquivalent: "")
        pinItem.target = self
        menu.addItem(pinItem)
        let autoHideItem = NSMenuItem(
            title: "全屏时自动隐藏",
            action: #selector(toggleAutoHideFullscreen),
            keyEquivalent: "")
        autoHideItem.target = self
        autoHideItem.state = autoHideInFullscreenEnabled ? .on : .off
        menu.addItem(autoHideItem)
        let settingsItem = NSMenuItem(
            title: "设置…",
            action: #selector(openSettings),
            keyEquivalent: "")
        settingsItem.target = self
        menu.addItem(settingsItem)
        let hideItem = NSMenuItem(
            title: "隐藏桌面显示",
            action: #selector(selectHiddenMode),
            keyEquivalent: "")
        hideItem.target = self
        menu.addItem(hideItem)
        menu.addItem(.separator())
        let quitItem = NSMenuItem(
            title: "退出灵眸",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "")
        quitItem.target = NSApp
        menu.addItem(quitItem)
        return menu
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
