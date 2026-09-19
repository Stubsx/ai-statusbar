import Cocoa
import SwiftUI

/// 每个 Harness 只展示运行会话与尚未查看的新结果，与状态图标逐条对应。
struct StatusToolSection: View {
    let group: HarnessConversationGroup
    var kimiWebAvailable = false
    let displayTitle: (String) -> String
    var openDestination: (ToolDestination) -> Void = NotificationRouter.openDestination
    let openConversation: (HarnessConversation) -> Void
    /// 一键已读入口；nil 时（如预览）不显示清除按钮。
    var clearFinished: (([HarnessConversation]) -> Void)? = nil
    @State private var clearHovered = false
    private var tool: ToolStatus { group.tool }

    /// 已结束/已中断/异常的结果行；运行中与待回答的会话不参与一键清除。
    private var finishedConversations: [HarnessConversation] {
        clearFinished == nil ? [] : group.conversations.filter { !$0.current }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 0) {
                if NotificationRouter.supportsApplicationNavigation(forToolKey: tool.key) {
                    Button { openDestination(ToolDestination(toolKey: tool.key)) } label: { header }
                        .buttonStyle(StatusRowButtonStyle(showsArrow: finishedConversations.isEmpty,
                                                          trailingInset: headerTrailingInset))
                        .help(NotificationRouter.destinationLabel(forToolKey: tool.key))
                        .accessibilityIdentifier("status-app-\(tool.key)")
                } else {
                    header.padding(.horizontal, 6).padding(.vertical, 4)
                        .padding(.trailing, headerTrailingInset)
                }
                if !finishedConversations.isEmpty {
                    clearFinishedButton
                }
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

    /// 清除图标在场时收窄箭头预留位，让图标紧跟运行/待查看计数，读作同一组状态图标。
    private var headerTrailingInset: CGFloat { finishedConversations.isEmpty ? 16 : 4 }

    /// 与头部计数（play.fill / bubble.left.fill）同一套图标语言：纯 SF Symbol、
    /// secondary 色、无底色，悬停点亮；不与文字按钮混排。
    private var clearFinishedButton: some View {
        Button {
            clearFinished?(finishedConversations)
        } label: {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(clearHovered ? .accentColor : .secondary)
                .padding(3)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.trailing, 7)
        .help("一键清除已结束/已中断会话的提醒；运行中与待回答的会话保持不变")
        .accessibilityIdentifier("status-clear-\(tool.key)")
        .accessibilityLabel("清除已结束会话")
        .onHover { clearHovered = $0 }
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
    /// 尾部为悬停箭头预留的宽度；被清除图标占用时收窄。
    var trailingInset: CGFloat = 16

    func makeBody(configuration: Configuration) -> some View {
        StatusRowButtonBody(label: configuration.label, isPressed: configuration.isPressed,
                            showsArrow: showsArrow, trailingInset: trailingInset)
    }
}

private struct StatusRowButtonBody<Label: View>: View {
    let label: Label
    let isPressed: Bool
    let showsArrow: Bool
    let trailingInset: CGFloat
    @State private var hovered = false

    var body: some View {
        label
            .padding(.trailing, trailingInset)
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
