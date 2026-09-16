import Cocoa
import Combine
import CryptoKit
import ServiceManagement
import UserNotifications

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

/// 一次可自动安装的正式发布：GitHub Release 里的发布页、DMG 安装包与 sha256 校验文件。
struct ReleaseInfo: Equatable {
    let tag: String
    let pageURL: URL
    let dmgURL: URL
    let shaURL: URL
}

// MARK: - 登录项 / 更新维护

final class MaintenanceStore: ObservableObject {
    enum InstallPhase: Equatable {
        case downloading
        case verifying
        case installing
    }

    @Published var loginEnabled = false
    @Published var loginMessage = ""
    @Published var updateMessage = "检查 GitHub 上的正式发布版本"
    @Published var checking = false
    @Published var releaseURL: URL?
    /// 当前可一键安装的新版本；Release 缺少 DMG/校验资产时为 nil，仅保留发布页入口。
    @Published var update: ReleaseInfo?
    @Published var installPhase: InstallPhase?
    @Published var installProgress: Double = 0
    @Published var installError: String?
    private var notifiedUpdateTag: String?
    private var downloader: ReleaseDownloader?
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

    /// 查询正式发布版本。`notify` 为启动自动检查场景：发现新版本且系统允许时发一条提醒。
    func checkUpdates(notify: Bool = false) {
        guard !checking, installPhase == nil else { return }
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
            var info: ReleaseInfo?
            if let http = response as? HTTPURLResponse, http.statusCode == 200,
               let data, let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let tag = object["tag_name"] as? String, let latest = ReleaseVersion(tag),
               let link = object["html_url"] as? String, let url = URL(string: link),
               url.scheme == "https", url.host == "github.com",
               url.path.lowercased().hasPrefix("/stubsx/ai-statusbar/releases/"),
               object["draft"] as? Bool != true, object["prerelease"] as? Bool != true {
                let current = ReleaseVersion(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")
                let hasNewer = current.map { latest > $0 } ?? false
                message = current == nil ? "最新正式版本 \(tag)"
                    : hasNewer ? "发现新版本 \(tag)" : "当前已是最新版本（正式版 \(tag)）"
                release = url
                if hasNewer, let installable = Self.installableRelease(tag: tag, version: latest, pageURL: url, object: object) {
                    info = installable
                }
            } else if (response as? HTTPURLResponse)?.statusCode == 404 {
                message = "尚无可用的正式发布版本"
            }
            DispatchQueue.main.async {
                self?.checking = false
                self?.updateMessage = message
                self?.releaseURL = release
                self?.update = info
                if notify, let info { self?.announceUpdate(info) }
            }
        }.resume()
    }

    /// 从 Release 的 assets 里找自动安装需要的 DMG 与 sha256 校验文件（文件名由 scripts/release.sh 固定生成）。
    private static func installableRelease(tag: String, version: ReleaseVersion,
                                           pageURL: URL, object: [String: Any]) -> ReleaseInfo? {
        let dmgName = "Lingmou-\(version.parts.map(String.init).joined(separator: ".")).dmg"
        let assets = object["assets"] as? [[String: Any]] ?? []
        func assetURL(named name: String) -> URL? {
            for entry in assets where (entry["name"] as? String) == name {
                guard let link = entry["browser_download_url"] as? String, let url = URL(string: link),
                      url.scheme == "https", url.host == "github.com",
                      url.path.lowercased().hasPrefix("/stubsx/ai-statusbar/releases/download/")
                else { continue }
                return url
            }
            return nil
        }
        guard let dmg = assetURL(named: dmgName), let sha = assetURL(named: dmgName + ".sha256") else { return nil }
        return ReleaseInfo(tag: tag, pageURL: pageURL, dmgURL: dmg, shaURL: sha)
    }

