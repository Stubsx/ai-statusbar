import Foundation

public final class LingmouCollector {
    public let environment: CollectorEnvironment
    public let settings: CollectorSettings
    private let files: FileSupport
    private let processes: ProcessSupport

    public init(
        environment: CollectorEnvironment = CollectorEnvironment(),
        settings: CollectorSettings? = nil
    ) {
        self.environment = environment
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
        let codex = CodexCollector(
            environment: environment,
            settings: settings,
            files: files,
            processes: processes
        ).collect()
        let local = LocalCollectors(
            environment: environment, settings: settings, files: files, processes: processes)
        let kimi = local.kimi()
        let kimiWork = local.kimiWork()
        let claude = local.claude()
        let hermes = local.hermes()
        let zcode = local.zcode()
        let dsh = local.dsh()
        let quota = QuotaCollector(environment: environment, settings: settings, files: files)
            .collect()
        let usage = UsageCollector(environment: environment, settings: settings, files: files)
            .collectWithSync()
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
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm:ss"
        return StatusData(
            updatedAt: formatter.string(from: Date(timeIntervalSince1970: environment.now)),
            tools: tools,
            usage: usage.local,
            usageMerged: usage.merged,
            sync: usage.sync
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
        var state = !raw.busy.isEmpty ? "busy" : (raw.processOn ? "idle" : "off")
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
            busyItems: raw.busy,
            detail: state == "busy" ? "\(raw.busy.count) 个任务" : raw.detail,
            latestTitle: raw.latest?.title,
            latestAge: raw.latest.map { ageString($0.timestamp) },
            quota: quota
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
