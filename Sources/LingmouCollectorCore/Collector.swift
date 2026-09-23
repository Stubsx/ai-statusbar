import Foundation

public final class LingmouCollector {
    public let environment: CollectorEnvironment
    public let settings: CollectorSettings
    private let adapters: [any ToolAdapter]
    private let files: FileSupport
    private let processes: ProcessSupport

    public init(
        environment: CollectorEnvironment = CollectorEnvironment(),
        settings: CollectorSettings? = nil,
        adapters: [any ToolAdapter] = []
    ) {
        self.environment = environment
        self.adapters = adapters
        self.files = FileSupport()
        self.processes = ProcessSupport()
        self.settings =
            settings
            ?? CollectorSettings.load(
                path: environment.path(".ai-statusbar", "settings.json"),
                files: files
            )
    }

    public func collect() -> StatusData {
        collectStatus(metrics: collectMetrics())
    }

    /// Slow enrichment runs independently from the one-second local status path.
    public func collectMetrics() -> CollectorMetrics {
        let quota = QuotaCollector(
            environment: environment, settings: settings, files: files, processes: processes
        ).collect()
        let usage = UsageCollector(environment: environment, settings: settings, files: files).collectWithSync()
        let priceCache = ModelPricing.collect(
            environment: environment, files: files, enabled: settings.priceEstimatesEnabled)
        let exchangeRate = ModelPricing.collectExchangeRate(
            environment: environment, files: files, enabled: settings.priceEstimatesEnabled)
        let cost = ModelPricing.costData(
            local: usage.local, merged: usage.merged, cache: priceCache,
            exchangeRate: exchangeRate)
        return CollectorMetrics(quotas: quota.compactMapValues { $0 }, usage: usage.local,
                                usageMerged: usage.merged, sync: usage.sync, cost: cost,
                                collectedAt: environment.now)
    }

    public func collectStatus(metrics: CollectorMetrics? = nil) -> StatusData {
        func measured<T>(_ name: String, _ body: () -> T) -> T {
            let start = Date()
            let value = body()
            if ProcessInfo.processInfo.environment["LINGMOU_PROFILE"] == "1" {
                FileHandle.standardError.write(Data("\(name): \(Date().timeIntervalSince(start))s\n".utf8))
            }
            return value
        }
        let codex = measured("codex") { CodexCollector(
            environment: environment,
            settings: settings,
            files: files,
            processes: processes
        ).collect() }
        let local = LocalCollectors(
            environment: environment, settings: settings, files: files, processes: processes)
        let kimi = measured("kimi") { local.kimi() }
        let kimiWork = measured("kimiWork") { local.kimiWork() }
        let claude = measured("claude") { local.claude() }
        let hermes = measured("hermes") { local.hermes() }
        let zcode = measured("zcode") { local.zcode() }
        let dsh = measured("dsh") { local.dsh() }
        let quota = metrics?.quotas ?? [:]
        var tools = [
            makeTool(
                key: "codex-ide", letter: "C", name: "Codex App", raw: codex.ide,
                quota: quota["codex"] ?? nil),
            makeTool(
                key: "codex-cli", letter: "X", name: "Codex CLI", raw: codex.cli,
                quota: quota["codex"] ?? nil),
        ]
        tools += [
            makeTool(
                key: "kimi", letter: "K", name: "Kimi Code", raw: kimi, quota: quota["kimi"] ?? nil),
            makeTool(
                key: "kimi-work", letter: "W", name: "Kimi Work", raw: kimiWork,
                quota: quota["kimi-work"] ?? nil),
            makeTool(key: "claude", letter: "L", name: "Claude Code", raw: claude, quota: nil),
            makeTool(key: "hermes", letter: "H", name: "Hermes", raw: hermes, quota: nil),
            makeTool(
                key: "zcode", letter: "Z", name: "ZCode", raw: zcode, quota: quota["zcode"] ?? nil),
            makeTool(key: "dsh", letter: "D", name: "DSH", raw: dsh, quota: nil),
        ]
        tools += AdapterContract.collect(adapters, excluding: Set(tools.map(\.key)),
                                         environment: environment, settings: settings)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm:ss"
        return StatusData(
            updatedAt: formatter.string(from: Date(timeIntervalSince1970: environment.now)),
            tools: tools,
            usage: metrics?.usage,
            usageMerged: metrics?.usageMerged,
            sync: metrics?.sync,
            cost: metrics?.cost,
            collectedAt: environment.now
        )
    }