    /// 新版本提醒：每个 tag 只发一次；系统未授权通知时静默跳过（设置页与菜单仍有入口）。
    private func announceUpdate(_ info: ReleaseInfo) {
        guard notifiedUpdateTag != info.tag else { return }
        notifiedUpdateTag = info.tag
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional
            else { return }
            let content = UNMutableNotificationContent()
            content.title = "灵眸有新版本"
            content.body = "\(info.tag) 已发布，点击立即更新。"
            content.sound = .default
            content.userInfo = ["lingmou_update": info.tag]
            UNUserNotificationCenter.current().add(
                UNNotificationRequest(identifier: "lingmou-update-\(info.tag)", content: content, trigger: nil)
            ) { error in
                if let error { NSLog("灵眸：更新提醒投递失败：\(error.localizedDescription)") }
            }
        }
    }

    // MARK: 一键更新：下载 → 校验 → 挂载 → 分离脚本替换重启

    func installUpdate() {
        guard let info = update, installPhase == nil else { return }
        installError = nil
        let bundleURL = Bundle.main.bundleURL
        guard !bundleURL.path.hasPrefix("/Volumes/") else {
            installError = "灵眸正在安装镜像里运行；请先把它拷入“应用程序”再更新。"
            return
        }
        guard !bundleURL.path.contains("'") else {
            installError = "当前路径含特殊字符，无法自动替换；请打开发布页手动下载。"
            return
        }
        guard FileManager.default.isWritableFile(atPath: bundleURL.deletingLastPathComponent().path) else {
            installError = "当前目录没有写入权限，无法自动替换；请打开发布页手动下载。"
            return
        }
        installPhase = .downloading
        installProgress = 0
        let workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("lingmou-update-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        } catch {
            failInstall("无法创建更新临时目录")
            return
        }
        // 先取校验和（小文件），成功后再下载安装包
        fetchText(info.shaURL) { [weak self] checksumText in
            guard let self else { return }
            guard let checksumText, let expected = Self.sha256Hex(in: checksumText) else {
                DispatchQueue.main.async { self.failInstall("下载或解析校验文件失败") }
                return
            }
            let dmgURL = workDir.appendingPathComponent("Lingmou.dmg")
            let downloader = ReleaseDownloader()
            self.downloader = downloader
            downloader.onProgress = { [weak self] value in
                DispatchQueue.main.async { self?.installProgress = value }
            }
            downloader.onComplete = { [weak self] savedURL in
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.downloader = nil
                    guard let savedURL else { self.failInstall("安装包下载失败，请稍后重试"); return }
                    self.verifyAndMount(dmg: savedURL, expected: expected, workDir: workDir, bundleURL: bundleURL)
                }
            }
            downloader.start(url: info.dmgURL, destination: dmgURL)
        }
    }

    private func fetchText(_ url: URL, completion: @escaping (String?) -> Void) {
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        request.setValue("Lingmou", forHTTPHeaderField: "User-Agent")
        URLSession.shared.dataTask(with: request) { data, response, _ in
            guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                  let data, let text = String(data: data, encoding: .utf8) else {
                completion(nil)
                return
            }
            completion(text)
        }.resume()
    }

    /// shasum 输出形如 "<64 位十六进制>  Lingmou-x.y.z.dmg"，取第一个合法哈希。
    private static func sha256Hex(in checksumText: String) -> String? {
        guard let token = checksumText.split(whereSeparator: { $0.isWhitespace }).first else { return nil }
        let hex = token.lowercased()
        return hex.count == 64 && hex.allSatisfy(\.isHexDigit) ? hex : nil
    }

    private static func sha256Hex(ofFile url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try? handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private func verifyAndMount(dmg: URL, expected: String, workDir: URL, bundleURL: URL) {
        installPhase = .verifying
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let actual = Self.sha256Hex(ofFile: dmg)
            DispatchQueue.main.async {
                guard let self else { return }
                guard let actual, actual == expected else {
                    self.failInstall("安装包校验不一致，已取消更新")
                    return
                }
                self.mount(dmg: dmg, workDir: workDir, bundleURL: bundleURL)
            }
        }
    }

    private func mount(dmg: URL, workDir: URL, bundleURL: URL) {
        installPhase = .installing
        let mountPoint = workDir.appendingPathComponent("mounted", isDirectory: true)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                try FileManager.default.createDirectory(at: mountPoint, withIntermediateDirectories: true)
                guard try Process.runCommand("/usr/bin/hdiutil",
                                             ["attach", dmg.path, "-nobrowse", "-readonly",
                                              "-mountpoint", mountPoint.path]) == 0 else {
                    throw NSError(domain: "lingmou.update", code: 1)
                }
                // 成功路径不在这里卸载：分离脚本拷贝完新包后才会 detach
                let newApp = mountPoint.appendingPathComponent("灵眸.app", isDirectory: true)
                guard FileManager.default.fileExists(atPath: newApp.path) else {
                    throw NSError(domain: "lingmou.update", code: 2)
                }
                try Self.spawnSwapScript(app: bundleURL, newApp: newApp,
                                         mountPoint: mountPoint, workDir: workDir)
                // 脚本已分离启动：它等待本进程退出后完成替换并重启灵眸
                DispatchQueue.main.async { NSApp.terminate(nil) }
            } catch {
                _ = try? Process.runCommand("/usr/bin/hdiutil", ["detach", mountPoint.path, "-quiet"])
                DispatchQueue.main.async { self?.failInstall("挂载或准备安装包失败") }
            }
        }
    }

    /// 生成并分离启动替换脚本。脚本等待旧进程退出 → 挪走旧包 → ditto 新包 → 启动新版 → 清理。
    /// 任一步失败都会把旧包放回原位，日志留在工作目录旁的 .swap.log 里。
    private static func spawnSwapScript(app: URL, newApp: URL, mountPoint: URL, workDir: URL) throws {
        let pid = ProcessInfo.processInfo.processIdentifier
        let scriptURL = URL(fileURLWithPath: workDir.path + ".swap.sh")
        let logURL = URL(fileURLWithPath: workDir.path + ".swap.log")
        let oldURL = URL(fileURLWithPath: workDir.path + ".old-app")
        let script = """
            #!/bin/sh
            APP='\(app.path)'
            SRC='\(newApp.path)'
            OLD='\(oldURL.path)'
            MNT='\(mountPoint.path)'
            WORK='\(workDir.path)'
            PID=\(pid)
            log() { echo "$(date '+%Y-%m-%d %H:%M:%S') $*" >> '\(logURL.path)'; }
            i=0
            while [ "$i" -lt 100 ] && kill -0 "$PID" 2>/dev/null; do
              sleep 0.2
              i=$((i+1))
            done
            if ! mv "$APP" "$OLD"; then
              log "替换失败：无法移动旧版（$APP）"
              exit 1
            fi
            if ! ditto "$SRC" "$APP"; then
              log "替换失败：无法安装新版，正在还原"
              mv "$OLD" "$APP" && log "已还原旧版"
              exit 1
            fi
            if ! open "$APP"; then
              log "新版已安装但启动失败，请手动打开 $APP"
            fi
            sleep 3
            rm -rf "$OLD"
            hdiutil detach "$MNT" -quiet
            rm -rf "$WORK"
            rm -f "$LOG" "$0"
            """
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: scriptURL.path)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [scriptURL.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
    }

    private func failInstall(_ message: String) {
        installPhase = nil
        installError = message
    }
}

// MARK: - 安装包下载（带进度）

private final class ReleaseDownloader: NSObject, URLSessionDownloadDelegate {
    var onProgress: ((Double) -> Void)?
    var onComplete: ((URL?) -> Void)?
    private var session: URLSession!
    private var destination: URL!
    private var finished = false

    func start(url: URL, destination: URL) {
        self.destination = destination
        session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
        session.downloadTask(with: url).resume()
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        onProgress?(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        finished = true
        session.finishTasksAndInvalidate()
        // location 指向的临时文件在本方法返回后就会被系统删除，必须先就地保存
        var saved: URL?
        do {
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: location, to: destination)
            saved = destination
        } catch {
            if (try? FileManager.default.copyItem(at: location, to: destination)) != nil {
                saved = destination
            }
        }
        onComplete?(saved)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard !finished, let error else { return }
        finished = true
        session.finishTasksAndInvalidate()
        NSLog("灵眸：更新安装包下载失败：\(error.localizedDescription)")
        onComplete?(nil)
    }
}

// MARK: - 命令行工具辅助

private extension Process {
    /// 运行外部命令并等待退出，返回退出码（stdout/stderr 丢弃，避免阻塞）。
    static func runCommand(_ launchPath: String, _ arguments: [String]) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }
}
