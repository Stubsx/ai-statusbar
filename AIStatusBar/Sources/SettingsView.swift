import Cocoa
import SwiftUI

// 设置窗口内容（SettingsView，macOS 26 风格：隐藏标题栏 + 卡片分组）。

// MARK: - 设置窗口（macOS 26 风格：隐藏标题栏 + 卡片分组）

struct SettingsView: View {
    @ObservedObject var store: StatusStore  // 同步来源状态来自最新一次采集
    @ObservedObject var settings: SettingsStore
    @ObservedObject var catalog: PetCatalog
    @State private var showOnlineQuotaAlert = false
    @State private var showAdaptiveAlert = false
    @State private var perToolBusyExpanded = false
    @AppStorage("desktopPresentationMode") private var desktopPresentationMode = "card"
    @AppStorage("panelAppearanceMode") private var appearanceMode = "system"
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
            case "data":
                settingsScroll { dataSection }
            case "notify":
                settingsScroll { notifySection }
            default:
                settingsScroll {
                    statusSection
                    appearanceSection
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
            settingRow("用量同步", detail: "多台设备共用一个目录（默认 iCloud Drive）汇总用量与活跃") {
                toggle($settings.usageSyncEnabled)
            }
            if settings.usageSyncEnabled {
                syncDetail
            }
        }
    }

    private var notifySection: some View {
        section("通知") {
            settingRow("任务完成时提醒", detail: "工具从工作中转为空闲时推送") {
                toggle($settings.notifyEnabled)
            }
            if settings.notifyEnabled {
                notifyToolsGrid
            }
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
