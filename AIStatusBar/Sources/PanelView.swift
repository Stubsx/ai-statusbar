import Cocoa
import SwiftUI

// 桌面浮窗内容（PanelView）。

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
    @AppStorage("usageBreakdown") private var usageBreakdown = "tools"
    @State private var historyTool = "all"
    @State private var clearHistoryConfirmation = false

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
            let stale = s.sources?.filter { Date().timeIntervalSince1970 - $0.updatedAt > 3_600 }.count ?? 0
            let unavailable = s.dir == nil || store.data?.usageMerged == nil
            Text(unavailable ? "同步目录不可用 · 当前显示本机统计" :
                 "\(s.sources?.count ?? 1) 台设备\(stale > 0 ? " · \(stale) 台超过 1 小时未更新" : " · 数据已汇总")")
                .font(.system(size: 9).monospacedDigit())
                .foregroundColor(unavailable || stale > 0 ? .orange : .secondary)
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
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 12) {
                Text("灵眸").font(.custom("PingFangSC-Semibold", size: 15)).tracking(2)
                Spacer()
                if store.settings.experience.privacyMode {
                    Image(systemName: "eye.slash").foregroundColor(.secondary).help("演示模式：任务标题已隐藏")
                }
                pageMenu
                Button { (NSApp.delegate as? AppDelegate)?.showSettings() } label: {
                    Image(systemName: "slider.horizontal.3").font(.system(size: 12))
                }.buttonStyle(.borderless).help("设置")
            }
            Divider().opacity(0.5)
            if tab == "status" {
                summaryView
            } else {
                FittedPanelScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        if tab == "heat" { heatView }
                        else if tab == "usage" { usageView }
                        else if tab == "quota" { quotaView }
                        else if tab == "history" { historyView }
                        else { statusView }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.trailing, 2)
                }
            }
            HStack {
                FreshnessView(timestamp: store.lastCollectedAt)
                Spacer()
                if tab != "status" {
                    Button("返回状态") { tab = "status" }
                        .font(.system(size: 10)).buttonStyle(.borderless)
                        .keyboardShortcut(.escape, modifiers: [])
                }
            }
        }
        .padding(14)
        .frame(width: tab == "status" ? 300 : (tab == "details" ? 380 : 340))
        .modifier(ConditionalGlass(bare: bare))
        .onAppear { applyLevel() }
        .onChange(of: tab) { _ in
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .statusUpdated, object: nil)
            }
        }
    }

    private var visibleTools: [ToolStatus] {
        (store.data?.tools.filter { $0.state != "off" || $0.health?.state == "error" } ?? []).sorted {
            func priority(_ tool: ToolStatus) -> Int {
                tool.health?.state == "error" ? 0 : (tool.state == "busy" ? 1 : 2)
            }
            return priority($0) == priority($1) ? $0.key < $1.key : priority($0) < priority($1)
        }
    }

    private var summaryToolLimit: Int {
        store.attentionEvents.isEmpty && store.collectorError == nil ? 4 : 3
    }

    /// 默认只是状态速览；任务再多也不把浮窗撑成长看板。
    private var summaryView: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let error = store.collectorError {
                Button { (NSApp.delegate as? AppDelegate)?.showSettings(tab: "connections") } label: {
                    Label("状态暂未更新 · 查看原因", systemImage: "exclamationmark.triangle")
                        .font(.system(size: 11)).foregroundColor(.orange)
                }.buttonStyle(.plain).help(error)
            }
            if let record = store.attentionEvents.first {
                HStack(spacing: 8) {
                    Button { store.openEvent(record) } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Label("\(record.toolName) · \(record.label)", systemImage: record.symbol)
                                .font(.system(size: 10)).foregroundColor(record.waiting || record.phase == "failed" ? .orange : .secondary)
                                .lineLimit(1)
                            Text(store.displayTitle(record.title)).font(.system(size: 12, weight: .medium))
                                .lineLimit(1)
                        }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                    }.buttonStyle(.plain)
                        .accessibilityIdentifier("open-event-\(record.id)")
                        .help("\(store.displayTitle(record.title))\n\(NotificationRouter.destinationLabel(forToolKey: record.toolKey, sessionId: record.sessionId))，并清除此条提醒")
                    Button { historyTool = "all"; tab = "history" } label: {
                        HStack(spacing: 3) {
                            Text("\(store.attentionEvents.count) 条")
                            Image(systemName: "chevron.right").font(.system(size: 8, weight: .semibold))
                        }.font(.system(size: 10)).fixedSize()
                    }.buttonStyle(.borderless).help("查看未读事件与历史记录")
                        .accessibilityLabel("查看全部 \(store.attentionEvents.count) 条未读事件")
                }
                .padding(9)
                .background(RoundedRectangle(cornerRadius: 9).fill(
                    record.waiting || record.phase == "failed" ? Color.orange.opacity(0.07) : Color.primary.opacity(0.035)))
            }
            if visibleTools.isEmpty { emptyStatus }
            ForEach(Array(visibleTools.prefix(summaryToolLimit)), id: \.key) { tool in
                let sessionId = tool.state == "busy" ? (tool.activeItems ?? tool.busyItems).first?.id : nil
                Button { NotificationRouter.openDestination(forToolKey: tool.key, sessionId: sessionId) } label: {
                    HStack(spacing: 8) {
                        Circle().fill(tool.health?.state == "error" ? .orange : color(for: tool.state))
                            .frame(width: 6, height: 6)
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(tool.name).font(.system(size: 12, weight: .medium))
                                Spacer(minLength: 6)
                                Text(tool.health?.state == "error" ? "读取异常" :
                                     (tool.state == "busy" ? "\(tool.busyCount) 个运行中" : label(for: tool.state)))
                                    .font(.system(size: 10)).foregroundColor(.secondary)
                            }
                            if tool.state == "busy", let item = (tool.activeItems ?? tool.busyItems).first {
                                Text(store.displayTitle(item.title)).font(.system(size: 11)).foregroundColor(.secondary)
                                    .lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                        Image(systemName: "arrow.up.right").font(.system(size: 9)).foregroundColor(.secondary)
                    }.padding(.vertical, 4).contentShape(Rectangle())
                }.buttonStyle(.plain).help(NotificationRouter.destinationLabel(forToolKey: tool.key, sessionId: sessionId))
            }
            if visibleTools.count > summaryToolLimit {
                Button("还有 \(visibleTools.count - summaryToolLimit) 个工具 · 查看全部") { tab = "details" }
                    .font(.system(size: 10)).buttonStyle(.borderless)
            }
        }
    }

    private var emptyStatus: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(store.data == nil ? "正在观察你的 AI 工具…" : "当前没有运行中的工具")
                .font(.system(size: 12, weight: .medium))
            Text("开始工作后，状态会自动出现在这里。")
                .font(.system(size: 11)).foregroundColor(.secondary)
            Button("查看已识别工具") { (NSApp.delegate as? AppDelegate)?.showSettings(tab: "connections") }
                .font(.system(size: 10)).buttonStyle(.borderless)
        }.padding(.vertical, 4)
    }

    private var statusView: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let error = store.collectorError {
                Label(error, systemImage: "exclamationmark.triangle").font(.system(size: 11)).foregroundColor(.orange)
                Button("查看连接与诊断") { (NSApp.delegate as? AppDelegate)?.showSettings(tab: "connections") }
            }
            if visibleTools.isEmpty { emptyStatus }
            ForEach(visibleTools, id: \.key) { tool in
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 7) {
                        Circle().fill(tool.health?.state == "error" ? .orange : color(for: tool.state)).frame(width: 6, height: 6)
                        Text(tool.name).font(.system(size: 12, weight: .semibold))
                        Spacer()
                        Text(tool.state == "busy" ? "\(tool.busyCount) 个任务运行中" : label(for: tool.state))
                            .font(.system(size: 10)).foregroundColor(.secondary)
                        Button { NotificationRouter.openDestination(forToolKey: tool.key) } label: {
                            Image(systemName: "arrow.up.right").font(.system(size: 10, weight: .semibold))
                        }.buttonStyle(.borderless).help(NotificationRouter.destinationLabel(forToolKey: tool.key))
                    }
                    let items = tool.activeItems ?? tool.busyItems
                    ForEach(items, id: \.id) { item in
                        taskLink(title: item.title, toolKey: tool.key, sessionId: item.id)
                    }
                    if items.isEmpty, let title = tool.latestTitle {
                        taskLink(title: "最近：\(title)", toolKey: tool.key, sessionId: tool.latestSessionId, secondary: true)
                    }
                    if tool.health?.state == "error" {
                        Text(tool.health?.message ?? "部分数据不可读").font(.system(size: 10)).foregroundColor(.orange)
                    }
                }
                .padding(.vertical, 3)
            }
        }
    }

    private func taskLink(title: String, toolKey: String, sessionId: String?, secondary: Bool = false) -> some View {
        Button { NotificationRouter.openDestination(forToolKey: toolKey, sessionId: sessionId) } label: {
            HStack(alignment: .top, spacing: 7) {
                Image(systemName: secondary ? "clock" : "play.fill").font(.system(size: 8)).padding(.top, 3)
                Text(store.displayTitle(title)).font(.system(size: 11))
                    .lineLimit(4).frame(maxWidth: .infinity, alignment: .leading)
            }
            .foregroundColor(secondary ? .secondary : .primary)
            .padding(.leading, 13).padding(.vertical, 3).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("\(store.displayTitle(title))\n\(NotificationRouter.destinationLabel(forToolKey: toolKey, sessionId: sessionId))")
    }

    private var historyView: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Picker("工具", selection: $historyTool) {
                    Text("全部工具").tag("all")
                    ForEach(store.data?.tools ?? [], id: \.key) { tool in Text(tool.name).tag(tool.key) }
                }.labelsHidden().frame(maxWidth: 160)
                Spacer()
                Button("清空") { clearHistoryConfirmation = true }
                    .disabled(store.recentEvents.isEmpty && store.historyError == nil).buttonStyle(.borderless)
            }
            Text("未读优先 · 本机保留 7 天 / 200 条").font(.system(size: 10)).foregroundColor(.secondary)
            if let error = store.historyError { Text(error).font(.system(size: 10)).foregroundColor(.orange) }
            if historyEvents.isEmpty {
                Text("还没有事件。任务结束、等待或中断后会出现在这里。")
                    .font(.system(size: 11)).foregroundColor(.secondary)
            }
            TaskEventRows(store: store, events: historyEvents, expanded: true)
        }
        .alert("清空最近事件？", isPresented: $clearHistoryConfirmation) {
            Button("取消", role: .cancel) {}
            Button("清空", role: .destructive) { store.clearHistory() }
        } message: {
            Text("仅清除灵眸本机历史，不影响原工具的任务。仍在等待回答或确认的任务会保留，旧事件不会再次推送。")
        }
    }

    private var rangeModels: [String: UsageEntry]? {
        guard let usage = usageForDisplay else { return nil }
        switch usageRange {
        case "7d": return usage.weekly?.models
        case "30d": return usage.monthly?.models
        default: return usage.models
        }
    }

    private var pageMenu: some View {
        Menu {
            Button("状态速览") { tab = "status" }.keyboardShortcut("1", modifiers: .command)
            Button("Token 用量") { tab = "usage" }.keyboardShortcut("2", modifiers: .command)
            Button("活跃热力") { tab = "heat" }.keyboardShortcut("3", modifiers: .command)
            Button("账号配额") { tab = "quota" }.keyboardShortcut("4", modifiers: .command)
            Divider()
            Button("最近事件") { historyTool = "all"; tab = "history" }.keyboardShortcut("5", modifiers: .command)
            Button(tab == "details" ? "返回状态速览" : "运行详情") {
                tab = tab == "details" ? "status" : "details"
            }.keyboardShortcut("e", modifiers: .command)
        } label: {
            Text(["status": "状态", "usage": "用量", "heat": "活跃", "quota": "配额",
                  "history": "最近事件", "details": "运行详情"][tab] ?? "状态")
                .font(.system(size: 11, weight: .medium))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("查看用量、配额和更多信息（⌘1–⌘5）")
        .accessibilityLabel("切换状态、用量与记录")
    }

    private var historyEvents: [TaskRecord] {
        store.recentEvents.filter { historyTool == "all" || $0.toolKey == historyTool }.sorted {
            if $0.needsAttention != $1.needsAttention { return $0.needsAttention }
            if $0.needsAttention && $0.priority != $1.priority { return $0.priority < $1.priority }
            return $0.timestamp > $1.timestamp
        }
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
                HStack(spacing: 0) {
                    segmentButton("按工具", tag: "tools", selection: $usageBreakdown)
                    segmentButton("按模型", tag: "models", selection: $usageBreakdown)
                }.padding(.vertical, 8)
                Text(rangeSubtitle)
                    .font(.system(size: 9).monospacedDigit())
                    .foregroundColor(.secondary.opacity(0.7))
                    .padding(.top, 3)
                    .padding(.bottom, 5)
                usageRow("总计", entries.total, bold: true)
                Divider().background(Color.primary.opacity(0.1))
                // 按工具总用量（输入+缓存+输出）从高到低排序
                let sortedTools = (usageBreakdown == "models" ? (rangeModels ?? [:]) : entries.tools).sorted { lhs, rhs in
                    let l = lhs.value.input + lhs.value.output + lhs.value.cache
                    let r = rhs.value.input + rhs.value.output + rhs.value.cache
                    return l > r
                }
                ForEach(sortedTools, id: \.key) { key, e in
                    usageRow(usageBreakdown == "models" ? key : usageName(key), e, bold: false)
                }
                if usageBreakdown == "models" && (rangeModels ?? [:]).isEmpty {
                    Text("此时间范围暂无模型明细").font(.system(size: 11)).foregroundColor(.secondary)
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
                    Text("配额暂不可用，可在“连接与诊断”查看原因")
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
                        if let quota = t.quota {
                            FreshnessView(timestamp: Double(quota.updatedAt),
                                          maxAge: t.health?.quotaState == "stale" ? 0 : (t.key == "kimi-work" ? 4_200 : 600),
                                          staleLabel: "配额已过期 · 更新于")
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
        ["codex": "Codex", "kimi": "Kimi Code", "kimi-work": "Kimi Work", "claude": "Claude Code", "zcode": "ZCode", "hermes": "Hermes", "dsh": "DSH"][key] ?? key
    }

    private func fmt(_ n: Int) -> String {
        NumberFormat.tokens(n, unit: store.settings.numberUnit)
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
