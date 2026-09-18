import Cocoa
import SwiftUI

private struct PanelContentHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

/// 短内容自然收高，长内容才滚动，避免按条数猜高度产生大片留白。
struct FittedPanelScrollView<Content: View>: View {
    var maxHeight: CGFloat = 320
    @ViewBuilder let content: Content
    @State private var contentHeight: CGFloat = 120

    var body: some View {
        ScrollView {
            content
                .fixedSize(horizontal: false, vertical: true)
                .background(GeometryReader { geometry in
                    Color.clear.preference(key: PanelContentHeightKey.self, value: geometry.size.height)
                })
        }
        .frame(height: min(maxHeight, max(1, contentHeight)))
        .onPreferenceChange(PanelContentHeightKey.self) { height in
            guard height > 0, abs(contentHeight - height) > 0.5 else { return }
            contentHeight = height
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .statusUpdated, object: nil)
            }
        }
    }
}

enum ExperienceFormat {
    static func age(_ timestamp: TimeInterval, now: TimeInterval = Date().timeIntervalSince1970) -> String {
        guard timestamp > 0 else { return "尚未更新" }
        let seconds = max(0, Int(now - timestamp))
        if seconds < 60 { return "刚刚" }
        if seconds < 3_600 { return "\(seconds / 60) 分钟前" }
        if seconds < 86_400 { return "\(seconds / 3_600) 小时前" }
        let formatter = DateFormatter()
        formatter.dateFormat = "M月d日 HH:mm"
        return formatter.string(from: Date(timeIntervalSince1970: timestamp))
    }

    static func quotaState(_ state: String?) -> String {
        switch state {
        case "ready": return "配额读取正常"
        case "local": return "来自本地记录"
        case "stale": return "数据已过期或暂时无法更新"
        case "disabled": return "联网配额已关闭"
        case "login_required": return "需要在原工具登录"
        case "unsupported": return "暂不支持账号配额"
        default: return "暂无法获取，请检查原工具登录与网络"
        }
    }
}

struct FreshnessView: View {
    let timestamp: TimeInterval?
    var maxAge: TimeInterval = 45
    var staleLabel = "上次更新"
    var body: some View {
        TimelineView(.periodic(from: .now, by: 10)) { context in
            let age = context.date.timeIntervalSince1970 - (timestamp ?? 0)
            Text(timestamp == nil ? "正在读取状态" :
                 "\(age > maxAge ? staleLabel : "更新于") \(ExperienceFormat.age(timestamp ?? 0, now: context.date.timeIntervalSince1970))")
                .font(.system(size: 10).monospacedDigit())
                .foregroundColor(age > maxAge && timestamp != nil ? .orange : .secondary)
        }
    }
}

struct ToolsConnectionsView<ToolSettings: View>: View {
    @ObservedObject var store: StatusStore
    @ViewBuilder var toolSettings: (String) -> ToolSettings
    @State private var copied = false

    private var groups: [(key: String, name: String)] {
        let known = SettingsStore.tools.map { (key: $0.0, name: $0.1) }
        let extra = (store.data?.tools ?? []).filter { tool in
            !["codex-ide", "codex-cli"].contains(tool.key)
                && !known.contains(where: { $0.key == tool.key })
        }.map { (key: $0.key, name: $0.name) }
        return known + extra
    }

    private func tools(for key: String) -> [ToolStatus] {
        (store.data?.tools ?? []).filter {
            key == "codex" ? ["codex-ide", "codex-cli"].contains($0.key) : $0.key == key
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("工具设置与状态").font(.system(size: 15, weight: .semibold))
                    FreshnessView(timestamp: store.lastCollectedAt)
                }
                Spacer()
                Button("刷新") { store.refresh() }
                Button(copied ? "已复制" : "复制诊断") { copyReport() }
            }
            if let error = store.collectorError {
                Label(error, systemImage: "exclamationmark.triangle").foregroundColor(.orange)
            }
            if let error = store.historyError {
                Label(error, systemImage: "internaldrive").foregroundColor(.orange)
            }
            if let error = store.integrationError ?? store.quotaError {
                Label(error, systemImage: "internaldrive").foregroundColor(.orange)
            }
            ForEach(groups, id: \.key) { group in
                VStack(alignment: .leading, spacing: 7) {
                    Text(group.name)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.secondary.opacity(0.9))
                        .padding(.leading, 2)
                    VStack(spacing: 0) {
                        let statuses = tools(for: group.key)
                        if statuses.isEmpty {
                            Text("尚未读取到本地状态")
                                .font(.system(size: 11)).foregroundColor(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading).padding(14)
                        } else {
                            ForEach(statuses, id: \.key) { tool in
                                diagnostics(for: tool, showName: statuses.count > 1)
                            }
                        }
                        if SettingsStore.tools.contains(where: { $0.0 == group.key }) {
                            Divider().padding(.leading, 14).opacity(0.5)
                        }
                        toolSettings(group.key)
                    }
                    .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.045)))
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.primary.opacity(0.07), lineWidth: 0.5))
                }
            }
            Text("诊断内容仅含工具名、支持能力、状态与时间，不包含任务标题、会话正文、凭证或个人路径。")
                .font(.system(size: 10)).foregroundColor(.secondary)
        }
    }

    private func diagnostics(for tool: ToolStatus, showName: Bool) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .top, spacing: 8) {
                Circle().fill(tool.health?.state == "error" ? Color.orange :
                              tool.health?.state == "ready" ? Color.green : Color.secondary.opacity(0.5))
                    .frame(width: 6, height: 6).padding(.top, 4)
                VStack(alignment: .leading, spacing: 3) {
                    if showName { Text(tool.name).font(.system(size: 12, weight: .medium)) }
                    Text(tool.health?.message ?? "当前采集器未提供诊断信息，请更新灵眸")
                        .font(.system(size: 11)).foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 4)
                if NotificationRouter.supportsApplicationNavigation(forToolKey: tool.key) {
                    Button("打开工具") { NotificationRouter.openDestination(forToolKey: tool.key) }
                        .controlSize(.small).help(NotificationRouter.destinationLabel(forToolKey: tool.key))
                }
            }
            DisclosureGroup("诊断详情") {
                VStack(alignment: .leading, spacing: 5) {
                    Text("任务事件：\(phaseDescription(tool.capabilities?.eventPhases ?? []))")
                    Text("\(NotificationRouter.destinationLabel(forToolKey: tool.key)) · \(ExperienceFormat.quotaState(tool.health?.quotaState))")
                    if let timestamp = tool.health?.sourceUpdatedAt {
                        Text("最近本地活动：\(ExperienceFormat.age(timestamp))")
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true).padding(.top, 5)
            }
            .font(.system(size: 10)).foregroundColor(.secondary)
        }.padding(14)
    }

    private func phaseDescription(_ phases: [String]) -> String {
        let labels = ["ended": "本轮结束", "interrupted": "中断", "waiting_input": "等待回答",
                      "waiting_permission": "等待确认", "failed": "异常"]
        let result = phases.compactMap { labels[$0] }.joined(separator: "、")
        return result.isEmpty ? "活动状态；暂无明确结束或等待信号" : result
    }

    private func copyReport() {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
        var rows = ["灵眸 \(version)", "采集状态：\(store.collectorError == nil ? "可用" : "失败")"]
        for tool in store.data?.tools ?? [] {
            rows.append("\(tool.key): \(tool.health?.state ?? "unknown"), quota=\(tool.health?.quotaState ?? "unknown"), events=\((tool.capabilities?.eventPhases ?? []).joined(separator: ","))")
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(rows.joined(separator: "\n"), forType: .string)
        copied = true
    }
}
