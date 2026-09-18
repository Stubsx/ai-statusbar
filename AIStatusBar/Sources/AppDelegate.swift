import Cocoa
import Combine
import QuartzCore
import SwiftUI
import UserNotifications
import ScreenCaptureKit
import CryptoKit

// AppDelegate：菜单栏、面板、通知、屏幕采集适配等应用生命周期逻辑。

// MARK: - AppDelegate

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate,
    UNUserNotificationCenterDelegate
{
    private var statusItem: NSStatusItem!
    private var panel: NSPanel!
    private var hosting: DraggableHostingView<PanelView>!
    private var petPanel: NSPanel!
    private var petHosting: DraggableHostingView<PetView>!
    private var ballPanel: NSPanel!
    private var ballHosting: DraggableHostingView<FloatingBallView>!
    private var glassView: NSView?  // macOS 26+ 的 NSGlassEffectView（用 NSView 声明避开可用性注解）
    private var store: StatusStore!
    private let settings = SettingsStore()
    /// 登录项与更新维护：设置窗口与通知/菜单入口共享同一份状态
    private let maintenance = MaintenanceStore()
    /// 素材库目录跟随设置（默认本机 ~/.ai-statusbar/Pets，可指到 iCloud Drive 文件夹）。
    private lazy var petCatalog = PetCatalog(
        userPetsDirectory: PetCatalog.effectiveUserPetsDirectory(configuredPath: settings.petLibraryDir)
    )
    private var settingsWindow: NSWindow?
    private var activityToken: NSObjectProtocol?  // App Nap 防护 token，app 生命周期内持有
    private var fullscreenAutoHidden = false  // 当前是否因检测到全屏 App 而自动隐藏（区别于用户手动隐藏）
    private var fullscreenAutoHideSuppressed = false  // 用户在全屏期间手动重新显示后，本次会话内不再自动隐藏
    private var petDetailsExpanded = false
    private var lastDesktopMode: String?  // 上次 applyDesktopPresentationMode 处理过的桌面模式
    // 卡片模式收起态：悬浮球常驻，点击展开完整面板；鼠标离开面板 10 秒自动收回
    private var cardExpanded = false
    private var cardAutoCollapseTimer: Timer?
    private var cardOutsideSince: Date?  // 鼠标首次离开面板的时刻；回到面板内即清零
    private var panelTransitionToken = 0
    private var panelTransitioning = false
    private var panelSizeUpdatePending = false
    private var deferredPanelAppearance: (() -> Void)?
    private var restorePanelSizing: (() -> Void)?
    private var desktopMoveTimer: Timer?
    private var desktopAnchorMoving = false
    private var lastDesktopMoveTime: TimeInterval = 0
    private var pendingOriginKeys = Set<String>()
    private var observedAppearanceMode: String?
    private var cancellables: Set<AnyCancellable> = []  // 设置订阅（如桌宠大小）

    func applicationDidFinishLaunching(_ notification: Notification) {
        FloatingBallAppearance.migrateRemovedAppearance()
        // 通知 delegate 在启动时设置，托管横幅点击回调（跳转对应工具）
        UNUserNotificationCenter.current().delegate = self
        // 历史版本只在开关从关→开时请求一次系统授权，且忽略结果；若当时授权
        // 未完成（如签名身份变化），此后通知会被系统静默丢弃。启动时补查一次：
        // notDetermined 才真正弹系统授权框，已允许/已拒绝都不打扰用户。
        if settings.notifyEnabled || settings.experience.quotaAlerts {
            UNUserNotificationCenter.current().getNotificationSettings { s in
                if s.authorizationStatus == .notDetermined {
                    UNUserNotificationCenter.current().requestAuthorization(
                        options: [.alert, .sound]) { _, _ in }
                }
            }
        }
        let collectorPath = Bundle.main.path(forResource: "lingmou-collector", ofType: nil)
        store = StatusStore(collectorPath: collectorPath, settings: settings)
        NotificationRouter.prefersBrowserTabReuse = { [settings] in settings.kimiWebTabReuse }
        NotificationRouter.prefersKimiDesktopSessionNavigation = { [settings] in settings.kimiDesktopSessionNavigation }

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            MenuBarPresentation.update(button, data: nil, collectorError: nil, unreadCount: 0)
        }
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        buildPanel()
        buildPetPanel()
        buildBallPanel()
        applyDesktopPresentationMode()
        store.start()
        if !settings.experience.onboardingCompleted { showSettings(tab: "welcome") }
        // 启动自动检查更新：延迟 8 秒避开启动高峰，静默失败；发现新版本会发一次提醒
        if settings.autoUpdateCheck {
            DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
                guard let self, self.settings.autoUpdateCheck, self.maintenance.installPhase == nil else { return }
                self.maintenance.checkUpdates(notify: true)
            }
        }
        NotificationCenter.default.addObserver(self, selector: #selector(onStatusUpdated),
                                               name: .statusUpdated, object: nil)
        // 保持任务监测及时，但常驻组件不能阻止用户的 Mac 自动休眠。
        activityToken = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiatedAllowingIdleSystemSleep, .suddenTerminationDisabled, .automaticTerminationDisabled],
            reason: "监测本地 AI 任务状态")
    }

    // MARK: 通知点击路由

    /// 点击"任务完成"通知时跳到对应工具：App 型激活对应应用，
    /// CLI 型（Codex CLI / Kimi Code）回到跑着该进程的终端/编辑器窗口。
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        if response.actionIdentifier == UNNotificationDefaultActionIdentifier {
            let info = response.notification.request.content.userInfo
            DispatchQueue.main.async { [weak self] in
                defer { completionHandler() }
                // 更新提醒：打开设置并直接开始下载安装
                if info["lingmou_update"] != nil {
                    self?.showSettings(tab: "general")
                    self?.maintenance.installUpdate()
                    return
                }
                self?.store.openNotification(info) { [weak self] in self?.showTaskPanel(tab: "status") }
            }
        } else {
            completionHandler()
        }
    }

    /// 灵眸面板/设置恰好在前台时也照常弹横幅，避免操作面板时错过完成通知
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .list, .sound])
    }

    // MARK: 菜单栏标题

    @objc private func onStatusUpdated() {
        if let button = statusItem.button {
            MenuBarPresentation.update(button, data: store.data, collectorError: store.collectorError,
                                       unreadCount: store.attentionEvents.count)
        }
        guard store.data != nil else { return }

        // 过渡期间不争抢窗口尺寸；最后一次数据在动画完成后统一测量。
        if !panel.isVisible || panelTransitioning || desktopAnchorMoving {
            panelSizeUpdatePending = true
        } else {
            updatePanelSize()
        }
    }

    private func updatePanelSize() {
        guard !desktopAnchorMoving else {
            panelSizeUpdatePending = true
            return
        }
        panelSizeUpdatePending = false
        hosting.layout()
        let size = hosting.fittingSize
        if abs(panel.frame.height - size.height) > 1 || abs(panel.frame.width - size.width) > 1 {
            var f = panel.frame
            f.origin.y += f.size.height - size.height  // 保持顶边不动
            f.size = size
            if let screen = panel.screen ?? NSScreen.main {
                f.origin.x = max(screen.visibleFrame.minX, min(f.origin.x, screen.visibleFrame.maxX - size.width))
                f.origin.y = max(screen.visibleFrame.minY, min(f.origin.y, screen.visibleFrame.maxY - size.height))
            }
            panel.setFrame(f, display: true)
        }
    }

    // MARK: 面板配色跟随背景

    private var requestedCaptureAccess = false  // 每次启动只请求一次录屏权限

    /// 录屏授权弹框的去重键：当前签名证书的 SHA-1。
    /// TCC 授权跟随签名身份——换了证书（或 ad-hoc 重建）后系统视为新 app，会重新弹框；
    /// 对比"上次弹框时的证书哈希"，保证每个签名身份只自动弹一次，而不是每次启动都弹。
    /// ad-hoc 签名取不到证书链，统一归为 "adhoc"：宁可少弹，需要授权时走设置里的引导。
    private var capturePromptSignerKey: String {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return "unknown" }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return "unknown" }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let certs = (info as? [String: Any])?[kSecCodeInfoCertificates as String] as? [SecCertificate],
              let leaf = certs.first else { return "adhoc" }
        let der = SecCertificateCopyData(leaf) as Data
        return Insecure.SHA1.hash(data: der).map { String(format: "%02x", $0) }.joined()
    }
    private var appearanceCaptureGeneration: UInt = 0  // 丢弃异步返回的过期截图
    private var adaptiveAppearanceName: NSAppearance.Name?  // 滞回区内保持上次自适应判定
    /// 拖动触发的外观重检去抖任务（见 scheduleAppearanceRecheck）
    private var appearanceRecheckWorkItem: DispatchWorkItem?

    /// 调试日志：往 ~/.ai-statusbar/adapt-debug.log 追加一行（ISO 时间戳 + 消息），异常静默
    private func adaptLog(_ msg: String) {
        guard ProcessInfo.processInfo.environment["LINGMOU_DEBUG"] == "1" else { return }
        let dir = NSHomeDirectory() + "/.ai-statusbar"
        let path = dir + "/adapt-debug.log"
        let line = ISO8601DateFormatter().string(from: Date()) + " " + msg + "\n"
        guard let data = line.data(using: .utf8) else { return }
        do {
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            if !FileManager.default.fileExists(atPath: path) {
                FileManager.default.createFile(atPath: path, contents: nil)
            }
            let fh = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
            fh.seekToEndOfFile()
            fh.write(data)
            try fh.close()
        } catch {}
    }

    /// 面板外观模式：light / dark / system / adaptive（默认 system，跟随系统，不需要录屏权限）。
    /// 旧 Bool 键 panelAdaptiveAppearance 迁移只在这里做：true→adaptive，其余→system。
    private func panelAppearanceMode() -> String {
        if let m = UserDefaults.standard.string(forKey: "panelAppearanceMode") {
            return m
        }
        let legacy = UserDefaults.standard.object(forKey: "panelAdaptiveAppearance") as? Bool
        return legacy == true ? "adaptive" : "system"
    }

    /// 设置里确认启用"背景自适应"后立刻请求录屏权限；已授权则什么都不做。
    /// 系统授权框只在无 TCC 记录时弹一次，已有记录（曾拒绝/启动时已请求过）时静默返回，
    /// 因此延迟复查仍未授权就直接打开"录屏"设置页，保证用户总有地方可以开。
    func requestScreenCaptureAccessIfNeeded() {
        guard !CGPreflightScreenCaptureAccess() else { return }
        requestedCaptureAccess = true
        // 用户在设置里显式开启，允许重新弹框；同时记录签名身份，启动时的自动弹框保持安静
        UserDefaults.standard.set(capturePromptSignerKey, forKey: "capturePromptSigner")
        CGRequestScreenCaptureAccess()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            guard !CGPreflightScreenCaptureAccess(),
                  let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
            else { return }
            NSWorkspace.shared.open(url)
        }
    }

    /// 同步设置 SwiftUI、窗口和玻璃容器。macOS 26 的玻璃只改 appearance 不保证底色有足够反差，
    /// 因此深/浅外观同时给玻璃加方向一致的 tint；system 模式仍保留系统原生无 tint 行为。
    ///
    /// 文字不再先消失再出现；只插值底色。开关动画中先缓存最新外观请求。
    private func setPanelAppearance(_ name: NSAppearance.Name?) {
        if panelTransitioning || desktopAnchorMoving {
            deferredPanelAppearance = { [weak self] in self?.setPanelAppearance(name) }
            return
        }
        let appearance = name.flatMap { NSAppearance(named: $0) }
        let unchanged = hosting.appearance?.name == name
            && panel.appearance?.name == name
            && glassView?.appearance?.name == name
        guard !unchanged else { return }

        let layer = hosting.layer
        let oldBackground = layer?.presentation()?.backgroundColor ?? layer?.backgroundColor
        writePanelAppearance(name, appearance: appearance)
        if panel.isVisible, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
           let layer, let newBackground = layer.backgroundColor, newBackground != oldBackground {
            let anim = CABasicAnimation(keyPath: "backgroundColor")
            anim.fromValue = oldBackground
            anim.toValue = newBackground
            anim.duration = 0.20
            anim.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            layer.add(anim, forKey: "panelBackgroundFade")
        }
    }

    private func writePanelAppearance(_ name: NSAppearance.Name?, appearance: NSAppearance?) {
        hosting.appearance = appearance
        panel.appearance = appearance
        glassView?.appearance = appearance
        #if compiler(>=6.2)
        if #available(macOS 26.0, *), let glass = glassView as? NSGlassEffectView {
            switch name {
            case .darkAqua:
                glass.tintColor = NSColor.black.withAlphaComponent(0.25)
                // NSGlassEffectView 的 tint 很克制，白色窗口上仅靠 tint 不足以托住白字；
                // 在内容层后加半透明底色，仍保留玻璃纹理，同时保证文字对比度。
                hosting.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.52).cgColor
            case .aqua:
                glass.tintColor = NSColor.white.withAlphaComponent(0.20)
                hosting.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.50).cgColor
            default:
                glass.tintColor = nil
                hosting.layer?.backgroundColor = NSColor.clear.cgColor
            }
        }
        #endif
    }

    /// 统一入口：按模式应用面板外观。light/dark/system 直写（不发 SCK 请求，开销可忽略）；
    /// adaptive 走背景采样。定时器/拖动/切 app/切 Space/设置变更都调这里。
    /// window→glass/hosting 的 appearance 传导均不可靠，三者都要直写。
    /// 拖动期间的 didMove 以鼠标事件频率触发；adaptive 模式的背景采样是 SCK 截图
    ///（枚举窗口 + 截屏，单次数十毫秒），全速跟随会把截图服务打满、拖动明显掉帧。
    /// 这里做 trailing 去抖：连续拖动只保留最后一次采样（停 250ms 后执行），
    /// 原生窗口组拖动期间所有采样入口暂停，松手后再补采一次。
    private func scheduleAppearanceRecheck() {
        guard !desktopAnchorMoving else { return }
        appearanceRecheckWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.applyPanelAppearanceMode() }
        appearanceRecheckWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: item)
    }

    private func applyPanelAppearanceMode() {
        guard !desktopAnchorMoving else { return }
        appearanceCaptureGeneration &+= 1
        let generation = appearanceCaptureGeneration
        switch panelAppearanceMode() {
        case "light":
            adaptiveAppearanceName = nil
            setPanelAppearance(.aqua)
        case "dark":
            adaptiveAppearanceName = nil
            setPanelAppearance(.darkAqua)
        case "system":  // 恢复跟随系统
            adaptiveAppearanceName = nil
            setPanelAppearance(nil)
        default:
            adaptPanelAppearance(generation: generation)
        }
    }

    /// adaptive 模式：截取面板正下方区域算平均亮度，亮背景→深色配色，暗背景→浅色配色（反差保证可读）。
    /// CGWindowListCreateImage 在 macOS 15+ 已废弃且静默返回 nil，改用 ScreenCaptureKit。
    /// 采样图保持面板宽高比，避免 ScreenCaptureKit 的透明留边稀释亮度；
    /// 滞回防抖动：>=0.58 深 / <=0.42 浅 / 中间保持上次判定。
    private func adaptPanelAppearance(generation: UInt) {
        guard panel.isVisible else { return }  // 面板不可见直接返回，省电
        // SCScreenshotManager 需要 macOS 14；低版本静默降级（不动 appearance）
        guard #available(macOS 14.0, *) else { return }
        // 无录屏权限：每个签名身份只自动弹一次授权框（TCC 跟随签名证书，
        // 本地构建/下载的 release/CI 产物签名不同时各自是"新 app"，不能每次启动都弹）
        if !CGPreflightScreenCaptureAccess() {
            let prompted = UserDefaults.standard.string(forKey: "capturePromptSigner")
            if !requestedCaptureAccess, prompted != capturePromptSignerKey {
                requestedCaptureAccess = true
                UserDefaults.standard.set(capturePromptSignerKey, forKey: "capturePromptSigner")
                CGRequestScreenCaptureAccess()
                adaptLog("无录屏权限，已弹授权请求（每个签名身份仅自动弹一次），本次采样放弃")
            } else {
                adaptLog("无录屏权限（已申请过，等待授权），跳过本次采样")
            }
            return
        }
        // AppKit 坐标(左下原点) → Quartz 全局坐标(主屏左上原点)
        var rect = panel.frame
        let primaryTop = NSScreen.screens.first?.frame.maxY ?? 0
        rect.origin.y = primaryTop - rect.maxY
        SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: true) { [weak self] content, error in
            guard let self else { return }
            if let error {
                self.adaptLog("SCShareableContent 失败: \(error.localizedDescription)")
                return
            }
            guard let content else { return }
            // 跨屏边缘时选择与面板相交面积最大的显示器，并把采样范围裁进该显示器。
            guard let display = content.displays
                .filter({ $0.frame.intersects(rect) })
                .max(by: {
                    let lhs = $0.frame.intersection(rect)
                    let rhs = $1.frame.intersection(rect)
                    return lhs.width * lhs.height < rhs.width * rhs.height
                })
            else {
                self.adaptLog("找不到相交 display: rect=\(rect) displays=\(content.displays.count)")
                return
            }
            let captureRect = rect.intersection(display.frame)
            guard !captureRect.isNull, captureRect.width > 0, captureRect.height > 0 else { return }
            // 排除自己 app 的窗口，避免采到面板自身
            let own = content.windows.filter {
                $0.owningApplication?.bundleIdentifier == Bundle.main.bundleIdentifier
            }
            let filter = SCContentFilter(display: display, excludingWindows: own)
            let config = SCStreamConfiguration()
            config.sourceRect = captureRect.offsetBy(dx: -display.frame.origin.x,
                                                     dy: -display.frame.origin.y)
            // 24 像素长边已足够判断整体明暗，同时让输出宽高比贴近采样区域。
            let longSide = 24.0
            if captureRect.width >= captureRect.height {
                config.width = Int(longSide)
                config.height = max(1, Int((longSide * captureRect.height / captureRect.width).rounded()))
            } else {
                config.height = Int(longSide)
                config.width = max(1, Int((longSide * captureRect.width / captureRect.height).rounded()))
            }
            // 明确填满目标小图；比例已在上方保持，关闭系统默认留边可避免透明黑边参与统计。
            config.preservesAspectRatio = false
            config.showsCursor = false
            SCScreenshotManager.captureImage(contentFilter: filter, configuration: config) { image, error in
                if let error {
                    self.adaptLog("captureImage 失败: \(error.localizedDescription)")
                    return
                }
                guard let image else { return }
                DispatchQueue.main.async {
                    // 截图异步完成前可能已切换模式/背景，只允许最新请求生效。
                    guard self.appearanceCaptureGeneration == generation,
                          self.panelAppearanceMode() == "adaptive"
                    else { return }
                    self.applyAppearance(for: image)
                }
            }
        }
    }

    /// 把小图转换为 RGBA，忽略透明填充并对预乘 alpha 反算真实颜色。
    /// 对亮度排序后裁掉两端各 10%，降低少量高亮/阴影内容对整张卡片判定的干扰。
    private func backgroundLuminance(for image: CGImage) -> (value: Double, valid: Int, total: Int)? {
        let width = image.width
        let height = image.height
        guard width > 0, height > 0 else { return nil }
        let bytesPerRow = width * 4
        var pixels = [UInt8](repeating: 0, count: bytesPerRow * height)
        let bitmapInfo = CGBitmapInfo.byteOrder32Big.rawValue
            | CGImageAlphaInfo.premultipliedLast.rawValue
        guard let ctx = CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8,
                                  bytesPerRow: bytesPerRow, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: bitmapInfo)
        else { return nil }
        ctx.interpolationQuality = .medium
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        var luminances: [Double] = []
        luminances.reserveCapacity(width * height)
        for i in stride(from: 0, to: pixels.count, by: 4) {
            let alpha = Double(pixels[i + 3]) / 255
            guard alpha >= 0.05 else { continue }  // 透明留边或无内容区域
            // CGContext 输出 premultipliedLast；反预乘后才是屏幕内容自身的颜色。
            let red = min(1, Double(pixels[i]) / 255 / alpha)
            let green = min(1, Double(pixels[i + 1]) / 255 / alpha)
            let blue = min(1, Double(pixels[i + 2]) / 255 / alpha)
            luminances.append(0.2126 * red + 0.7152 * green + 0.0722 * blue)
        }

        let total = width * height
        // 有效内容太少时不猜测，维持当前外观并等待下次采样。
        guard luminances.count >= max(4, total / 8) else { return nil }
        luminances.sort()
        let trim = luminances.count >= 20 ? luminances.count / 10 : 0
        let kept = luminances[trim..<(luminances.count - trim)]
        return (kept.reduce(0, +) / Double(kept.count), luminances.count, total)
    }

    /// 主线程：按背景亮度和滞回阈值切换 hosting/panel/glass 的 appearance。
    private func applyAppearance(for image: CGImage) {
        guard let sample = backgroundLuminance(for: image) else {
            adaptLog("有效背景像素不足，保持现状")
            return
        }
        let lum = sample.value
        let lumStr = String(format: "%.2f", lum)
        // macOS 26 实测：window.appearance 经 NSGlassEffectView 传到 NSHostingView 的链路断了，
        // .preferredColorScheme 动态更新对已渲染的 hosting view 也不生效（仅静态初始值有效）；
        // 唯一直写 hosting.appearance 立即生效（SwiftUI colorScheme 随之翻转），故以它为主通道；
        // window→glass 的传导同样不可靠，glassView 也要直写（玻璃背景明暗），panel.appearance 作副通道
        let appearanceName: NSAppearance.Name
        if lum >= 0.58 {
            appearanceName = .darkAqua
        } else if lum <= 0.42 {
            appearanceName = .aqua
        } else if let previous = adaptiveAppearanceName {
            appearanceName = previous
        } else {
            // 首次进入 adaptive 时不能没有结论；中点只用于首次判定，之后由滞回保持稳定。
            appearanceName = lum >= 0.5 ? .darkAqua : .aqua
        }
        adaptiveAppearanceName = appearanceName
        let changed = hosting.appearance?.name != appearanceName
        // 即使文字外观已相同，也同步一次玻璃 tint/内容底色，覆盖“系统原本就是该外观”的启动场景。
        setPanelAppearance(appearanceName)
        if changed {
            adaptLog("亮度 \(lumStr)（有效 \(sample.valid)/\(sample.total)），切换 \(appearanceName.rawValue)")
        } else {
            adaptLog("亮度 \(lumStr)（有效 \(sample.valid)/\(sample.total)），已是目标外观")
        }
    }

    // MARK: 菜单

    func menuNeedsUpdate(_ menu: NSMenu) {
        populateStatusMenu(menu, store: store)
    }

    func populateStatusMenu(_ menu: NSMenu, store: StatusStore) {
        menu.removeAllItems()
        if let error = store.collectorError {
            let item = NSMenuItem(title: "状态暂未更新 · 查看原因",
                                  action: #selector(openMenuConnections), keyEquivalent: "")
            item.target = self
            item.image = symbol("exclamationmark.circle", color: .systemOrange)
            item.toolTip = error
            menu.addItem(item)
            menu.addItem(.separator())
        }
        if store.data != nil || !store.recentEvents.isEmpty {
            MenuBarPresentation.appendTools(to: menu, tools: store.data?.tools ?? [],
                                            events: store.recentEvents, target: self,
                                            openTool: #selector(openTool(_:)),
                                            openConnections: #selector(openMenuConnections),
                                            displayTitle: { store.displayTitle($0) })
        } else if store.collectorError == nil {
            let loading = NSMenuItem(title: "正在读取工具状态…", action: nil, keyEquivalent: "")
            loading.image = symbol("hourglass", template: true)
            menu.addItem(loading)
        }
        if menu.items.last?.isSeparatorItem == false { menu.addItem(.separator()) }

        let desktop = NSMenuItem(title: "桌面显示", action: nil, keyEquivalent: "")
        desktop.image = symbol("rectangle.on.rectangle", template: true)
        desktop.submenu = buildDesktopDisplayMenu()
        menu.addItem(desktop)
        menu.addItem(.separator())

        let settingsItem = NSMenuItem(title: "设置…", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        settingsItem.image = symbol("gearshape", template: true)
        menu.addItem(settingsItem)
        if let update = maintenance.update {
            let updating = maintenance.installPhase != nil
            let item = NSMenuItem(title: updating ? "正在更新灵眸…" : "更新到 \(update.tag)…",
                                  action: updating ? nil : #selector(openUpdateSettings),
                                  keyEquivalent: "")
            item.target = self
            item.image = symbol("arrow.up.circle", template: true)
            menu.addItem(item)
        }
        let refresh = NSMenuItem(title: "刷新状态", action: #selector(doRefresh), keyEquivalent: "r")
        refresh.target = self
        refresh.image = symbol("arrow.clockwise", template: true)
        menu.addItem(refresh)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "退出灵眸", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.target = NSApp
        quit.image = symbol("power", template: true)
        menu.addItem(quit)
    }

    private func buildDesktopDisplayMenu() -> NSMenu {
        let menu = NSMenu()
        let panelItem = NSMenuItem(title: "打开桌面面板", action: #selector(openTaskCenter), keyEquivalent: "1")
        panelItem.target = self
        panelItem.image = symbol("eye", template: true)
        menu.addItem(panelItem)
        menu.addItem(.separator())
        let mode = desktopPresentationMode
        for (title, value, action) in [("桌面卡片", "card", #selector(selectCardMode)),
                                       ("桌面宠物", "pet", #selector(selectPetMode)),
                                       ("隐藏", "hidden", #selector(selectHiddenMode))] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            item.state = mode == value ? .on : .off
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let pinned = UserDefaults.standard.object(forKey: "panelPinned") == nil
            ? true : UserDefaults.standard.bool(forKey: "panelPinned")
        let pin = NSMenuItem(title: "置顶桌面显示", action: #selector(togglePin), keyEquivalent: "t")
        pin.target = self
        pin.image = symbol("pin", template: true)
        pin.state = pinned ? .on : .off
        menu.addItem(pin)
        let fullscreenHide = NSMenuItem(title: "全屏时自动隐藏", action: #selector(toggleAutoHideFullscreen), keyEquivalent: "")
        fullscreenHide.target = self
        fullscreenHide.image = symbol("arrow.up.left.and.arrow.down.right", template: true)
        fullscreenHide.state = autoHideInFullscreenEnabled ? .on : .off
        menu.addItem(fullscreenHide)
        return menu
    }

    @objc private func openMenuConnections() { showSettings(tab: "connections") }

    // MARK: 桌面浮窗

    private func buildPanel() {
        // macOS 26+：用 AppKit 官方液态玻璃 NSGlassEffectView 做容器
        var systemGlass = false
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) { systemGlass = true }
        #endif
        hosting = DraggableHostingView(rootView: PanelView(store: store, bare: systemGlass))
        hosting.wantsLayer = true
        hosting.layer?.backgroundColor = NSColor.clear.cgColor  // 防止透明窗口边缘泛灰
        hosting.layer?.cornerRadius = 18
        hosting.layer?.masksToBounds = true
        // 面板右键菜单：点任意位置（含空白处）都能弹出，复用菜单栏已有的 togglePin 逻辑
        hosting.contextMenuBuilder = { [weak self] in
            self?.buildPanelContextMenu() ?? NSMenu()
        }
        panel = TaskPanel(contentRect: NSRect(x: 0, y: 0, width: 320, height: 200),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.identifier = NSUserInterfaceItemIdentifier("AIStatusPanel")
        panel.animationBehavior = .none  // 仅由下面的统一过渡驱动，避免系统开关动画叠加。
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView(frame: NSRect(x: 0, y: 0, width: 320, height: 200))
            glass.cornerRadius = 18
            glass.contentView = hosting
            panel.contentView = glass
            glassView = glass  // 持有引用：window→glass 的 appearance 传导不可靠，需直写
        } else {
            panel.contentView = hosting
        }
        #else
        panel.contentView = hosting
        #endif
        panel.contentView?.wantsLayer = true
        let pinned = UserDefaults.standard.object(forKey: "panelPinned") == nil
            ? true : UserDefaults.standard.bool(forKey: "panelPinned")
        panel.isFloatingPanel = pinned
        panel.level = pinned ? .floating : .normal
        panel.collectionBehavior = pinned ? [.canJoinAllSpaces, .fullScreenAuxiliary] : []
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.isMovableByWindowBackground = true  // 原生拖动：系统处理，不抖不丢帧
        panel.acceptsMouseMovedEvents = true    // 保证热力图 hover 生效
        // 拖动结束（含实时拖动过程中）：卡片模式下面板位置由悬浮球推导、
        // 桌宠模式临时跟随，均不持久化；只做背景亮度重采（去抖，见该方法注释）
        NotificationCenter.default.addObserver(forName: NSWindow.didMoveNotification,
                                               object: panel, queue: .main) { [weak self] _ in
            guard let self else { return }
            // 子窗口已由 AppKit 同步移动，不再反向触发定位与截图请求。
            if self.panel.parent == nil { self.scheduleAppearanceRecheck() }
        }
        NotificationCenter.default.addObserver(forName: NSWindow.didResizeNotification,
                                               object: panel, queue: .main) { [weak self] _ in
            guard let self, self.panel.parent != nil else { return }
            guard !self.desktopAnchorMoving, !self.panelTransitioning else {
                self.panelSizeUpdatePending = true
                return
            }
            if self.petDetailsExpanded { self.positionDetailsPanelNextToPet() }
            if self.cardExpanded { self.positionCardPanelNextToBall() }
        }

        // 面板外观：每 3 秒走一次模式入口（adaptive 模式下检测面板下方亮度）
        let appearanceTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            self?.applyPanelAppearanceMode()
        }
        appearanceTimer.tolerance = 0.3
        RunLoop.main.add(appearanceTimer, forMode: .common)
        // 事件驱动补采样：前台 app 切换 / 切 Space 时背景内容大概率变了，即时重检
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] _ in
            self?.applyPanelAppearanceMode()
            self?.updateFullscreenAutoHide()
        }
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.applyPanelAppearanceMode()
            self?.updateFullscreenAutoHide()
        }
        // 全屏自动隐藏：进出原生全屏伴随切 Space 事件可即时响应；网页全屏（不切 Space、
        // 只改窗口尺寸）没有系统通知，靠轮询兜底。5 秒粒度足够——进入只晚几秒隐藏，
        // 又把每秒一次的 WindowServer 窗口列表往返降下来，减少常驻唤醒。
        let fullscreenTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            self?.updateFullscreenAutoHide()
        }
        fullscreenTimer.tolerance = 0.5
        RunLoop.main.add(fullscreenTimer, forMode: .common)
        // 设置改动（外观模式切换）立即生效，不等下个 3 秒周期
        NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            let appearance = self.panelAppearanceMode()
            if appearance != self.observedAppearanceMode {
                self.observedAppearanceMode = appearance
                self.applyPanelAppearanceMode()
            }
            if self.desktopPresentationMode != self.lastDesktopMode {
                self.applyDesktopPresentationMode()
            }
        }

        hosting.layout()
        panel.setContentSize(hosting.fittingSize)
    }

    /// 桌宠使用独立透明窗口，与详情卡片分别保存位置和尺寸。
    /// 这样展开卡片时不会让宠物本身突然缩放或跳位。
    private func buildPetPanel() {
        petHosting = DraggableHostingView(
            rootView: PetView(store: store, settings: settings, catalog: petCatalog) { [weak self] in
                self?.togglePetDetails()
            }
        )
        petHosting.wantsLayer = true
        petHosting.layer?.backgroundColor = NSColor.clear.cgColor
        petHosting.contextMenuBuilder = { [weak self] in
            self?.buildPetContextMenu() ?? NSMenu()
        }

        petPanel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 220, height: 236),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        petPanel.identifier = NSUserInterfaceItemIdentifier("AIStatusPetPanel")
        petPanel.contentView = petHosting
        petPanel.backgroundColor = .clear
        petPanel.isOpaque = false
        petPanel.hasShadow = false
        petPanel.hidesOnDeactivate = false
        petPanel.isReleasedWhenClosed = false
        petPanel.isMovableByWindowBackground = true
        petPanel.acceptsMouseMovedEvents = true
        applyWindowLevel(to: petPanel)

        NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification,
            object: petPanel,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            self.desktopAnchorDidMove(originKey: "petOrigin")
        }
        NotificationCenter.default.addObserver(forName: NSWindow.didResizeNotification,
                                               object: petPanel, queue: .main) { [weak self] _ in
            self?.desktopAnchorDidMove(originKey: "petOrigin")
        }

        // 桌宠大小可调：窗口尺寸由这里按比例手动驱动（底边锚定，脚底位置不动），
        // 不交给 NSHostingView 自适应——那条路径锚定方向不受控，会与底边锚定打架
        if #available(macOS 13.0, *) {
            petHosting.sizingOptions = []
        }
        petPanel.setContentSize(Self.petPanelSize(scale: CGFloat(settings.petScale)))
        settings.$petScale
            .dropFirst()
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] scale in
                guard let self, let petPanel = self.petPanel else { return }
                let size = Self.petPanelSize(scale: CGFloat(scale))
                guard abs(petPanel.frame.height - size.height) > 0.5
                    || abs(petPanel.frame.width - size.width) > 0.5
                else { return }
                // AppKit 原点即窗口底边：origin 不动，脚底天然稳定，只改尺寸
                var f = petPanel.frame
                f.size = size
                petPanel.setFrame(f, display: true)
            }
            .store(in: &cancellables)
        restoreWindowPosition(petPanel, key: "petOrigin") { screen, size in
            NSPoint(
                x: screen.visibleFrame.maxX - size.width - 24,
                y: screen.visibleFrame.minY + 24
            )
        }
    }

    /// 桌宠基础尺寸（与 PetView 固定 frame 一致）按比例缩放后的窗口尺寸。
    /// 气泡改浮层后窗口只包形象本体（236），顶部不再为提示预留 30pt。
    private static func petPanelSize(scale: CGFloat) -> NSSize {
        NSSize(width: 220 * scale, height: 236 * scale)
    }

    private func restoreWindowPosition(
        _ window: NSWindow,
        key: String,
        defaultOrigin: (NSScreen, NSSize) -> NSPoint
    ) {
        guard let fallbackScreen = NSScreen.main ?? NSScreen.screens.first else { return }
        let saved = UserDefaults.standard.string(forKey: key).map(NSPointFromString)
        let requested = saved ?? defaultOrigin(fallbackScreen, window.frame.size)
        let requestedFrame = NSRect(origin: requested, size: window.frame.size)
        let screen = NSScreen.screens.first(where: { $0.visibleFrame.intersects(requestedFrame) })
            ?? fallbackScreen
        let visible = screen.visibleFrame
        let maxX = max(visible.minX, visible.maxX - window.frame.width)
        let maxY = max(visible.minY, visible.maxY - window.frame.height)
        let clamped = NSPoint(
            x: min(max(requested.x, visible.minX), maxX),
            y: min(max(requested.y, visible.minY), maxY)
        )
        window.setFrameOrigin(clamped)
    }

    // MARK: 悬浮球（卡片模式收起态）

    /// 悬浮球是卡片模式的常驻窗口：固定尺寸容纳顶部状态胶囊，独立记忆位置（默认屏幕右下角，
    /// 与桌宠默认位一致）。完整面板只在展开期间出现，位置始终从球推导。
    private func buildBallPanel() {
        ballHosting = DraggableHostingView(
            rootView: FloatingBallView(store: store) { [weak self] in
                self?.toggleCardPanel()
            }
        )
        ballHosting.wantsLayer = true
        ballHosting.layer?.backgroundColor = NSColor.clear.cgColor
        ballHosting.contextMenuBuilder = { [weak self] in
            self?.buildBallContextMenu() ?? NSMenu()
        }

        ballPanel = NSPanel(
            contentRect: NSRect(origin: .zero, size: FloatingBallStatusArtwork.size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        ballPanel.identifier = NSUserInterfaceItemIdentifier("AIStatusBallPanel")
        ballPanel.contentView = ballHosting
        ballPanel.backgroundColor = .clear
        ballPanel.isOpaque = false
        // 阴影由 SwiftUI 球体自带（圆形轮廓），窗口阴影会按矩形画边，关掉
        ballPanel.hasShadow = false
        ballPanel.hidesOnDeactivate = false
        ballPanel.acceptsMouseMovedEvents = true
        ballPanel.isReleasedWhenClosed = false
        ballPanel.isMovableByWindowBackground = true
        applyWindowLevel(to: ballPanel)

        // 展开期间拖动球，面板像挂件一样跟着走（与桌宠拖动跟随同一体验）
        NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification,
            object: ballPanel,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            self.desktopAnchorDidMove(originKey: "ballOrigin")
        }

        // 窗口尺寸固定，不交给 NSHostingView 自适应（与桌宠窗口同一策略）
        if #available(macOS 13.0, *) {
            ballHosting.sizingOptions = []
        }
        restoreWindowPosition(ballPanel, key: "ballOrigin") { screen, size in
            NSPoint(
                x: screen.visibleFrame.maxX - size.width - 24,
                y: screen.visibleFrame.minY + 24
            )
        }
    }

    /// 悬浮球点击：展开 / 收起完整面板（右键菜单与面板内菜单共用同一动作）
    @objc private func toggleCardPanel() {
        guard desktopPresentationMode == "card" else { return }
        if cardExpanded {
            collapseCardPanel()
            return
        }
        cardExpanded = true
        if !panel.isVisible {
            updatePanelSize()
            positionCardPanelNextToBall()
        }
        transitionPanel(visible: true)
        cardOutsideSince = nil
        updateCardAutoCollapseTimer()
        scheduleAppearanceRecheck()  // 面板换位后重采背景亮度
    }

    /// 收回到悬浮球：淡出后隐藏；若期间又重新展开（completion 里再校验），不打断
    @objc private func collapseCardPanel() {
        guard cardExpanded else { return }
        cardExpanded = false
        updateCardAutoCollapseTimer()
        transitionPanel(visible: false)
    }

    /// 固定玻璃窗口位置，只在合成层淡入/淡出；反向点击从当前呈现透明度接续。
    private func transitionPanel(visible: Bool) {
        guard let layer = panel.contentView?.layer else {
            if visible { panel.orderFront(nil) } else { panel.orderOut(nil) }
            return
        }
        panelTransitionToken &+= 1
        let token = panelTransitionToken
        let from = panel.isVisible ? (layer.presentation()?.opacity ?? layer.opacity) : 0
        let target: Float = visible ? 1 : 0
        let duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            ? 0 : Double(abs(target - from)) * (visible ? 0.20 : 0.16)
        panelTransitioning = true
        freezePanelSizing()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.removeAnimation(forKey: "panelVisibility")
        layer.opacity = target
        if duration > 0.001 {
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = from
            fade.toValue = target
            fade.duration = duration
            fade.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            layer.add(fade, forKey: "panelVisibility")
        }
        CATransaction.commit()
        if visible {
            panel.orderFront(nil)
            syncPanelAttachment()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + duration) { [weak self] in
            guard let self, self.panelTransitionToken == token else { return }
            self.panelTransitioning = false
            if !visible {
                self.detachPanel()
                self.panel.orderOut(nil)
            }
            self.restorePanelSizingIfIdle()
            if self.panelSizeUpdatePending { self.updatePanelSize() }
            let appearance = self.deferredPanelAppearance
            self.deferredPanelAppearance = nil
            appearance?()
        }
    }

    private func cancelPanelTransition() {
        panelTransitionToken &+= 1
        panelTransitioning = false
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        panel.contentView?.layer?.removeAnimation(forKey: "panelVisibility")
        panel.contentView?.layer?.opacity = 1
        CATransaction.commit()
        restorePanelSizingIfIdle()
        if panelSizeUpdatePending { updatePanelSize() }
        let appearance = deferredPanelAppearance
        deferredPanelAppearance = nil
        appearance?()
    }

    /// 展开的面板优先放在球的正上方，屏幕顶不够时翻到球下方，始终收进可见区域
    private func positionCardPanelNextToBall() {
        guard !desktopAnchorMoving else { return }
        guard let panel, let ballPanel else { return }
        // 消息在窗口右侧展开，面板仍对齐球体的原有中心。
        let ball = NSRect(origin: ballPanel.frame.origin, size: FloatingBallStatusArtwork.anchorSize)
        let screen = screenContainingMost(of: ball)
            ?? NSScreen.main
            ?? NSScreen.screens.first
        guard let screen else { return }
        let visible = screen.visibleFrame
        let size = panel.frame.size
        var origin = NSPoint(x: ball.midX - size.width / 2, y: ball.maxY + 12)
        if origin.y + size.height > visible.maxY {
            origin.y = ball.minY - 12 - size.height
        }
        origin.x = min(max(origin.x, visible.minX + 4), max(visible.minX, visible.maxX - size.width - 4))
        origin.y = min(max(origin.y, visible.minY + 4), max(visible.minY, visible.maxY - size.height - 4))
        if panel.frame.origin != origin { panel.setFrameOrigin(origin) }
    }

    /// 自动收回计时：鼠标离开面板连续 10 秒即收回到悬浮球；回到面板内清零重计。
    /// 用 1Hz 取点轮询代替 tracking area——面板内容高度随状态自适应变化，
    /// tracking 区维护复杂，而每秒一次的矩形包含判断开销可忽略。
    private let cardAutoCollapseInterval: TimeInterval = 10
    private func updateCardAutoCollapseTimer() {
        cardAutoCollapseTimer?.invalidate()
        cardAutoCollapseTimer = nil
        guard cardExpanded, desktopPresentationMode == "card" else {
            cardOutsideSince = nil
            return
        }
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            guard let self, self.cardExpanded else { return }
            guard !self.desktopAnchorMoving else {
                self.cardOutsideSince = nil
                return
            }
            if self.panel.isKeyWindow || self.panel.frame.contains(NSEvent.mouseLocation) {
                self.cardOutsideSince = nil
            } else {
                let since = self.cardOutsideSince ?? Date()
                self.cardOutsideSince = since
                if Date().timeIntervalSince(since) >= self.cardAutoCollapseInterval {
                    self.collapseCardPanel()
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        cardAutoCollapseTimer = timer
    }

    /// 桌宠模式的详情卡优先放在宠物右侧，空间不足时自动换到左侧，
    /// 并始终限制在宠物所在屏幕的可见区域内。
    private func positionDetailsPanelNextToPet() {
        guard !desktopAnchorMoving else { return }
        guard let panel, let petPanel else { return }
        let petFrame = petPanel.frame
        let screen = screenContainingMost(of: petFrame)
            ?? NSScreen.main
            ?? NSScreen.screens.first
        guard let screen else { return }

        let visible = screen.visibleFrame
        let size = panel.frame.size
        let gap: CGFloat = 14
        let rightX = petFrame.maxX + gap
        let leftX = petFrame.minX - size.width - gap
        let rightFits = rightX + size.width <= visible.maxX
        let leftFits = leftX >= visible.minX

        let requestedX: CGFloat
        if rightFits {
            requestedX = rightX
        } else if leftFits {
            requestedX = leftX
        } else {
            let rightSpace = visible.maxX - petFrame.maxX
            let leftSpace = petFrame.minX - visible.minX
            requestedX = rightSpace >= leftSpace ? rightX : leftX
        }

        let maxX = max(visible.minX, visible.maxX - size.width)
        let maxY = max(visible.minY, visible.maxY - size.height)
        let origin = NSPoint(
            x: min(max(requestedX, visible.minX), maxX),
            y: min(max(petFrame.midY - size.height / 2, visible.minY), maxY)
        )
        if panel.frame.origin != origin { panel.setFrameOrigin(origin) }
        scheduleAppearanceRecheck()  // 跟随拖动会高频触发本方法，采样去抖防掉帧
    }

    private var desktopPresentationMode: String {
        let defaults = UserDefaults.standard
        if let mode = defaults.string(forKey: "desktopPresentationMode"),
           ["card", "pet", "hidden"].contains(mode) {
            return mode
        }
        // 旧版只有 panelVisible；首次升级时保留用户原来的显示选择。
        let legacyVisible = defaults.object(forKey: "panelVisible") == nil
            ? true : defaults.bool(forKey: "panelVisible")
        let migrated = legacyVisible ? "card" : "hidden"
        defaults.set(migrated, forKey: "desktopPresentationMode")
        return migrated
    }

    private func setDesktopPresentationMode(_ mode: String) {
        UserDefaults.standard.set(mode, forKey: "desktopPresentationMode")
        applyDesktopPresentationMode()
    }

    private func applyWindowLevel(to window: NSPanel) {
        let pinned = UserDefaults.standard.object(forKey: "panelPinned") == nil
            ? true : UserDefaults.standard.bool(forKey: "panelPinned")
        window.isFloatingPanel = pinned
        window.level = pinned ? .floating : .normal
        window.collectionBehavior = pinned ? [.canJoinAllSpaces, .fullScreenAuxiliary] : []
    }

    private func hideDesktopWindows() {
        detachPanel()
        panel?.orderOut(nil)
        finishDesktopMovement(reposition: false)
        cancelPanelTransition()
        petPanel?.orderOut(nil)
        ballPanel?.orderOut(nil)
    }

    private func applyDesktopPresentationMode() {
        guard panel != nil, petPanel != nil, ballPanel != nil else { return }
        let mode = desktopPresentationMode
        // 页签/用量范围等 @AppStorage 写入也会触发本方法（UserDefaults.didChange），
        // 此时窗口尺寸正随内容自适应（顶边锚定）；若每次都恢复记忆位置或重摆详情卡，
        // 会把窗口拽回旧 origin，顶边来回跳。只在模式真正切换时才动位置。
        let modeChanged = lastDesktopMode != mode
        lastDesktopMode = mode  // 保存位置也会发 defaults 通知，先记住模式避免重入。
        if modeChanged {
            detachPanel()
            finishDesktopMovement(reposition: false)
            cancelPanelTransition()
        }
        let visible = mode != "hidden"
        if (UserDefaults.standard.object(forKey: "panelVisible") as? Bool) != visible {
            UserDefaults.standard.set(visible, forKey: "panelVisible")
        }
        guard !fullscreenAutoHidden else {
            hideDesktopWindows()
            return
        }
        switch mode {
        case "pet":
            cardExpanded = false
            updateCardAutoCollapseTimer()
            ballPanel.orderOut(nil)
            petPanel.orderFront(nil)
            if !panelTransitioning && petDetailsExpanded {
                if panelSizeUpdatePending { updatePanelSize() }
                if modeChanged { positionDetailsPanelNextToPet() }
                panel.orderFront(nil)
            } else if !panelTransitioning {
                panel.orderOut(nil)
            }
        case "hidden":
            petDetailsExpanded = false
            cardExpanded = false
            updateCardAutoCollapseTimer()
            hideDesktopWindows()
        default:
            petDetailsExpanded = false
            petPanel.orderOut(nil)
            // 切回卡片模式从悬浮球开始；模式内反复触发（@AppStorage 写入）不打断展开态
            if modeChanged { cardExpanded = false }
            updateCardAutoCollapseTimer()
            if !panelTransitioning {
                if cardExpanded {
                    if panelSizeUpdatePending { updatePanelSize() }
                    panel.orderFront(nil)
                } else { panel.orderOut(nil) }
            }
            ballPanel.orderFront(nil)
        }
        syncPanelAttachment()
    }

    // MARK: 原生窗口组跟随

    private func screenContainingMost(of frame: NSRect) -> NSScreen? {
        NSScreen.screens.filter { $0.visibleFrame.intersects(frame) }.max {
            let lhs = $0.visibleFrame.intersection(frame)
            let rhs = $1.visibleFrame.intersection(frame)
            return lhs.width * lhs.height < rhs.width * rhs.height
        }
    }

    private func freezePanelSizing() {
        if #available(macOS 13.0, *), restorePanelSizing == nil {
            let options = hosting.sizingOptions
            hosting.sizingOptions = []
            restorePanelSizing = { [weak self] in self?.hosting.sizingOptions = options }
        }
    }

    private func restorePanelSizingIfIdle() {
        guard !desktopAnchorMoving, !panelTransitioning else { return }
        restorePanelSizing?()
        restorePanelSizing = nil
    }

    private func detachPanel() {
        guard let panel else { return }
        panel.parent?.removeChildWindow(panel)
        panel.isMovableByWindowBackground = true
    }

    private func syncPanelAttachment() {
        guard let panel, panel.isVisible, !fullscreenAutoHidden else {
            detachPanel()
            return
        }
        let parent: NSPanel?
        switch desktopPresentationMode {
        case "pet": parent = petDetailsExpanded ? petPanel : nil
        case "card": parent = cardExpanded ? ballPanel : nil
        default: parent = nil
        }
        guard let parent else { detachPanel(); return }
        guard panel.parent !== parent else { return }
        detachPanel()
        parent.addChildWindow(panel, ordered: .above)
        panel.isMovableByWindowBackground = false
    }

    /// 热路径仅记下移动时间；相对位置由窗口组维护，不写设置、不定位、不截图。
    private func desktopAnchorDidMove(originKey: String) {
        pendingOriginKeys.insert(originKey)
        lastDesktopMoveTime = ProcessInfo.processInfo.systemUptime
        if !desktopAnchorMoving {
            desktopAnchorMoving = true
            freezePanelSizing()
            appearanceCaptureGeneration &+= 1  // 丢弃拖动前尚未完成的采样。
            appearanceRecheckWorkItem?.cancel()
        }
        guard desktopMoveTimer == nil else { return }
        let timer = Timer(timeInterval: 0.10, repeats: true) { [weak self] _ in
            guard let self else { return }
            // 按住鼠标停顿不算结束，避免拖动中途换边；程序化移动也会收敛。
            guard NSEvent.pressedMouseButtons & 1 == 0,
                  ProcessInfo.processInfo.systemUptime - self.lastDesktopMoveTime >= 0.15 else { return }
            self.finishDesktopMovement(reposition: true)
        }
        timer.tolerance = 0.02
        desktopMoveTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func finishDesktopMovement(reposition: Bool) {
        desktopMoveTimer?.invalidate()
        desktopMoveTimer = nil
        let wasMoving = desktopAnchorMoving
        desktopAnchorMoving = false
        restorePanelSizingIfIdle()
        let keys = pendingOriginKeys
        pendingOriginKeys.removeAll()
        for key in keys {
            let window = key == "petOrigin" ? petPanel : ballPanel
            if let window {
                UserDefaults.standard.set(NSStringFromPoint(window.frame.origin), forKey: key)
            }
        }
        guard wasMoving, reposition else { return }
        if panelSizeUpdatePending && !panelTransitioning { updatePanelSize() }
        if !fullscreenAutoHidden {
            if desktopPresentationMode == "pet", petDetailsExpanded { positionDetailsPanelNextToPet() }
            if desktopPresentationMode == "card", cardExpanded { positionCardPanelNextToBall() }
        }
        let appearance = deferredPanelAppearance
        deferredPanelAppearance = nil
        appearance?()
        scheduleAppearanceRecheck()
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let activityToken { ProcessInfo.processInfo.endActivity(activityToken) }
        store.cancelKimiAuthorization()
        finishDesktopMovement(reposition: false)
    }

    @objc private func selectCardMode() { setDesktopPresentationMode("card") }
    @objc private func selectPetMode() { setDesktopPresentationMode("pet") }
    @objc private func selectHiddenMode() { setDesktopPresentationMode("hidden") }

    @objc private func togglePetDetails() {
        guard desktopPresentationMode == "pet" else { return }
        petDetailsExpanded.toggle()
        if petDetailsExpanded {
            if !panel.isVisible {
                updatePanelSize()
                positionDetailsPanelNextToPet()
            }
            transitionPanel(visible: true)
        } else {
            transitionPanel(visible: false)
        }
    }

    @objc private func openSettings() {
        if settingsWindow == nil {
            let w = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 470, height: 640),
                styleMask: [.titled, .closable, .fullSizeContentView],
                backing: .buffered, defer: false)
            w.title = "灵眸 设置"
            w.titlebarAppearsTransparent = true
            w.titleVisibility = .hidden
            w.isMovableByWindowBackground = true
            w.contentView = NSHostingView(rootView: SettingsView(store: store, settings: settings,
                                                                 catalog: petCatalog, maintenance: maintenance))
            w.isReleasedWhenClosed = false
            w.center()
            settingsWindow = w
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    func showSettings(tab: String = "general") {
        UserDefaults.standard.set(tab, forKey: "settingsTab")
        openSettings()
    }

    @objc private func openUpdateSettings() { showSettings(tab: "general") }

    @objc private func openTaskCenter() { showTaskPanel() }
    @objc private func openTool(_ sender: NSMenuItem) {
        if let conversation = sender.representedObject as? HarnessConversation {
            store.openConversation(conversation)
        } else if let destination = sender.representedObject as? ToolDestination {
            NotificationRouter.openDestination(destination)
        } else if let key = sender.representedObject as? String {
            NotificationRouter.openDestination(forToolKey: key)
        }
    }

    func showTaskPanel(tab: String? = nil) {
        // 普通打开复用持久化页面；显式入口先选页，避免展开时闪回其他页面。
        let page = PanelPage.restored(tab ?? UserDefaults.standard.string(forKey: "panelTab"))
        UserDefaults.standard.set(page.rawValue, forKey: "panelTab")
        if desktopPresentationMode == "card" {
            if !cardExpanded { toggleCardPanel() }
        } else if desktopPresentationMode == "pet" {
            if !petDetailsExpanded { togglePetDetails() }
        } else {
            panel.center()
            transitionPanel(visible: true)
        }
        updatePanelSize()
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    @objc private func togglePin() {
        let current = UserDefaults.standard.object(forKey: "panelPinned") == nil
            ? true : UserDefaults.standard.bool(forKey: "panelPinned")
        let pinned = !current
        UserDefaults.standard.set(pinned, forKey: "panelPinned")
        applyWindowLevel(to: panel)
        applyWindowLevel(to: petPanel)
        applyWindowLevel(to: ballPanel)
        if pinned {
            applyDesktopPresentationMode()  // 置顶时顺手提到最前，避免找不到
        }
    }

    // MARK: 全屏自动隐藏

    /// 「全屏时自动隐藏」开关（默认开启），与 panelPinned 一致存 UserDefaults
    private var autoHideInFullscreenEnabled: Bool {
        UserDefaults.standard.object(forKey: "panelAutoHideFullscreen") == nil
            ? true : UserDefaults.standard.bool(forKey: "panelAutoHideFullscreen")
    }

    /// 面板所在屏幕的最前台窗口是否全屏：原生全屏（游戏、⌃⌘F）与浏览器网页全屏（看视频）的
    /// 窗口 bounds 都会覆盖整屏（含菜单栏区域），普通最大化窗口只占 visibleFrame 不会命中。
    /// 只读 layer/bounds/PID、不读窗口标题，无需屏幕录制或辅助功能授权。
    private func panelScreenHasFullscreenApp() -> Bool {
        // 卡片模式收起时唯一可见窗口是悬浮球，以球所在屏为准
        let referenceFrame: NSRect?
        switch desktopPresentationMode {
        case "pet": referenceFrame = petPanel?.frame
        case "hidden": referenceFrame = nil
        default: referenceFrame = cardExpanded ? panel?.frame : ballPanel?.frame
        }
        guard desktopPresentationMode != "hidden",
              let panelFrame = referenceFrame,
              let target = (NSScreen.screens.first { $0.frame.intersects(panelFrame) } ?? NSScreen.main)?.frame,
              let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                    kCGNullWindowID) as? [[String: Any]]
        else { return false }
        let myPID = Int(ProcessInfo.processInfo.processIdentifier)
        // 列表按前到后排序，只判定第一个非本进程的普通窗口：后台恰好等于全屏尺寸的
        // 窗口（如虚拟显示器控制窗）不能当成全屏
        for info in list {
            guard let layer = info[kCGWindowLayer as String] as? Int, layer == 0 else { continue }
            guard let ownerPID = info[kCGWindowOwnerPID as String] as? Int, ownerPID != myPID else { continue }
            guard let bounds = info[kCGWindowBounds as String] as? NSDictionary,
                  let frame = CGRect(dictionaryRepresentation: bounds) else { continue }
            // 覆盖整屏即判定全屏（±2pt 容差）；多显示器时只认面板所在的那块屏
            return frame.minX <= target.minX + 2 && frame.minY <= target.minY + 2
                && frame.maxX >= target.maxX - 2 && frame.maxY >= target.maxY - 2
        }
        return false
    }

    /// 全屏状态机：进全屏隐藏（不动桌面显示偏好），退全屏按原偏好恢复；
    /// 用户手动显示优先，不与用户抢
    private func updateFullscreenAutoHide() {
        guard panel != nil, petPanel != nil else { return }
        guard autoHideInFullscreenEnabled else {
            // 开关刚被关掉：撤销仍在生效的自动隐藏，回到永远置顶的旧行为
            fullscreenAutoHideSuppressed = false
            if fullscreenAutoHidden {
                fullscreenAutoHidden = false
                applyDesktopPresentationMode()
            }
            return
        }
        if panelScreenHasFullscreenApp() {
            if (panel.isVisible || petPanel.isVisible) && !fullscreenAutoHideSuppressed {
                fullscreenAutoHidden = true
                hideDesktopWindows()
            }
        } else {
            fullscreenAutoHideSuppressed = false
            if fullscreenAutoHidden {
                fullscreenAutoHidden = false
                applyDesktopPresentationMode()
            }
        }
    }

    @objc private func toggleAutoHideFullscreen() {
        UserDefaults.standard.set(!autoHideInFullscreenEnabled, forKey: "panelAutoHideFullscreen")
        updateFullscreenAutoHide()  // 立即生效：打开且正处全屏马上隐藏，关掉立即恢复
    }

    /// 构建桌面浮窗右键菜单（置顶切换 + 设置 + 退出）。复用 togglePin()/openSettings() 动作，
    /// 与菜单栏下拉的"置顶桌面卡片"、"设置…"项保持同一套逻辑与图标。
    private func buildPanelContextMenu() -> NSMenu {
        let menu = NSMenu()
        if desktopPresentationMode == "pet" {
            let collapseItem = NSMenuItem(
                title: "收起详情卡片",
                action: #selector(togglePetDetails),
                keyEquivalent: "")
            collapseItem.target = self
            collapseItem.image = symbol("minus.rectangle", template: true)
            menu.addItem(collapseItem)
        } else {
            if cardExpanded {
                let collapseItem = NSMenuItem(
                    title: "收起到悬浮球",
                    action: #selector(collapseCardPanel),
                    keyEquivalent: "")
                collapseItem.target = self
                collapseItem.image = symbol("minus.rectangle", template: true)
                menu.addItem(collapseItem)
            }
            let petItem = NSMenuItem(
                title: "切换到桌面宠物",
                action: #selector(selectPetMode),
                keyEquivalent: "")
            petItem.target = self
            petItem.image = symbol("pawprint", template: true)
            menu.addItem(petItem)
        }
        menu.addItem(.separator())
        let pinned = UserDefaults.standard.object(forKey: "panelPinned") == nil
            ? true : UserDefaults.standard.bool(forKey: "panelPinned")
        let pinItem = NSMenuItem(
            title: pinned ? "取消置顶" : "置顶",
            action: #selector(togglePin),
            keyEquivalent: "")
        pinItem.target = self
        pinItem.image = symbol("pin", template: true)
        pinItem.state = pinned ? .on : .off
        menu.addItem(pinItem)
        let autoHideItem = NSMenuItem(
            title: "全屏时自动隐藏",
            action: #selector(toggleAutoHideFullscreen),
            keyEquivalent: "")
        autoHideItem.target = self
        autoHideItem.image = symbol("arrow.up.left.and.arrow.down.right", template: true)
        autoHideItem.state = autoHideInFullscreenEnabled ? .on : .off
        menu.addItem(autoHideItem)
        let settingsItem = NSMenuItem(
            title: "设置…",
            action: #selector(openSettings),
            keyEquivalent: "")
        settingsItem.target = self
        settingsItem.image = symbol("gearshape", template: true)
        menu.addItem(settingsItem)
        menu.addItem(.separator())
        let quitItem = NSMenuItem(
            title: "退出灵眸",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "")
        quitItem.target = NSApp
        quitItem.image = symbol("power", color: .systemRed)
        menu.addItem(quitItem)
        return menu
    }

    /// 悬浮球右键菜单：展开/收起 + 模式切换，其余项与面板/桌宠菜单同源
    private func addTaskEntries(to menu: NSMenu) {
        for (title, action, icon) in [("打开面板", #selector(openTaskCenter), "eye")] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            item.image = symbol(icon, template: true)
            menu.addItem(item)
        }
        menu.addItem(.separator())
    }

    private func buildBallContextMenu() -> NSMenu {
        let menu = NSMenu()
        addTaskEntries(to: menu)
        let toggleItem = NSMenuItem(
            title: cardExpanded ? "收起面板" : "展开面板",
            action: #selector(toggleCardPanel),
            keyEquivalent: "")
        toggleItem.target = self
        toggleItem.image = symbol(cardExpanded ? "minus.rectangle" : "plus.rectangle", template: true)
        menu.addItem(toggleItem)
        let petItem = NSMenuItem(
            title: "切换到桌面宠物",
            action: #selector(selectPetMode),
            keyEquivalent: "")
        petItem.target = self
        petItem.image = symbol("pawprint", template: true)
        menu.addItem(petItem)
        menu.addItem(.separator())

        let pinned = UserDefaults.standard.object(forKey: "panelPinned") == nil
            ? true : UserDefaults.standard.bool(forKey: "panelPinned")
        let pinItem = NSMenuItem(
            title: pinned ? "取消置顶" : "置顶",
            action: #selector(togglePin),
            keyEquivalent: "")
        pinItem.target = self
        pinItem.image = symbol("pin", template: true)
        pinItem.state = pinned ? .on : .off
        menu.addItem(pinItem)
        let autoHideItem = NSMenuItem(
            title: "全屏时自动隐藏",
            action: #selector(toggleAutoHideFullscreen),
            keyEquivalent: "")
        autoHideItem.target = self
        autoHideItem.image = symbol("arrow.up.left.and.arrow.down.right", template: true)
        autoHideItem.state = autoHideInFullscreenEnabled ? .on : .off
        menu.addItem(autoHideItem)
        let settingsItem = NSMenuItem(
            title: "设置…",
            action: #selector(openSettings),
            keyEquivalent: "")
        settingsItem.target = self
        settingsItem.image = symbol("gearshape", template: true)
        menu.addItem(settingsItem)
        let hideItem = NSMenuItem(
            title: "隐藏桌面显示",
            action: #selector(selectHiddenMode),
            keyEquivalent: "")
        hideItem.target = self
        hideItem.image = symbol("eye.slash", template: true)
        menu.addItem(hideItem)
        menu.addItem(.separator())
        let quitItem = NSMenuItem(
            title: "退出灵眸",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "")
        quitItem.target = NSApp
        quitItem.image = symbol("power", color: .systemRed)
        menu.addItem(quitItem)
        return menu
    }

    private func buildPetContextMenu() -> NSMenu {
        let menu = NSMenu()
        addTaskEntries(to: menu)
        let detailsItem = NSMenuItem(
            title: petDetailsExpanded ? "收起详情卡片" : "展开详情卡片",
            action: #selector(togglePetDetails),
            keyEquivalent: "")
        detailsItem.target = self
        detailsItem.image = symbol(petDetailsExpanded ? "minus.rectangle" : "plus.rectangle", template: true)
        menu.addItem(detailsItem)
        let cardItem = NSMenuItem(
            title: "切换到桌面卡片",
            action: #selector(selectCardMode),
            keyEquivalent: "")
        cardItem.target = self
        cardItem.image = symbol("rectangle.on.rectangle", template: true)
        menu.addItem(cardItem)
        menu.addItem(.separator())

        let pinned = UserDefaults.standard.object(forKey: "panelPinned") == nil
            ? true : UserDefaults.standard.bool(forKey: "panelPinned")
        let pinItem = NSMenuItem(
            title: pinned ? "取消置顶" : "置顶",
            action: #selector(togglePin),
            keyEquivalent: "")
        pinItem.target = self
        pinItem.image = symbol("pin", template: true)
        pinItem.state = pinned ? .on : .off
        menu.addItem(pinItem)
        let autoHideItem = NSMenuItem(
            title: "全屏时自动隐藏",
            action: #selector(toggleAutoHideFullscreen),
            keyEquivalent: "")
        autoHideItem.target = self
        autoHideItem.image = symbol("arrow.up.left.and.arrow.down.right", template: true)
        autoHideItem.state = autoHideInFullscreenEnabled ? .on : .off
        menu.addItem(autoHideItem)
        let settingsItem = NSMenuItem(
            title: "设置…",
            action: #selector(openSettings),
            keyEquivalent: "")
        settingsItem.target = self
        settingsItem.image = symbol("gearshape", template: true)
        menu.addItem(settingsItem)
        let hideItem = NSMenuItem(
            title: "隐藏桌面显示",
            action: #selector(selectHiddenMode),
            keyEquivalent: "")
        hideItem.target = self
        hideItem.image = symbol("eye.slash", template: true)
        menu.addItem(hideItem)
        menu.addItem(.separator())
        let quitItem = NSMenuItem(
            title: "退出灵眸",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "")
        quitItem.target = NSApp
        quitItem.image = symbol("power", color: .systemRed)
        menu.addItem(quitItem)
        return menu
    }

    @objc private func doRefresh() {
        store.refresh()
    }
}
