import Cocoa

struct ToolDestination {
    let toolKey: String
    var sessionId: String? = nil
}

/// Codex local conversations have an official deep link; other tools retain host-level routing.
enum NotificationRouter {
    private static let hostedCodexMarks = ["ChatGPT.app/", "Codex.app/", "app-server", "mcp-server"]

    static func destinationLabel(forToolKey key: String, sessionId: String? = nil) -> String {
        if conversationURL(forToolKey: key, sessionId: sessionId) != nil { return "打开这条 Codex 对话" }
        switch key {
        case "codex-ide": return "打开 Codex 应用"
        case "kimi-work": return "打开 Kimi 应用"
        case "zcode": return "打开 ZCode 应用或宿主"
        case "hermes": return "打开 Hermes 应用或宿主"
        case "codex-cli", "kimi", "claude": return "打开宿主终端或编辑器"
        case "dsh": return "打开 DSH 页面"
        default: return "暂不支持自动打开"
        }
    }

    static func openDestination(_ destination: ToolDestination) {
        openDestination(forToolKey: destination.toolKey, sessionId: destination.sessionId)
    }

    static func conversationURL(forToolKey key: String, sessionId: String?) -> URL? {
        guard key == "codex-ide", let sessionId, UUID(uuidString: sessionId) != nil else { return nil }
        return URL(string: "codex://threads/\(sessionId.lowercased())")
    }

    static func openDestination(forToolKey key: String, sessionId: String? = nil) {
        DispatchQueue.main.async {
            if let url = conversationURL(forToolKey: key, sessionId: sessionId) {
                openCodexConversation(url)
                return
            }
            switch key {
            case "codex-ide":
                if activateRunningApp(bundleID: "com.openai.codex", named: ["Codex"]) { return }
                openApplication(bundleID: "com.openai.codex", path: "/Applications/Codex.app")
            case "kimi-work":
                if activateRunningApp(bundleID: "com.moonshot.kimichat", named: ["Kimi"]) { return }
                openApplication(bundleID: "com.moonshot.kimichat", path: "/Applications/Kimi.app")
            case "zcode":
                if activateRunningApp(bundleID: "dev.zcode.app", named: ["ZCode"]) { return }
                if openHost(of: "zcode-cli", reportMissing: false) { return }
                openApplication(bundleID: "dev.zcode.app", path: "/Applications/ZCode.app")
            case "codex-cli": _ = openHost(of: "codex", excluding: hostedCodexMarks)
            case "kimi": _ = openHost(of: "kimi")
            case "claude": _ = openHost(of: "claude", excluding: ["Claude.app/"])
            case "hermes":
                if activateRunningApp(bundleID: "com.nousresearch.hermes", named: ["Hermes"]) { return }
                _ = openHost(of: "hermes")
            case "dsh":
                if !NSWorkspace.shared.open(URL(string: "http://127.0.0.1:3080/")!) {
                    explain("无法打开 DSH 页面", detail: "请确认本机 DSH Web 服务和默认浏览器可用。")
                }
            default:
                explain("这个工具暂不支持自动打开", detail: "请回到原工具查看对应任务。")
            }
        }
    }

    private static func openCodexConversation(_ url: URL) {
        let app = NSRunningApplication.runningApplications(withBundleIdentifier: "com.openai.codex").first
        let applicationURL = app?.bundleURL
            ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.openai.codex")
        guard let applicationURL else {
            openDestination(forToolKey: "codex-ide")
            return
        }
        app?.unhide()
        if #available(macOS 14, *) {
            NSApp.yieldActivation(toApplicationWithBundleIdentifier: "com.openai.codex")
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        configuration.createsNewApplicationInstance = false
        configuration.allowsRunningApplicationSubstitution = false
        NSWorkspace.shared.open([url], withApplicationAt: applicationURL, configuration: configuration) { _, error in
            if error != nil { openDestination(forToolKey: "codex-ide") }
        }
    }

    /// Returns whether a destination was found; openApplication reports asynchronous failures.
    private static func activateRunningApp(bundleID: String, named names: [String]) -> Bool {
        let running = NSWorkspace.shared.runningApplications.filter { !$0.isTerminated }
        guard let app = running.first(where: { $0.bundleIdentifier == bundleID }) ?? running.first(where: {
            $0.activationPolicy == .regular && names.contains($0.localizedName ?? "")
        }) else { return false }
        activate(app)
        return true
    }

    private static func activate(_ app: NSRunningApplication) {
        app.unhide()
        if #available(macOS 14, *) { NSApp.yieldActivation(to: app) }
        if let url = app.bundleURL {
            // Ask the app to restore its window, including a minimized last window.
            // Process activation alone does not send the standard reopen event.
            openApplication(at: url, fallback: app)
        } else if !requestActivation(app) {
            explain("无法将应用切到前台", detail: "请从程序坞打开原应用后重试。")
        }
    }

