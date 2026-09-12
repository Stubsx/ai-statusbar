import Cocoa
import Combine
import ServiceManagement

struct ReleaseVersion: Comparable {
    let parts: [Int]
    init?(_ value: String) {
        let normalized = value.hasPrefix("v") ? String(value.dropFirst()) : value
        let pieces = normalized.split(separator: ".", omittingEmptySubsequences: false)
        guard pieces.count == 3 else { return nil }
        let numbers = pieces.compactMap { Int($0) }
        guard numbers.count == 3, numbers.allSatisfy({ $0 >= 0 }) else { return nil }
        parts = numbers
    }
    static func < (lhs: Self, rhs: Self) -> Bool { lhs.parts.lexicographicallyPrecedes(rhs.parts) }
}

final class MaintenanceStore: ObservableObject {
    @Published var loginEnabled = false
    @Published var loginMessage = ""
    @Published var updateMessage = "检查 GitHub 上的正式发布版本"
    @Published var checking = false
    @Published var releaseURL: URL?
    private let launchAgentName = "io.github.stubsx.lingmou.login"
    private var launchAgentURL: URL {
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/LaunchAgents/\(launchAgentName).plist")
    }

    init() { refreshLoginState() }

    func refreshLoginState() {
        if #available(macOS 13, *) {
            loginEnabled = SMAppService.mainApp.status == .enabled
            loginMessage = SMAppService.mainApp.status == .requiresApproval
                ? "需要在系统设置的登录项中允许灵眸" : "登录后自动显示灵眸"
        } else {
            loginEnabled = FileManager.default.fileExists(atPath: launchAgentURL.path)
            loginMessage = "通过本机登录项启动灵眸"
        }
    }

    func setLoginEnabled(_ enabled: Bool) {
        do {
            if #available(macOS 13, *) {
                if enabled { try SMAppService.mainApp.register() }
                else { try SMAppService.mainApp.unregister() }
            } else if enabled {
                guard let executable = Bundle.main.executableURL else { return }
                let property: [String: Any] = [
                    "Label": launchAgentName, "ProgramArguments": [executable.path],
                    "RunAtLoad": true, "LimitLoadToSessionType": "Aqua",
                ]
                let manager = FileManager.default
                try manager.createDirectory(at: launchAgentURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                try PropertyListSerialization.data(fromPropertyList: property, format: .xml, options: 0)
                    .write(to: launchAgentURL, options: .atomic)
                try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: launchAgentURL.path)
            } else if FileManager.default.fileExists(atPath: launchAgentURL.path) {
                try FileManager.default.removeItem(at: launchAgentURL)
            }
            refreshLoginState()
        } catch {
            refreshLoginState()
            loginMessage = "登录项设置失败；请将灵眸放在应用程序目录后重试"
        }
    }

    func openLoginSettings() {
        if #available(macOS 13, *) { SMAppService.openSystemSettingsLoginItems() }
        else { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preferences.users")!) }
    }

    func checkUpdates() {
        guard !checking else { return }
        checking = true
        releaseURL = nil
        updateMessage = "正在检查正式版本…"
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/Stubsx/ai-statusbar/releases/latest")!)
        request.timeoutInterval = 15
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Lingmou", forHTTPHeaderField: "User-Agent")
        URLSession.shared.dataTask(with: request) { [weak self] data, response, _ in
            var message = "暂时无法检查更新，请稍后重试"
            var release: URL?
            if let http = response as? HTTPURLResponse, http.statusCode == 200,
               let data, let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let tag = object["tag_name"] as? String, let latest = ReleaseVersion(tag),
               let link = object["html_url"] as? String, let url = URL(string: link),
               url.scheme == "https", url.host == "github.com",
               url.path.lowercased().hasPrefix("/stubsx/ai-statusbar/releases/"),
               object["draft"] as? Bool != true, object["prerelease"] as? Bool != true {
                let current = ReleaseVersion(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")
                message = current.map { latest > $0 ? "发现新版本 \(tag)" : "当前已是最新版本（正式版 \(tag)）" }
                    ?? "最新正式版本 \(tag)"
                release = url
            } else if (response as? HTTPURLResponse)?.statusCode == 404 {
                message = "尚无可用的正式发布版本"
            }
            DispatchQueue.main.async {
                self?.checking = false
                self?.updateMessage = message
                self?.releaseURL = release
            }
        }.resume()
    }
}
