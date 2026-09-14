import Cocoa
import SwiftUI

/// 每个 Harness 只展示运行会话与尚未查看的新结果，与状态图标逐条对应。
struct StatusToolSection: View {
    let group: HarnessConversationGroup
    var kimiWebAvailable = false
    let displayTitle: (String) -> String
    var openDestination: (ToolDestination) -> Void = NotificationRouter.openDestination
    let openConversation: (HarnessConversation) -> Void
    private var tool: ToolStatus { group.tool }

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
            ForEach(group.conversations) { conversation in
                sessionRow(conversation)
            }
            if tool.health?.state == "error" {
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
            HStack(spacing: 8) {
                if group.runningCount > 0 {
                    Label("\(group.runningCount)", systemImage: "play.fill")
                }
                if group.attentionCount > 0 {
                    Label("\(group.attentionCount)", systemImage: "bubble.left.fill")
                }
                if group.runningCount == 0 && group.attentionCount == 0 {
                    Text(group.statusLabel)
                }
            }
            .font(.system(size: 10)).foregroundColor(.secondary).fixedSize()
            .accessibilityElement(children: .ignore).accessibilityLabel(group.statusLabel)
        }
    }

    private func statusColor(_ conversation: HarnessConversation) -> Color {
        switch conversation.phase {
        case "working": return .green
        case "waiting_input", "waiting_permission", "failed": return .orange
        default: return .secondary
        }
    }

    private func routeHelp(_ conversation: HarnessConversation) -> String {
        let direct = NotificationRouter.supportsSessionNavigation(forToolKey: tool.key,
            sessionId: conversation.sessionId, kimiWebAvailable: kimiWebAvailable)
        let route = direct
            ? NotificationRouter.destinationLabel(forToolKey: tool.key, sessionId: conversation.sessionId)
            : NotificationRouter.destinationLabel(forToolKey: tool.key)
        let age = conversation.timestamp.map { " · " + ExperienceFormat.age($0) } ?? ""
        return "\(displayTitle(conversation.title))\n\(conversation.label)\(age)\n\(route)"
            + (conversation.needsAttention ? "，并清除此会话的提醒" : "")
    }

    @ViewBuilder
    private func sessionRow(_ conversation: HarnessConversation) -> some View {
        let navigable = NotificationRouter.supportsApplicationNavigation(forToolKey: tool.key)
        Group {
            if navigable {
                Button { openConversation(conversation) } label: { sessionLabel(conversation) }
                    .buttonStyle(StatusRowButtonStyle())
                    .help(routeHelp(conversation))
                    .accessibilityIdentifier("status-session-\(tool.key)-\(conversation.sessionId ?? conversation.id)")
            } else {
                sessionLabel(conversation)
                    .padding(.trailing, 16).padding(.horizontal, 6).padding(.vertical, 4)
                    .help(displayTitle(conversation.title) + "\n暂不支持自动打开")
            }
        }.padding(.leading, 14)
    }

    private func sessionLabel(_ conversation: HarnessConversation) -> some View {
        HStack(spacing: 6) {
            Image(systemName: conversation.symbol).font(.system(size: 9))
                .foregroundColor(statusColor(conversation)).frame(width: 10)
            Text(displayTitle(conversation.title))
                .font(.system(size: 11))
                .foregroundColor(conversation.current || conversation.needsAttention ? .primary : .secondary)
                .lineLimit(1).truncationMode(.tail).frame(maxWidth: .infinity, alignment: .leading)
            if conversation.needsAttention {
                Circle().fill(Color.accentColor).frame(width: 4, height: 4)
                    .accessibilityLabel("未读")
            }
            Text(conversation.label).font(.system(size: 9))
                .foregroundColor(statusColor(conversation)).fixedSize()
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
