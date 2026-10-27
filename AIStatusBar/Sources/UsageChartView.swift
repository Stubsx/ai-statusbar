import SwiftUI

/// 用量页图表视图:占比堆叠条 + 图例 + 每日柱状图。
/// 部署目标 macOS 12,不能用 SwiftUI Charts,与活跃热力图一样用纯形状绘制。
struct UsageChartCard: View {
    struct Row: Identifiable {
        let id: String
        let name: String
        let tokens: Int
        /// 估价文本(已按当前币种格式化);无估价为 nil 显示 "—",不估价为 nil
        let cost: String??
    }

    /// 汇总行文本(如 "总计 464.8万 tokens · ¥117.08"),由调用方格式化
    let summary: String
    let rows: [Row]
    /// 今日模式的三段构成;为 nil 表示当前是范围模式
    let composition: UsageEntry?
    /// 范围模式的每日用量(已按日期升序、去掉未来日)
    let days: [HeatDay]
    /// 每日费用；旧数据或关闭估价时为 nil，只展示 Token 模式
    let costDays: [CostDay]?
    let todayKey: String
    let showWeekdayLabels: Bool
    /// token 数量格式化(复用 PanelView 的 fmt)
    let format: (Int) -> String
    let formatCost: (Double) -> String

    @AppStorage("usageChartMetric") private var chartMetric = "tokens"
    @State private var hoveredRow: String? = nil
    @State private var hoveredDay: HeatDay? = nil

    private var usesCost: Bool { chartMetric == "cost" && costDays != nil }

    /// 类别色板:系统色自动适配深浅色;最后一个是"其他"的灰
    private static let palette: [Color] = [
        Color(nsColor: .systemBlue), Color(nsColor: .systemPurple),
        Color(nsColor: .systemOrange), Color(nsColor: .systemGreen),
        Color(nsColor: .systemPink), Color(nsColor: .systemTeal),
    ]
    private static let otherColor = Color(nsColor: .systemGray)

