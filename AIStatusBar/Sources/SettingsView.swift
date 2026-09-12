import Cocoa
import SwiftUI
import UserNotifications

// 设置窗口内容（SettingsView，macOS 26 风格：隐藏标题栏 + 卡片分组）。

// MARK: - 设置窗口（macOS 26 风格：隐藏标题栏 + 卡片分组）

struct SettingsView: View {
    @ObservedObject var store: StatusStore  // 同步来源状态来自最新一次采集
    @ObservedObject var settings: SettingsStore
    @ObservedObject var catalog: PetCatalog
    @State private var showOnlineQuotaAlert = false
    @State private var showKimiDecryptAlert = false
    @State private var showAdaptiveAlert = false
    @State private var perToolBusyExpanded = false
    @State private var advancedExpanded = false
    @StateObject private var maintenance = MaintenanceStore()
    /// 系统级通知授权状态（设置窗口打开通知页时查询，用于提示"被系统拒绝"的情况）
    @State private var notifyAuth: UNAuthorizationStatus = .notDetermined
    @AppStorage("desktopPresentationMode") private var desktopPresentationMode = "card"
    @AppStorage("panelAppearanceMode") private var appearanceMode = "system"
    @AppStorage("floatingBallAppearance") private var ballAppearance = "blue"
    @AppStorage("settingsTab") private var settingsTab = "general"

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
        VStack(spacing: 0) {
            header
            tabBar
            Divider().opacity(0.4)
            switch settingsTab {
            case "pet":
                PetSettingsTab(settings: settings, catalog: catalog)
            case "models":
                settingsScroll {
                    Text("模型用量已移到看板的“用量”页。")
                    Button("查看模型用量") {
                        UserDefaults.standard.set("models", forKey: "usageBreakdown")
                        (NSApp.delegate as? AppDelegate)?.showTaskPanel(tab: "usage")
                    }
                }
            case "connections":
                settingsScroll { ConnectionDiagnosticsView(store: store) }
            case "welcome":
                settingsScroll { welcomeSection }
            case "data":
                settingsScroll { dataSection; eventInterfaceSection }
            case "notify":
                settingsScroll {
                    notifySection
                    notificationControlsSection
                    quotaAlertsSection
                }
            default:
                settingsScroll {
                    appearanceSection
                    maintenanceSection
                    DisclosureGroup("高级状态判定", isExpanded: $advancedExpanded) {
                        statusSection.padding(.top, 10)
                    }
                    .font(.system(size: 12, weight: .medium))
                }
            }
        }
        .frame(width: 470)
    }

    /// 顶部标签栏：与设置行（12.5pt 标题）同比例，避免照搬状态面板的紧凑样式后显得过小。
    private var tabBar: some View {
        HStack(spacing: 6) {
            tabButton("通用", "general")
            tabButton("桌宠", "pet")
            tabButton("数据", "data")
            tabButton("通知", "notify")
            tabButton("连接", "connections")
            Spacer()
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 12)
    }

    private func tabButton(_ title: String, _ id: String) -> some View {
        Button(action: { settingsTab = id }) {
            Text(title)
                .font(.system(size: 12.5, weight: settingsTab == id ? .semibold : .regular))
                .foregroundColor(settingsTab == id ? Color.primary : Color.secondary)
                .padding(.horizontal, 13)
                .padding(.vertical, 6)
                .background(
                    Capsule().fill(
                        settingsTab == id ? Color.primary.opacity(0.16) : Color.primary.opacity(0.06)
                    )
                )
        }
        .buttonStyle(.plain)
    }

    private func settingsScroll<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                content()
                Spacer(minLength: 2)
            }
            .padding(.horizontal, 24)
            .padding(.top, 16)
            .padding(.bottom, 20)
        }
    }

    private var statusSection: some View {
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
    }

    private var appearanceSection: some View {
        section("外观") {
            settingRow("桌面显示", detail: "桌宠会根据 AI 工具状态切换动作") {
                modePicker($desktopPresentationMode, options: [
                    ("桌面卡片", "card"), ("桌面宠物", "pet"), ("隐藏", "hidden"),
                ])
            }
            divider
            settingRow("浮球风格", detail: "看板收起时的圆球形象") {
                HStack(spacing: 6) {
                    FloatingBallArtwork(mood: .idle, gaze: .zero, hovered: false, reduceMotion: true,
                                        appearance: FloatingBallAppearance(rawValue: ballAppearance) ?? .blue)
                        .scaleEffect(0.5)
                        .frame(width: 32, height: 32)
                        .accessibilityHidden(true)
                    modePicker($ballAppearance, options: FloatingBallAppearance.allCases.map { ($0.title, $0.rawValue) })
                }
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
            settingRow("演示模式", detail: "隐藏看板、桌宠和通知中的任务标题，并移除已有通知预览") {
                toggle($settings.experience.privacyMode)
            }
            divider
            settingRow("数量单位", detail: "用量数字按 K/M/B 或 万/亿 显示") {
                modePicker($settings.numberUnit, options: [
                    ("K / M / B", "metric"), ("万 / 亿", "wan"),
                ])
            }
            divider
            settingRow("在 Dock 中显示图标", detail: "默认仅驻留菜单栏") {
                toggle($settings.showDockIcon)
            }
        }
    }

    private var dataSection: some View {
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
            if settings.onlineQuota {
                settingRow(
                    "读取 Kimi 月度额度",
                    detail: "连接后自动更新月度额度；后台不会弹出钥匙串窗口"
                ) {
                    toggle(kimiTokenDecryptBinding)
                        .disabled(store.isAuthorizingKimi)
                }
                .alert("连接 Kimi 月度额度？", isPresented: $showKimiDecryptAlert) {
                    Button("取消", role: .cancel) {}
                    Button("连接并开启") { store.authorizeKimiCredentials() }
                } message: {
                    Text("灵眸需要读取钥匙串“kimi-desktop Safe Storage”来解密 Kimi 登录凭证。本次连接最多等待 60 秒；拒绝或超时后不会自动重试。“始终允许”可让系统记住授权。之后后台只使用已有权限，权限失效时显示提示。口令只用于本机解密，不会外传。")
                }
                if store.isAuthorizingKimi {
                    settingRow("等待钥匙串授权", detail: store.kimiAuthorizationMessage ?? "") {
                        Button("取消请求") { store.cancelKimiAuthorization() }
                    }
                } else if let message = store.kimiAuthorizationMessage {
                    Text(message).font(.system(size: 11)).foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            divider
            settingRow("用量同步", detail: "多台设备共用一个目录（默认 iCloud Drive）汇总用量与活跃") {
                toggle($settings.usageSyncEnabled)
            }
            if settings.usageSyncEnabled {
                syncDetail
            }
        }
    }

    private var eventInterfaceSection: some View {
        section("本地事件接口") {
            settingRow("允许本机脚本订阅", detail: "默认关闭；仅导出开启后观测到的新事件，灵眸需保持运行") {
                toggle($settings.experience.eventExport)
            }
            if settings.experience.eventExport {
                divider
                settingRow("包含任务标题", detail: "默认只含工具、会话标识、时间与状态；演示模式始终隐藏标题") {
                    toggle($settings.experience.eventExportTitles)
                }
            }
            divider
            settingRow("快捷指令与 Raycast", detail: "本机轮询接口；不启动网络服务，也不自动执行命令") {
                Button("接入指南") {
                    if let url = Bundle.main.url(forResource: "LOCAL_EVENTS", withExtension: "md", subdirectory: "Guides") {
                        NSWorkspace.shared.open(url)
                    }
                }
            }
            if let error = store.integrationError {
                Text(error).font(.system(size: 11)).foregroundColor(.orange).padding(12)
            }
        }
    }

    private var welcomeSection: some View {
        VStack(alignment: .leading, spacing: 20) {
            Image(systemName: "eye").font(.system(size: 34, weight: .light)).foregroundColor(.accentColor)
            Text("让 AI 在一旁工作").font(.custom("PingFangSC-Semibold", size: 23))
            Text("灵眸会观察本机 AI 工具，在需要你接手时提醒你。")
                .font(.system(size: 13)).foregroundColor(.secondary)
            section("三步开始") {
                guideRow("1", "打开你的 AI 工具", "开始一个任务，运行状态会自动出现在灵眸中。")
                divider
                guideRow("2", "选择喜欢的显示方式", "使用桌面卡片、浮球或桌宠，也可以只保留菜单栏。")
                divider
                guideRow("3", "按需开启提醒", "通知默认关闭；启用后才会申请系统通知权限。")
            }
            let detected = store.data?.tools.filter { $0.health?.state != "not_detected" } ?? []
            Text(detected.isEmpty ? "还没有发现本地工具，打开一个 AI 工具后再试试。" :
                 "已发现：\(detected.map(\.name).joined(separator: "、"))")
                .font(.system(size: 11)).foregroundColor(.secondary)
            HStack {
                Button("查看连接") { settingsTab = "connections" }
                Spacer()
                Button("开始使用") {
                    settings.experience.onboardingCompleted = true
                    settingsTab = "general"
                    (NSApp.delegate as? AppDelegate)?.showTaskPanel()
                }.keyboardShortcut(.defaultAction)
            }
        }
    }

    private func guideRow(_ number: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(number).font(.custom("AvenirNext-DemiBold", size: 16)).foregroundColor(.accentColor)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 12, weight: .semibold))
                Text(detail).font(.system(size: 11)).foregroundColor(.secondary)
            }
            Spacer()
        }.padding(14)
    }

    private var maintenanceSection: some View {
        section("启动与更新") {
            settingRow("登录时启动", detail: maintenance.loginMessage) {
                Toggle("", isOn: Binding(get: { maintenance.loginEnabled },
                                         set: { maintenance.setLoginEnabled($0) }))
                    .labelsHidden().toggleStyle(.switch)
            }
            if maintenance.loginMessage.contains("系统设置") {
                settingRow("系统登录项") { Button("打开") { maintenance.openLoginSettings() } }
            }
            divider
            settingRow("检查更新", detail: maintenance.updateMessage) {
                Button(maintenance.checking ? "检查中…" : "检查") { maintenance.checkUpdates() }
                    .disabled(maintenance.checking)
            }
            if let url = maintenance.releaseURL {
                settingRow("正式发布与下载", detail: "从项目 GitHub 发布页获取安装包") {
                    Button("打开发布页") { NSWorkspace.shared.open(url) }
                }
            }
            divider
            settingRow("使用指南") { Button("查看") { settingsTab = "welcome" } }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            maintenance.refreshLoginState()
        }
    }

    private var notificationControlsSection: some View {
        section("提醒方式") {
            settingRow("合并相近提醒", detail: "将短时间内的更新合成一条；等待你处理的事件优先提醒") {
                toggle($settings.experience.mergeNotifications)
            }
            divider
            settingRow("暂时静音", detail: settings.experience.muteUntil > Date().timeIntervalSince1970
                       ? "任务和配额提醒已静音，事件仍会记录在本机"
                       : "暂停任务和配额提醒，保留事件记录") {
                Menu(settings.experience.muteUntil > Date().timeIntervalSince1970 ? "静音中" : "选择时长") {
                    Button("15 分钟") { settings.experience.muteUntil = Date().timeIntervalSince1970 + 900 }
                    Button("1 小时") { settings.experience.muteUntil = Date().timeIntervalSince1970 + 3_600 }
                    Button("4 小时") { settings.experience.muteUntil = Date().timeIntervalSince1970 + 14_400 }
                    Divider()
                    Button("恢复提醒") { settings.experience.muteUntil = 0 }
                }
            }
        }
    }

    private var quotaAlertsSection: some View {
        section("配额提醒") {
            settingRow("配额不足时提醒", detail: "仅使用仍有效的配额数据，同一账号窗口只提醒一次") {
                toggle($settings.experience.quotaAlerts)
            }
            if settings.experience.quotaAlerts {
                divider
                settingRow("剩余配额阈值") {
                    Picker("", selection: $settings.experience.quotaThreshold) {
                        ForEach([10, 20, 30, 50], id: \.self) { value in Text("\(value)%").tag(value) }
                    }.labelsHidden()
                }
                divider
                settingRow("配额恢复时提醒", detail: "已触及阈值的配额恢复后提醒一次") {
                    toggle($settings.experience.quotaRecovery)
                }
            }
        }
    }

    private var notifySection: some View {
        section("通知") {
            settingRow("任务更新提醒", detail: "提醒本轮结束、中断和等待回答；无活动时仅作保守提示") {
                toggle($settings.notifyEnabled)
            }
            if settings.notifyEnabled {
                notifyToolsGrid
                divider
                if notifyAuth == .denied {
                    settingRow("系统通知权限已关闭",
                               detail: "macOS 拒绝了灵眸的通知权限，通知不会弹出，需要在系统设置中打开") {
                        Button("打开系统设置") {
                            NSWorkspace.shared.open(
                                URL(string: "x-apple.systempreferences:com.apple.preference.notifications")!)
                        }
                    }
                    divider
                }
                settingRow("测试通知",
                           detail: notifyAuth == .authorized
                               ? "立即发送一条测试横幅，验证通知通道"
                               : "发送前会先向系统请求通知授权") {
                    Button("发送") { sendTestNotification() }
                }
            }
        }
        .onAppear { refreshNotifyAuth() }
        .onChange(of: settings.notifyEnabled) { _ in refreshNotifyAuth() }
        // 用户去系统设置改完授权后回到本窗口，App 重新激活时刷新状态行
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshNotifyAuth()
        }
    }

    // MARK: 通知系统授权

    private func refreshNotifyAuth() {
        UNUserNotificationCenter.current().getNotificationSettings { s in
            DispatchQueue.main.async { notifyAuth = s.authorizationStatus }
        }
    }

    /// 测试通知：未请求过授权先请求，已允许则直接发一条横幅，被拒则只刷新状态行
    private func sendTestNotification() {
        UNUserNotificationCenter.current().getNotificationSettings { s in
            switch s.authorizationStatus {
            case .notDetermined:
                UNUserNotificationCenter.current().requestAuthorization(
                    options: [.alert, .sound]
                ) { granted, _ in
                    DispatchQueue.main.async {
                        refreshNotifyAuth()
                        if granted { postTestNotification() }
                    }
                }
            case .authorized, .provisional, .ephemeral:
                DispatchQueue.main.async { postTestNotification() }
            default:
                DispatchQueue.main.async { refreshNotifyAuth() }
            }
        }
    }

    private func postTestNotification() {
        let content = UNMutableNotificationContent()
        content.title = "灵眸测试通知"
        content.body = "通知通道正常，任务状态更新时会这样提醒你。"
        content.sound = .default
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        ) { error in
            if let error { NSLog("灵眸：测试通知投递失败：\(error.localizedDescription)") }
        }
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
        .padding(.bottom, 12)
        .padding(.horizontal, 24)
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
                                     ? "\(ExperienceFormat.age(source.updatedAt)) · \(source.days) 天"
                                     : "尚未导出")
                                    .font(.system(size: 10).monospacedDigit())
                                    .foregroundColor(Date().timeIntervalSince1970 - source.updatedAt > 3_600 ? .orange : .secondary)
                            }
                        }
                    }
                    .padding(.top, 2)
                } else {
                    Text("同步目录暂不可用或尚未导出，当前显示本机统计。请检查目录与网盘状态。")
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

    /// 首次开启需说明钥匙串授权；关闭直接生效。
    private var kimiTokenDecryptBinding: Binding<Bool> {
        Binding(
            get: { settings.kimiTokenDecrypt },
            set: { enabled in
                if enabled { showKimiDecryptAlert = true }
                else { settings.kimiTokenDecrypt = false; store.refresh() }
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

/// 用量条目合计（输入+缓存+输出）；nil 视为 0
private func modelUsageTotal(_ entry: UsageEntry?) -> Int {
    guard let entry else { return 0 }
    return entry.input + entry.output + entry.cache
}