    private static func requestActivation(_ app: NSRunningApplication) -> Bool {
        if #available(macOS 14, *) {
            NSApp.yieldActivation(to: app)
            return app.activate(from: .current, options: [.activateAllWindows])
        }
        return app.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
    }

    private static func openApplication(bundleID: String?, path: String) {
        let url = FileManager.default.fileExists(atPath: path) ? URL(fileURLWithPath: path)
            : bundleID.flatMap { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }
        guard let url else {
            explain("没有找到对应应用", detail: "请先安装或打开原工具，再查看任务。")
            return
        }
        if #available(macOS 14, *), let bundleID {
            NSApp.yieldActivation(toApplicationWithBundleIdentifier: bundleID)
        }
        openApplication(at: url)
    }

    private static func openApplication(at url: URL, fallback: NSRunningApplication? = nil) {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        configuration.hides = false
        configuration.createsNewApplicationInstance = false
        configuration.allowsRunningApplicationSubstitution = false
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { app, error in
            DispatchQueue.main.async {
                if error != nil || app == nil {
                    if let fallback, requestActivation(fallback) { return }
                    explain("应用打开失败", detail: "请从访达打开原应用后重试。")
                }
            }
        }
    }

    /// Multiple CLI processes in one GUI app still cannot identify that app's terminal window.
    private static func openHost(of name: String, excluding: [String] = [], reportMissing: Bool = true) -> Bool {
        let lines = psLines()
        let appByPID = Dictionary(NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }
            .map { ($0.processIdentifier, $0) }, uniquingKeysWith: { first, _ in first })
        let parents = Dictionary(lines.map { ($0.pid, $0.ppid) }, uniquingKeysWith: { first, _ in first })
        var hosts: [pid_t: Int] = [:]
        for line in lines where matches(line.args, name: name, excluding: excluding) {
            var cursor = line.ppid
            var seen = Set<pid_t>()
            while cursor > 1 && seen.insert(cursor).inserted {
                if appByPID[cursor] != nil { hosts[cursor, default: 0] += 1; break }
                cursor = parents[cursor] ?? 0
            }
        }
        let candidates = hosts.keys.sorted().compactMap { pid -> (NSRunningApplication, Int)? in
            appByPID[pid].map { ($0, hosts[pid] ?? 1) }
        }
        guard let first = candidates.first else {
            if reportMissing {
                explain("未找到这个任务的宿主", detail: "原终端可能已退出，或会话运行在 tmux／后台服务中。请手动回到原工具。")
            }
            return false
        }
        if candidates.count == 1 { activate(first.0); return true }
        let alert = NSAlert()
        alert.messageText = "选择要打开的宿主应用"
        alert.informativeText = "检测到多个运行中的会话。目前可以打开宿主应用，具体终端窗口或标签需要在应用中选择。"
        for (app, count) in candidates {
            alert.addButton(withTitle: "\(app.localizedName ?? "终端") · \(count) 个会话")
        }
        alert.addButton(withTitle: "取消")
        NSApp.activate(ignoringOtherApps: true)
        let index = alert.runModal().rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
        if candidates.indices.contains(index) { activate(candidates[index].0) }
        return true
    }

    static func matches(_ args: String, name: String, excluding: [String] = []) -> Bool {
        guard !excluding.contains(where: args.contains) else { return false }
        var tokens = args.split(whereSeparator: \.isWhitespace).map(String.init)
        while let first = tokens.first, first.contains("=") && !first.hasPrefix("/") { tokens.removeFirst() }
        guard let executable = tokens.first else { return false }
        let names = name == "kimi" ? ["kimi", "kimi-code"] : [name]
        let basename = URL(fileURLWithPath: executable).lastPathComponent
        if names.contains(basename) { return true }
        let interpreters = ["python", "python3", "python3.11", "python3.12", "python3.13", "python3.14", "node", "bun"]
        guard interpreters.contains(basename), tokens.count > 1 else { return false }
        if names.contains(URL(fileURLWithPath: tokens[1]).lastPathComponent) { return true }
        return name == "hermes" && tokens.count > 2 && tokens[1] == "-m"
            && (tokens[2] == "hermes_cli" || tokens[2].hasPrefix("hermes_cli."))
    }

    private static func psLines() -> [(pid: pid_t, ppid: pid_t, args: String)] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-eo", "pid=,ppid=,args="]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline).compactMap { row in
            let fields = row.split(separator: " ", maxSplits: 2)
            guard fields.count == 3, let pid = Int32(fields[0]), let parent = Int32(fields[1]) else { return nil }
            return (pid, parent, String(fields[2]))
        }
    }

    private static func explain(_ title: String, detail: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = detail
        alert.addButton(withTitle: "知道了")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}