    /// 占比 <3% 或超出色板的条目合并为"其他",避免碎段不可读
    private var segments: [(row: Row?, tokens: Int, color: Color)] {
        let total = max(1, rows.reduce(0) { $0 + $1.tokens })
        var result: [(Row?, Int, Color)] = []
        var other = 0
        for (index, row) in rows.enumerated() {
            if index < Self.palette.count, Double(row.tokens) / Double(total) >= 0.03 {
                result.append((row, row.tokens, Self.palette[index]))
            } else {
                other += row.tokens
            }
        }
        if other > 0 { result.append((nil, other, Self.otherColor)) }
        return result
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(summary)
                .font(.system(size: 11, weight: .medium).monospacedDigit())
                .foregroundColor(.secondary)

            if !segments.isEmpty {
                proportionBar
                legend
            }
            if let composition {
                compositionView(composition)
            }
            if !days.isEmpty {
                dailyBars
            }
        }
    }

    // MARK: 占比堆叠条

    private var proportionBar: some View {
        let total = max(1, rows.reduce(0) { $0 + $1.tokens })
        let spacing: CGFloat = 1.5
        return GeometryReader { geo in
            let gaps = spacing * CGFloat(max(0, segments.count - 1))
            let usable = max(0, geo.size.width - gaps)
            HStack(spacing: spacing) {
                ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
                    RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                        .fill(segment.color)
                        .opacity(hoveredRow == nil || hoveredRow == segment.row?.id
                            || (segment.row == nil && hoveredRow == "其他") ? 1 : 0.3)
                        .frame(width: usable * CGFloat(segment.tokens) / CGFloat(total))
                }
            }
        }
        .frame(height: 14)
        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
    }

    // MARK: 图例

    private var legend: some View {
        let total = max(1, rows.reduce(0) { $0 + $1.tokens })
        return VStack(alignment: .leading, spacing: 3) {
            ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
                let percent = Int((Double(segment.tokens) / Double(total) * 100).rounded())
                HStack(spacing: 6) {
                    Circle().fill(segment.color).frame(width: 7, height: 7)
                    Text(segment.row?.name ?? "其他")
                        .font(.system(size: 11))
                        .foregroundColor(Color.primary.opacity(0.8))
                        .lineLimit(1)
                    Text("\(percent)%")
                        .font(.system(size: 10).monospacedDigit())
                        .foregroundColor(.secondary)
                    Spacer()
                    VStack(alignment: .trailing, spacing: 1) {
                        Text(format(segment.tokens))
                            .font(.system(size: 10).monospacedDigit())
                            .foregroundColor(.secondary)
                        if let cost = segment.row?.cost {
                            Text(cost ?? "—")
                                .font(.system(size: 9).monospacedDigit())
                                .foregroundColor(.secondary.opacity(0.8))
                        }
                    }
                }
                .padding(.vertical, 1)
                .padding(.horizontal, 4)
                .background(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(hoveredRow == (segment.row?.id ?? "其他")
                            ? Color.primary.opacity(0.05) : .clear))
                .onHover { inside in
                    hoveredRow = inside ? (segment.row?.id ?? "其他") : nil
                }
            }
        }
    }

    // MARK: 今日构成(输入/缓存/输出)

    private func compositionView(_ entry: UsageEntry) -> some View {
        let parts = [
            ("输入", entry.input, Color(nsColor: .systemBlue)),
            ("缓存", entry.cache, Color(nsColor: .systemTeal)),
            ("输出", entry.output, Color(nsColor: .systemOrange)),
        ]
        let total = max(1, parts.reduce(0) { $0 + $1.1 })
        let spacing: CGFloat = 1.5
        return VStack(alignment: .leading, spacing: 4) {
            GeometryReader { geo in
                let visible = parts.filter { $0.1 > 0 }
                let gaps = spacing * CGFloat(max(0, visible.count - 1))
                let usable = max(0, geo.size.width - gaps)
                HStack(spacing: spacing) {
                    ForEach(Array(visible.enumerated()), id: \.offset) { _, part in
                        Rectangle()
                            .fill(part.2)
                            .frame(width: usable * CGFloat(part.1) / CGFloat(total))
                    }
                }
            }
            .frame(height: 8)
            .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
            HStack(spacing: 10) {
                ForEach(Array(parts.enumerated()), id: \.offset) { _, part in
                    HStack(spacing: 4) {
                        Circle().fill(part.2).frame(width: 6, height: 6)
                        Text("\(part.0) \(format(part.1))")
                            .font(.system(size: 9).monospacedDigit())
                            .foregroundColor(.secondary)
                    }
                }
            }
        }
    }

    // MARK: 每日柱状图

    private var dailyBars: some View {
        let costs = Dictionary(uniqueKeysWithValues: (costDays ?? []).map { ($0.date, $0) })
        let values = days.map { usesCost ? costs[$0.date]?.estimate.amountUsd ?? 0 : Double($0.total) }
        let peak = max(1, values.max() ?? 1)
        return VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .bottom, spacing: 2) {
                ForEach(Array(days.enumerated()), id: \.element.date) { index, day in
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(Color(nsColor: usesCost ? .systemGreen : .systemBlue)
                            .opacity(day.date == todayKey ? 0.95 : 0.45))
                        .frame(maxWidth: .infinity)
                        .frame(height: max(3, 40 * values[index] / peak))
                        .onHover { inside in hoveredDay = inside ? day : nil }
                }
            }
            .frame(height: 40, alignment: .bottom)
            if showWeekdayLabels {
                HStack(spacing: 2) {
                    ForEach(days, id: \.date) { day in
                        Text(Self.narrowWeekday(day.date))
                            .font(.system(size: 8))
                            .foregroundColor(.secondary.opacity(0.7))
                            .frame(maxWidth: .infinity)
                    }
                }
            }
            HStack(spacing: 6) {
                if costDays != nil {
                    metricButton("Token", tag: "tokens")
                    metricButton("费用", tag: "cost")
                }
                Spacer(minLength: 4)
                if let day = hoveredDay {
                    Text(dailyDetail(day, cost: costs[day.date]))
                        .font(.system(size: 9, weight: .medium).monospacedDigit())
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
            }
            .frame(height: 16)
        }
    }

    private func metricButton(_ title: String, tag: String) -> some View {
        let selected = tag == "cost" ? usesCost : !usesCost
        return Button { chartMetric = tag } label: {
            Text(title)
                .font(.system(size: 9, weight: selected ? .semibold : .regular))
                .foregroundColor(selected ? .primary : .secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 1)
                .background(Capsule().fill(selected ? Color.primary.opacity(0.12) : .clear))
        }
        .buttonStyle(.plain)
    }

    private func dailyDetail(_ day: HeatDay, cost: CostDay?) -> String {
        guard day.total > 0 else { return "\(day.date) · 无用量" }
        guard usesCost else { return "\(day.date) · \(format(day.total)) tokens" }
        guard let cost else { return "\(day.date) · 暂无报价" }
        guard cost.estimate.amountUsd > 0 else { return "\(day.date) · 未计价" }
        return "\(day.date) · \(formatCost(cost.estimate.amountUsd))"
    }

    private static let weekdayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "EEEEE"
        return formatter
    }()
    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    private static func narrowWeekday(_ date: String) -> String {
        dayFormatter.date(from: date).map { weekdayFormatter.string(from: $0) } ?? ""
    }
}