    public func jsonData(prettyPrinted: Bool = false) throws -> Data {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.outputFormatting = prettyPrinted ? [.prettyPrinted, .sortedKeys] : []
        return try encoder.encode(collect())
    }

    public func renderSwiftBar(_ data: StatusData? = nil) -> String {
        let data = data ?? collect()
        let labels = ["busy": "工作中", "idle": "空闲", "off": "未运行"]
        func mark(_ state: String) -> String {
            ["busy": "🟢", "idle": "🟡", "off": "⚪️"][state] ?? "⚪️"
        }
        func badge(_ tool: ToolStatus) -> String {
            tool.state == "busy"
                ? "\(tool.letter)🟢\(tool.busyCount)" : "\(tool.letter)\(mark(tool.state))"
        }
        func safe(_ title: String) -> String {
            title.replacingOccurrences(of: "|", with: "¦")
                .split(whereSeparator: \.isNewline)
                .joined(separator: " ")
                .trimmingCharacters(in: .whitespaces)
        }
        var output = [data.tools.map(badge).joined(separator: " "), "---"]
        for tool in data.tools {
            output.append(
                "\(mark(tool.state)) \(tool.name)：\(labels[tool.state] ?? "未运行")（\(tool.detail)）")
            for item in tool.busyItems.prefix(3) {
                output.append("▶ \(safe(item.title)) | size=11 color=green")
            }
            if let title = tool.latestTitle, tool.busyItems.isEmpty {
                output.append("最近任务：\(safe(title)) · \(tool.latestAge ?? "") | size=11 color=gray")
            }
            output.append("---")
        }
        output.append(
            "C=Codex App  X=Codex CLI  K=Kimi Code  W=Kimi Work  L=Claude  H=Hermes  Z=ZCode  D=DSH | size=10 color=gray"
        )
        output.append("🟢工作中  🟡空闲  ⚪️未运行 | size=10 color=gray")
        output.append("刷新 | refresh=true")
        return output.joined(separator: "\n")
    }

    private func makeTool(
        key: String,
        letter: String,
        name: String,
        raw: RawToolState,
        quota: ToolQuota?
    ) -> ToolStatus {
        var seen = Set<String>()
        let active = raw.busy.filter { !$0.id.isEmpty && seen.insert($0.id).inserted }
        var state = !active.isEmpty ? "busy" : (raw.processOn ? "idle" : "off")
        if state == "idle", settings.offlineAfterSeconds > 0, raw.activity > 0,
            environment.now - raw.activity > TimeInterval(settings.offlineAfterSeconds)
        {
            state = "off"
        }
        return ToolStatus(
            key: key,
            letter: letter,
            name: name,
            state: state,
            busyItems: active,
            detail: state == "busy" ? "\(active.count) 个任务" : raw.detail,
            latestTitle: raw.latest?.title,
            latestAge: raw.latest.map { ageString($0.timestamp) },
            quota: quota,
            activeItems: active,
            activities: raw.activities,
            health: ToolSupport.health(for: key, raw: raw, quota: quota,
                                       environment: environment, settings: settings),
            capabilities: ToolSupport.capabilities(for: key),
            latestSessionId: raw.latest?.sessionId
        )
    }

    private func ageString(_ timestamp: TimeInterval) -> String {
        let seconds = max(0, Int(environment.now - timestamp))
        if seconds < 60 { return "刚刚" }
        if seconds < 3_600 { return "\(seconds / 60)分钟前" }
        if seconds < 86_400 { return "\(seconds / 3_600)小时前" }
        return "\(seconds / 86_400)天前"
    }
}
