import Cocoa
import SwiftUI

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

struct StatusData: Codable {
    let updatedAt: String
    let tools: [ToolStatus]
}

extension Notification.Name {
    static let statusUpdated = Notification.Name("statusUpdated")
}

// MARK: - 状态采集

final class StatusStore: ObservableObject {
    @Published var data: StatusData?
    let scriptPath: String
    private var timer: Timer?

    init(scriptPath: String) {
        self.scriptPath = scriptPath
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
                NotificationCenter.default.post(name: .statusUpdated, object: nil)
            }
        }
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
                        .stroke(Color.white.opacity(0.08)))
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

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("AI AGENTS")
                    .font(.system(size: 11, weight: .semibold))
                    .tracking(1)
                Spacer()
                Text(store.data?.updatedAt ?? "--:--:--")
                    .font(.system(size: 11, weight: .regular).monospacedDigit())
            }
            .foregroundColor(.white.opacity(0.45))
            .padding(.bottom, 8)

            if let tools = store.data?.tools {
                let visible = tools.filter { $0.state != "off" }  // 未运行的不显示
                if visible.isEmpty {
                    Text("全部未运行")
                        .font(.system(size: 11))
                        .foregroundColor(.white.opacity(0.35))
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
                                .foregroundColor(.white.opacity(0.55))
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
                                .foregroundColor(.white.opacity(0.35))
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
                    .foregroundColor(.white.opacity(0.55))
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 10)
        .frame(width: 300)  // 固定宽度，长标题自动省略号
        .modifier(ConditionalGlass(bare: bare))
        .environment(\.colorScheme, .dark)
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

// MARK: - AppDelegate

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private var panel: NSPanel!
    private var hosting: DraggableHostingView<PanelView>!
    private var store: StatusStore!

    func applicationDidFinishLaunching(_ notification: Notification) {
        let scriptPath = Bundle.main.path(forResource: "ai_status", ofType: "py")
            ?? (NSHomeDirectory() + "/Desktop/未命名文件夹/swiftbar-plugins/ai_status.py")
        store = StatusStore(scriptPath: scriptPath)

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
        let legend = NSMenuItem(title: "C=Codex App  X=Codex CLI  K=Kimi  L=Claude  Z=ZCode", action: nil, keyEquivalent: "")
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
