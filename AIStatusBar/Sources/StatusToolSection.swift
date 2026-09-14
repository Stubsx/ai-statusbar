import Cocoa
import SwiftUI

/// 状态速览和运行详情共用同一套目标与交互；应用入口不代选第一条会话。
struct StatusToolSection: View {
    let tool: ToolStatus
    var kimiWebAvailable = false
    var detailed = false
    let displayTitle: (String) -> String
    var openDestination: (ToolDestination) -> Void = NotificationRouter.openDestination
    @State private var expanded = false

    private var items: [BusyItem] { tool.activeItems ?? tool.busyItems }
    private var hasSessionLinks: Bool { items.contains { canOpen($0.id) } }
    private var previewLimit: Int { hasSessionLinks ? 3 : 1 }
    private var shownItems: [BusyItem] {
        Array(items.prefix(detailed || (expanded && hasSessionLinks) ? items.count : previewLimit))
    }
    private var stateLabel: String {
        if tool.health?.state == "error" { return "读取异常" }
        switch tool.state {
        case "busy": return "\(max(0, tool.busyCount)) 个运行中"
        case "idle": return "空闲"
        default: return "未运行"
        }
    }

    private func canOpen(_ sessionId: String?) -> Bool {
        NotificationRouter.supportsSessionNavigation(forToolKey: tool.key, sessionId: sessionId,
                                                      kimiWebAvailable: kimiWebAvailable)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            if NotificationRouter.supportsApplicationNavigation(forToolKey: tool.key) {
                Button { openDestination(ToolDestination(toolKey: tool.key)) } label: { header }
                    .buttonStyle(StatusRowButtonStyle())
                    .help(NotificationRouter.destinationLabel(forToolKey: tool.key))
                    .accessibilityIdentifier("status-app-\(tool.key)")
            } else {
                header.padding(.horizontal, 6).padding(.vertical, 4).padding(.trailing, 16)
            }
            ForEach(shownItems, id: \.id) { item in
                sessionRow(title: item.title, sessionId: item.id)
            }
            if !detailed, hasSessionLinks, items.count > previewLimit {
                Button { expanded.toggle() } label: {
                    HStack(spacing: 5) {
                        Image(systemName: expanded ? "chevron.up" : "chevron.down")
                            .font(.system(size: 8, weight: .semibold)).frame(width: 8)
                        Text(expanded ? "收起会话" : "展开其余 \(items.count - previewLimit) 条会话")
                            .font(.system(size: 10))
                        Spacer(minLength: 0)
                    }.foregroundColor(.secondary)
                }
                .buttonStyle(StatusRowButtonStyle(showsArrow: false))
                .padding(.leading, 14)
                .accessibilityIdentifier("status-sessions-toggle-\(tool.key)")
            }
            if items.isEmpty, let title = tool.latestTitle, detailed || canOpen(tool.latestSessionId) {
                sessionRow(title: title, sessionId: tool.latestSessionId, recent: true)
            }
            if detailed, tool.health?.state == "error" {
                Text(tool.health?.message ?? "部分数据不可读")
                    .font(.system(size: 10)).foregroundColor(.orange).padding(.leading, 20)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Circle().fill(tool.health?.state == "error" ? .orange : Color(NSColor.toolStatusColor(tool.state)))
                .frame(width: 6, height: 6)
            Text(tool.name).font(.system(size: 12, weight: .medium)).lineLimit(1)
            Spacer(minLength: 4)
            Text(stateLabel).font(.system(size: 10)).foregroundColor(.secondary).fixedSize()
        }
    }

    @ViewBuilder
    private func sessionRow(title: String, sessionId: String?, recent: Bool = false) -> some View {
        let visibleTitle = displayTitle(title)
        let navigable = canOpen(sessionId)
        Group {
            if navigable {
                Button { openDestination(ToolDestination(toolKey: tool.key, sessionId: sessionId)) } label: {
                    sessionLabel(visibleTitle, recent: recent, navigable: true)
                }
                .buttonStyle(StatusRowButtonStyle())
                .help("\(visibleTitle)\n\(NotificationRouter.destinationLabel(forToolKey: tool.key, sessionId: sessionId))")
                .accessibilityIdentifier("status-session-\(tool.key)-\(sessionId ?? "")")
            } else {
                sessionLabel(visibleTitle, recent: recent, navigable: false)
                    .padding(.trailing, 16).padding(.horizontal, 6).padding(.vertical, 4)
                    .help("\(visibleTitle)\n暂不支持直达会话，可点击工具名称打开应用或宿主")
            }
        }.padding(.leading, 14)
    }

    private func sessionLabel(_ title: String, recent: Bool, navigable: Bool) -> some View {
        HStack(spacing: 6) {
            Image(systemName: recent ? "clock" : "text.bubble")
                .font(.system(size: 9)).foregroundColor(.secondary).frame(width: 10)
            Text(recent ? "最近：\(title)" : title)
                .font(.system(size: 11)).foregroundColor(navigable && !recent ? .primary : .secondary)
                .lineLimit(1).truncationMode(.tail).frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// 只有真正的按钮安装 Hover；箭头始终预留位置，悬停不会挤动标题。
struct StatusRowButtonStyle: ButtonStyle {
    var showsArrow = true

    func makeBody(configuration: Configuration) -> some View {
        StatusRowButtonBody(label: configuration.label, isPressed: configuration.isPressed, showsArrow: showsArrow)
    }
}

private struct StatusRowButtonBody<Label: View>: View {
    let label: Label
    let isPressed: Bool
    let showsArrow: Bool
    @State private var hovered = false

    var body: some View {
        label
            .padding(.trailing, 16)
            .overlay(alignment: .trailing) {
                if showsArrow {
                    Image(systemName: "arrow.up.right").font(.system(size: 9, weight: .medium))
                        .foregroundColor(.accentColor).opacity(hovered || isPressed ? 1 : 0)
                        .accessibilityHidden(true)
                }
            }
            .padding(.horizontal, 6).padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 5).fill(
                Color.accentColor.opacity(isPressed ? 0.16 : (hovered ? 0.09 : 0))))
            .contentShape(Rectangle())
            .onHover { hovered = $0 }
            .onDisappear { hovered = false }
    }
}
