import Cocoa
import Darwin

struct ToolDestination {
    let toolKey: String
    var sessionId: String? = nil
}

/// Conversation-aware routes share the same entry point as task rows and notifications.
enum NotificationRouter {
    private static let hostedCodexMarks = ["ChatGPT.app/", "Codex.app/", "app-server", "mcp-server"]
    private static var resolvingKimi = false
    /// 由 AppDelegate 注入：跳转 Kimi 网页时是否优先复用已打开的同源标签页。
    static var prefersBrowserTabReuse: () -> Bool = { false }

    /// Rendering must never probe local servers or infer a session route from an app route.
    static func supportsSessionNavigation(forToolKey key: String, sessionId: String?,
                                          kimiWebAvailable: Bool = false) -> Bool {
        if conversationURL(forToolKey: key, sessionId: sessionId) != nil { return true }
        return key == "kimi" && kimiWebAvailable && sessionId.map(KimiWebInstance.validID) == true
    }

    static func supportsApplicationNavigation(forToolKey key: String) -> Bool {
        ["codex-ide", "codex-cli", "kimi", "kimi-work", "claude", "hermes", "zcode", "dsh"].contains(key)
    }

    static func destinationLabel(forToolKey key: String, sessionId: String? = nil) -> String {
        if conversationURL(forToolKey: key, sessionId: sessionId) != nil { return "打开这条 Codex 对话" }
        switch key {
        case "codex-ide": return "打开 Codex 应用"
        case "kimi-work": return "打开 Kimi 应用"
        case "zcode": return "打开 ZCode 应用或宿主"
        case "hermes": return "打开 Hermes 应用或宿主"
        case "kimi": return sessionId == nil ? "打开 Kimi 网页或宿主" : "打开对应 Kimi 会话或宿主"
        case "codex-cli", "claude": return "打开宿主终端或编辑器"
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
            case "kimi": openKimi(sessionId: sessionId)
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

    private static func openKimi(sessionId: String?) {
        guard !resolvingKimi else { return }
        resolvingKimi = true
        DispatchQueue.global(qos: .userInitiated).async {
            let resolution = KimiWebResolver().resolve(sessionId: sessionId)
            DispatchQueue.main.async {
                resolvingKimi = false
                if let destination = resolution.direct {
                    openKimiPage(destination.url)
                    return
                }
                if resolution.candidates.isEmpty && !resolution.unavailable {
                    _ = openHost(of: "kimi")
                    return
                }
                let alert = NSAlert()
                alert.messageText = "选择 Kimi 会话的打开位置"
                if resolution.candidates.isEmpty {
                    alert.informativeText = "本机 Kimi 网页服务暂不可用、未授权或无法读取这条会话。请检查原网页服务，或回到宿主终端。"
                } else if resolution.candidates.contains(where: \.confirmed) {
                    alert.informativeText = "这条会话在多个网页服务中打开，请选择要查看的位置。"
                } else {
                    alert.informativeText = sessionId == nil
                        ? "可打开本机 Kimi 网页，或回到宿主终端。"
                        : "尚未确认这条会话的原位置。可在网页查看已有记录，或回到宿主终端。"
                }
                for candidate in resolution.candidates {
                    alert.addButton(withTitle: "\(sessionId == nil ? "打开网页" : "在网页查看") · \(candidate.instance.port)")
                }
                alert.addButton(withTitle: "打开宿主终端")
                alert.addButton(withTitle: "取消")
                NSApp.activate(ignoringOtherApps: true)
                let index = alert.runModal().rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
                if resolution.candidates.indices.contains(index) {
                    openKimiPage(resolution.candidates[index].url)
                } else if index == resolution.candidates.count {
                    _ = openHost(of: "kimi")
                }
            }
        }
    }

    private static func openKimiPage(_ url: URL) {
        guard let browser = NSWorkspace.shared.urlForApplication(toOpen: url) else {
            explain("无法打开 Kimi 会话", detail: "请先配置默认浏览器。")
            return
        }
        guard prefersBrowserTabReuse() else {
            openInNewBrowserTab(url, browser: browser)
            return
        }
        DispatchQueue.global(qos: .userInitiated).async {
            // 复用失败（浏览器无脚本接口、未授权、超时、窗口序变化）都静默回落
            // 到原有新开标签页路径。
            if BrowserTabScriptRunner.reuse(url: url, browser: browser) { return }
            DispatchQueue.main.async { openInNewBrowserTab(url, browser: browser) }
        }
    }

    private static func openInNewBrowserTab(_ url: URL, browser: URL) {
        if openInDefaultChromiumProfile(url, browser: browser) { return }
        if #available(macOS 14, *), let bundleID = Bundle(url: browser)?.bundleIdentifier {
            NSApp.yieldActivation(toApplicationWithBundleIdentifier: bundleID)
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        configuration.createsNewApplicationInstance = false
        configuration.allowsRunningApplicationSubstitution = false
        NSWorkspace.shared.open([url], withApplicationAt: browser, configuration: configuration) { app, error in
            if error != nil || app == nil {
                DispatchQueue.main.async {
                    explain("无法打开 Kimi 会话", detail: "请检查默认浏览器和本机 Kimi 网页服务。")
                }
            }
        }
    }

    /// Launch Services can select a headless Chrome instance created by developer
    /// tools. Chromium's normal executable forwards URLs to its existing default
    /// profile through ProcessSingleton, without Apple Events automation access.
    private static func openInDefaultChromiumProfile(_ url: URL, browser: URL) -> Bool {
        guard let bundle = Bundle(url: browser),
              let bundleID = bundle.bundleIdentifier,
              ["com.google.Chrome", "com.microsoft.edgemac", "org.chromium.Chromium"].contains(bundleID),
              let executable = bundle.executableURL else { return false }
        let apps = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
        guard apps.count > 1 else { return false }
        let pids = Set(apps.map(\.processIdentifier))
        let lines = psLines().filter { pids.contains($0.pid) }.map { (pid: $0.pid, args: $0.args) }
        guard let pid = defaultChromiumProfilePID(lines), let app = apps.first(where: { $0.processIdentifier == pid }) else {
            return false
        }
        let process = Process()
        process.executableURL = executable
        process.arguments = [url.absoluteString]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { task in
            if task.terminationStatus != 0 {
                DispatchQueue.main.async {
                    explain("无法打开 Kimi 会话", detail: "请从默认浏览器打开本机 Kimi 网页后重试。")
                }
            }
        }
        do { try process.run() } catch { return false }
        app.unhide()
        _ = requestActivation(app)
        return true
    }

    static func defaultChromiumProfilePID(_ lines: [(pid: Int32, args: String)]) -> Int32? {
        func flags(_ args: String) -> [Substring] { args.split(whereSeparator: \.isWhitespace) }
        func headless(_ args: String) -> Bool {
            flags(args).contains { $0 == "--headless" || $0.hasPrefix("--headless=") }
        }
        guard lines.contains(where: { headless($0.args) }) else { return nil }
        let visible = lines.filter { !headless($0.args) }
        guard visible.count == 1,
              !flags(visible[0].args).contains(where: {
                  $0 == "--user-data-dir" || $0.hasPrefix("--user-data-dir=")
                      || $0 == "--profile-directory" || $0.hasPrefix("--profile-directory=")
              }) else { return nil }
        return visible[0].pid
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
        let kimiWebPIDs: Set<Int32> = name == "kimi" ? Set(KimiWebInstance.discover(
            home: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".kimi-code")
        ).map(\.pid)) : []
        let appByPID = Dictionary(NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }
            .map { ($0.processIdentifier, $0) }, uniquingKeysWith: { first, _ in first })
        let parents = Dictionary(lines.map { ($0.pid, $0.ppid) }, uniquingKeysWith: { first, _ in first })
        var hosts: [pid_t: Int] = [:]
        for line in lines where matches(line.args, name: name, excluding: excluding) || kimiWebPIDs.contains(line.pid) {
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

/// 通过 osascript 复用默认浏览器里已打开的 Kimi 同源标签页：命中则聚焦并
/// （会话目标时）导航过去，否则返回 false 交给调用方新开标签页。只支持带
/// 标签页脚本接口的浏览器（Chromium 系与 Safari）；授权、超时等一切失败都
/// 走回落，不影响原有路径。运行在后台线程。
private enum BrowserTabScriptRunner {
    private static let chromiumBundleIDs = ["com.google.Chrome", "com.microsoft.edgemac",
                                            "org.chromium.Chromium", "com.brave.Browser"]

    static func reuse(url: URL, browser: URL) -> Bool {
        guard let bundleID = Bundle(url: browser)?.bundleIdentifier,
            // 浏览器没在运行就没有可复用的标签页；枚举还会把它冷启动起来。
            NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
                .contains(where: { !$0.isTerminated }) else { return false }
        let safari = bundleID == "com.apple.Safari"
        guard safari || chromiumBundleIDs.contains(bundleID) else { return false }
        let fetch = """
        with timeout of 3 seconds
            tell application id "\(bundleID)"
                set out to ""
                set wcount to 0
                repeat with w in windows
                    set wcount to wcount + 1
                    set tcount to 0
                    repeat with t in tabs of w
                        set tcount to tcount + 1
                        try
                            set out to out & wcount & (character id 9) & tcount & (character id 9) & ((URL of t) as text) & linefeed
                        end try
                    end repeat
                end repeat
                return out
            end tell
        end timeout
        """
        guard let output = runScript(fetch) else { return false }
        switch BrowserTabReuse.plan(tabs: BrowserTabReuse.parseTabs(output), target: url) {
        case .newTab: return false
        case let .focus(tab): return act(bundleID: bundleID, safari: safari, tab: tab, navigate: nil)
        case let .navigate(tab, to: target): return act(bundleID: bundleID, safari: safari, tab: tab, navigate: target)
        }
    }

    /// 先核对目标标签页 URL 与枚举时一致：两段脚本之间窗口序变了就放弃复用，
    /// 绝不误碰别的标签页。
    private static func act(bundleID: String, safari: Bool, tab: BrowserTabAddress, navigate: String?) -> Bool {
        let tabRef = "tab \(tab.tabIndex) of window \(tab.windowIndex)"
        var statements = """
        if ((URL of \(tabRef)) as text) is not "\(escape(tab.url))" then return "stale"
        activate
        """
        // 两家浏览器的“置为当前标签”接口不同；导航都是改 tab 的 URL。
        statements += safari ? "\nset current tab of window \(tab.windowIndex) to \(tabRef)"
            : "\nset active tab index of window \(tab.windowIndex) to \(tab.tabIndex)"
        if let navigate {
            statements += "\nset URL of \(tabRef) to \"\(escape(navigate))\""
        }
        statements += """
        \ntry
            set index of window \(tab.windowIndex) to 1
        end try
        return "ok"
        """
        let script = """
        with timeout of 3 seconds
            tell application id "\(bundleID)"
                \(statements)
            end tell
        end timeout
        """
        return runScript(script) == "ok"
    }

    private static func escape(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    /// 运行一段 osascript；脚本内部 3 秒超时，进程级 5 秒强杀，任何失败返回 nil。
    private static func runScript(_ source: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", source]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let timeout = DispatchWorkItem { if process.isRunning { kill(process.processIdentifier, SIGKILL) } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 5, execute: timeout)
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        timeout.cancel()
        guard process.terminationStatus == 0 else { return nil }
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
