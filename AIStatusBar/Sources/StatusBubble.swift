import SwiftUI

/// 形象与信息分开：庆祝可以切换姿势，但不会覆盖仍在运行的任务数量。
struct StatusBubbleState: Equatable {
    let mood: PetMood
    var attentionCount = 0
    var urgentAttentionCount = 0
    var completedCount = 0
    var completionMessage = "本轮已结束"

    enum Kind: Equatable { case attention, error, completed, running, loading, idle, sleeping }

    var runningCount: Int {
        if case .working(let count) = mood { return max(0, count) }
        return 0
    }

    var kind: Kind {
        // 未读的结束记录也计入待处理，但不应盖掉刚发生的结束提示。
        if attentionCount > 0 && urgentAttentionCount > 0 { return .attention }
        if mood == .error { return .error }
        if completedCount > 0 { return .completed }
        if attentionCount > 0 { return .attention }
        if runningCount > 0 { return .running }
        switch mood {
        case .loading: return .loading
        case .sleeping: return .sleeping
        default: return .idle
        }
    }

    var count: Int? {
        switch kind {
        case .attention: return attentionCount
        case .completed: return completedCount
        case .running: return runningCount
        default: return nil
        }
    }

    var symbol: String {
        switch kind {
        case .attention: return "bubble.left.fill"
        case .error: return "exclamationmark.triangle"
        case .completed: return "checkmark"
        case .running: return "play.fill"
        case .loading: return "hourglass"
        case .idle: return "pause.fill"
        case .sleeping: return "moon.fill"
        }
    }

    var message: String {
        switch kind {
        case .attention: return "\(attentionCount) 项待处理"
        case .completed: return completionMessage
        default: return mood.summary
        }
    }

    var accessibilitySummary: String {
        var parts = [message]
        if kind != .running && runningCount > 0 { parts.append("仍有 \(runningCount) 个任务运行中") }
        return parts.joined(separator: "，")
    }

    func isVisible(expanded: Bool) -> Bool {
        expanded || ![Kind.idle, .sleeping].contains(kind)
    }

    static func compactCount(_ count: Int) -> String {
        count > 99 ? "99+" : String(max(0, count))
    }
}

/// 桌宠与悬浮球共用一个胶囊；悬浮球始终只显示 SF Symbols 和数字。
struct StatusBubble: View {
    enum Style: Equatable { case pet, ball }

    let state: StatusBubbleState
    var style: Style = .pet
    var expanded = false
    var scale: CGFloat = 1
    var monochrome = false
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var compact: Bool { style == .ball }
    private var showsMessage: Bool { !compact && (expanded || state.kind == .completed) }
    private var showsRunning: Bool { state.kind != .running && state.runningCount > 0 }
    private var fontSize: CGFloat { (compact ? 10 : 11) * scale }
    private var iconWidth: CGFloat { (compact ? 10 : 12) * scale }
    private var gap: CGFloat { 4 * scale }
    private var inset: CGFloat { (compact ? 8 : 10) * scale }
    private var separatorGap: CGFloat { (compact ? 5 : 6) * scale }

    private var text: String {
        if showsMessage { return state.message }
        return state.count.map(StatusBubbleState.compactCount) ?? ""
    }

    private var ink: Color {
        if monochrome { return Color(white: colorScheme == .dark ? 0.94 : 0.22) }
        return colorScheme == .dark ? Color(red: 0.90, green: 0.94, blue: 1) : Color(red: 0.24, green: 0.33, blue: 0.45)
    }

    private var blue: Color {
        if monochrome { return Color(white: colorScheme == .dark ? 0.82 : 0.30) }
        return colorScheme == .dark ? Color(red: 0.57, green: 0.77, blue: 1) : Color(red: 0.22, green: 0.49, blue: 0.81)
    }

    private var accent: Color {
        if monochrome { return ink }
        switch state.kind {
        case .attention: return colorScheme == .dark ? Color(red: 0.77, green: 0.70, blue: 1) : Color(red: 0.51, green: 0.40, blue: 0.75)
        case .error: return colorScheme == .dark ? Color(red: 1, green: 0.58, blue: 0.53) : Color(red: 0.80, green: 0.28, blue: 0.24)
        case .completed: return colorScheme == .dark ? Color(red: 0.48, green: 0.83, blue: 0.70) : Color(red: 0.17, green: 0.58, blue: 0.45)
        default: return blue
        }
    }

    private var background: Color {
        if monochrome { return Color(white: colorScheme == .dark ? 0.19 : 0.97) }
        return colorScheme == .dark ? Color(red: 0.19, green: 0.24, blue: 0.32) : Color(red: 0.96, green: 0.98, blue: 1)
    }

    private var border: Color {
        if monochrome { return Color(white: colorScheme == .dark ? 0.42 : 0.77) }
        return colorScheme == .dark ? Color.white.opacity(0.18) : Color(red: 0.76, green: 0.83, blue: 0.91)
    }

    var body: some View {
        HStack(spacing: 0) {
            if compact && showsRunning {
                // 悬浮球保留运行数的位置，新消息追加到右侧。
                runningContent
                separator
                primaryContent
            } else {
                primaryContent
                if showsRunning {
                    separator
                    runningContent
                }
            }
        }
        .font(.system(size: fontSize, weight: .semibold, design: .rounded).monospacedDigit())
        .foregroundColor(ink)
        .padding(.horizontal, inset)
        // 使用 SwiftUI 实际排版宽度。普通 NSFont 测得的数字 1 比圆角等宽数字窄，
        // 手算总宽度会把前面的数字压成省略号；数字组始终完整，只有长消息可截断。
        .frame(maxWidth: showsMessage ? 204 * scale : nil)
        .fixedSize(horizontal: true, vertical: true)
        .frame(height: (compact ? 22 : 27) * scale)
        .background(
            Capsule()
                .fill(background)
                .overlay(Capsule().strokeBorder(
                    border,
                    lineWidth: 0.7 * scale
                ))
        )
        .shadow(color: Color.black.opacity(colorScheme == .dark ? 0.15 : 0.08), radius: 3 * scale, y: 1.5 * scale)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.22), value: text)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.22), value: state.runningCount)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.22), value: showsRunning)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(state.accessibilitySummary)
    }

    private var primaryContent: some View {
        HStack(spacing: gap) {
            Image(systemName: state.symbol)
                .font(.system(size: (compact ? 9 : 10) * scale, weight: .bold))
                .foregroundColor(accent)
                .frame(width: iconWidth)
            if !text.isEmpty {
                Text(text)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .fixedSize(horizontal: !showsMessage, vertical: true)
            }
        }
    }

    private var runningContent: some View {
        HStack(spacing: gap) {
            Image(systemName: "play.fill")
                .font(.system(size: (compact ? 9 : 10) * scale, weight: .bold))
                .foregroundColor(blue)
                .frame(width: iconWidth)
            Text(StatusBubbleState.compactCount(state.runningCount))
        }
        .fixedSize()
        .layoutPriority(1)
    }

    private var separator: some View {
        Circle().fill(ink.opacity(0.30)).frame(width: 2 * scale, height: 2 * scale)
            .padding(.horizontal, separatorGap)
            .fixedSize()
    }
}
