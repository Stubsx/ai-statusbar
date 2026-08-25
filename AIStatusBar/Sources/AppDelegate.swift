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
    private var glassView: NSView?  // macOS 26+ 的 NSGlassEffectView（用 NSView 声明避开可用性注解）
    private var store: StatusStore!
    private let settings = SettingsStore()
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
    private var cancellables: Set<AnyCancellable> = []  // 设置订阅（如桌宠大小）

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 通知 delegate 在启动时设置，托管横幅点击回调（跳转对应工具）
        UNUserNotificationCenter.current().delegate = self
        // 历史版本只在开关从关→开时请求一次系统授权，且忽略结果；若当时授权
        // 未完成（如签名身份变化），此后通知会被系统静默丢弃。启动时补查一次：
        // notDetermined 才真正弹系统授权框，已允许/已拒绝都不打扰用户。
        if settings.notifyEnabled {
            UNUserNotificationCenter.current().getNotificationSettings { s in
                if s.authorizationStatus == .notDetermined {
                    UNUserNotificationCenter.current().requestAuthorization(
                        options: [.alert, .sound]) { _, _ in }
                }
            }
        }
        let collectorPath = Bundle.main.path(forResource: "lingmou-collector", ofType: nil)
        store = StatusStore(collectorPath: collectorPath, settings: settings)

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "AI …"
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        buildPanel()
        buildPetPanel()
        applyDesktopPresentationMode()
        store.start()
        NotificationCenter.default.addObserver(self, selector: #selector(onStatusUpdated),
                                               name: .statusUpdated, object: nil)
        // 防止 macOS 把后台菜单栏 app 的定时器节流（App Nap），保住 3 秒背景采样
        activityToken = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .suddenTerminationDisabled, .automaticTerminationDisabled],
            reason: "面板背景采样定时器")
    }

    // MARK: 通知点击路由

    /// 点击"任务完成"通知时跳到对应工具：App 型激活对应应用，
    /// CLI 型（Codex CLI / Kimi Code）回到跑着该进程的终端/编辑器窗口。
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        if response.actionIdentifier == UNNotificationDefaultActionIdentifier,
            let key = response.notification.request.content.userInfo["tool"] as? String
        {
            NotificationRouter.openDestination(forToolKey: key)
        }
        completionHandler()
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

    /// 菜单栏富文本徽标：字母(系统色) + 小圆点(状态色) + 任务数
    private func badgeTitle(_ tools: [ToolStatus]) -> NSAttributedString {
        let out = NSMutableAttributedString()
        let letterAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .medium),
        ]
        for (i, t) in tools.enumerated() {
            out.append(NSAttributedString(string: t.letter, attributes: letterAttrs))
            let dotColor = NSColor.toolStatusColor(t.state)
            out.append(NSAttributedString(string: "●", attributes: [
                .font: NSFont.systemFont(ofSize: 7, weight: .bold),
                .foregroundColor: dotColor,
                .baselineOffset: 2.5,
                .kern: -1,
            ]))
            if t.state == "busy" {
                out.append(NSAttributedString(string: "\(t.busyCount)", attributes: [
                    .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .bold),
                    .foregroundColor: NSColor.systemGreen,
                ]))
            }
            if i < tools.count - 1 {
                out.append(NSAttributedString(string: "  ", attributes: letterAttrs))
            }
        }
        return out
    }

    @objc private func onStatusUpdated() {
        guard let data = store.data else { return }
        let visible = data.tools.filter { $0.state != "off" }
        // 全部未运行时保留一个占位徽标，保证菜单入口还在
        statusItem.button?.attributedTitle = visible.isEmpty
            ? badgeTitle([ToolStatus(key: "_", letter: "AI", name: "", state: "off",
                                     busyCount: 0, busyItems: [], detail: "",
                                     latestTitle: nil, latestAge: nil, quota: nil)])
            : badgeTitle(visible)

        // 浮窗尺寸跟随内容
        hosting.layout()
        let size = hosting.fittingSize
        if abs(panel.frame.height - size.height) > 1 || abs(panel.frame.width - size.width) > 1 {
            var f = panel.frame
            f.origin.y += f.size.height - size.height  // 保持顶边不动
            f.size = size
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
    private var appearanceTransitionToken = 0  // 外观过渡进行中又来了新切换时，作废旧的淡入回调

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
    /// 过渡策略：内容透明度做一次"下潜再浮起"的关键帧动画（1 → 谷底 → 1），
    /// 外观切换安排在接近谷底时执行——此刻文字几乎不可见，避免新旧配色重影。
    /// 关键点：CA 动画提交后由 render server 独立驱动，主线程在切换外观时的
    /// 整帧 SwiftUI 重绘不会打断它；之前用 NSAnimationContext completion 链分两段，
    /// 接缝恰好落在重绘上，动画会卡一拍（掉帧感的来源）。
    private func setPanelAppearance(_ name: NSAppearance.Name?) {
        let appearance = name.flatMap { NSAppearance(named: $0) }
        let unchanged = hosting.appearance?.name == name
            && panel.appearance?.name == name
            && glassView?.appearance?.name == name
        guard !unchanged else { return }

        appearanceTransitionToken &+= 1
        let token = appearanceTransitionToken
        guard let host = hosting, let layer = host.layer else {
            writePanelAppearance(name, appearance: appearance)
            return
        }

        let dip = CAKeyframeAnimation(keyPath: "opacity")
        // 0.45s：下潜 0.13s + 谷底停留 0.05s + 浮起 0.26s。
        // 谷底短暂停留让外观切换更从容，整体读感是柔和的呼吸而不是快速眨眼。
        dip.values = [1.0, 0.06, 0.06, 1.0]
        dip.keyTimes = [0, 0.30, 0.42, 1]
        dip.duration = 0.45
        dip.timingFunctions = [
            CAMediaTimingFunction(name: .easeIn),
            CAMediaTimingFunction(name: .linear),
            CAMediaTimingFunction(name: .easeOut),
        ]
        layer.add(dip, forKey: "panelAppearanceDip")

        // 0.16s 时透明度正处谷底平台（动画仍在 render server 上连续推进），
        // 此刻切外观并让底色做一次短插值，回升段与底色渐变重叠。
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.16) { [weak self] in
            guard let self, token == self.appearanceTransitionToken else { return }
            let oldBackground = layer.backgroundColor
            self.writePanelAppearance(name, appearance: appearance)
            if let newBackground = layer.backgroundColor, newBackground != oldBackground {
                let anim = CABasicAnimation(keyPath: "backgroundColor")
                anim.fromValue = oldBackground
                anim.toValue = newBackground
                anim.duration = 0.28
                anim.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                // 模型值已是终值，动画只负责呈现层从旧色到新色的插值
                layer.add(anim, forKey: "panelBackgroundFade")
            }
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
    /// 拖动过程中的背景变化由 3 秒定时器兜底，停下后这一次即时修正观感。
    private func scheduleAppearanceRecheck() {
        appearanceRecheckWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.applyPanelAppearanceMode() }
        appearanceRecheckWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: item)
    }

    private func applyPanelAppearanceMode() {
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

    /// 标题限宽，超长截断加省略号
    private func truncate(_ s: String, _ maxChars: Int = 40) -> String {
        s.count > maxChars ? String(s.prefix(maxChars - 1)) + "…" : s
    }

    // MARK: 菜单

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let label = ["busy": "工作中", "idle": "空闲", "off": "未运行"]
        if let data = store.data {
            let visible = data.tools.filter { $0.state != "off" }
            if visible.isEmpty {
                let empty = NSMenuItem(title: "全部未运行", action: nil, keyEquivalent: "")
                empty.image = symbol("moon.zzz", color: .systemGray, size: 12)
                empty.isEnabled = false
                menu.addItem(empty)
                menu.addItem(.separator())
            }
            for t in visible {
                let header = NSMenuItem(title: "\(t.name)：\(label[t.state] ?? t.state)（\(t.detail)）",
                                        action: nil, keyEquivalent: "")
                header.image = symbol("circle.fill", color: NSColor.toolStatusColor(t.state), size: 10)
                header.isEnabled = false
                menu.addItem(header)
                for busy in t.busyItems.prefix(3) {
                    let item = NSMenuItem(title: truncate(busy.title), action: nil, keyEquivalent: "")
                    item.image = symbol("play.fill", color: .systemGreen, size: 11)
                    item.isEnabled = false
                    item.attributedTitle = NSAttributedString(string: item.title, attributes: [
                        .font: NSFont.systemFont(ofSize: 11),
                        .foregroundColor: NSColor.systemGreen,
                    ])
                    menu.addItem(item)
                }
                if t.busyItems.isEmpty, let latest = t.latestTitle {
                    let item = NSMenuItem(title: "最近任务：\(truncate(latest, 34)) · \(t.latestAge ?? "")", action: nil, keyEquivalent: "")
                    item.image = symbol("clock", size: 11, template: true)
                    item.isEnabled = false
                    item.attributedTitle = NSAttributedString(string: item.title, attributes: [
                        .font: NSFont.systemFont(ofSize: 11),
                        .foregroundColor: NSColor.secondaryLabelColor,
                    ])
                    menu.addItem(item)
                }
                menu.addItem(.separator())
            }
        }
        let settingsItem = NSMenuItem(title: "设置…", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        settingsItem.image = symbol("gearshape", template: true)
        menu.addItem(settingsItem)
        let desktopItem = NSMenuItem(title: "桌面显示", action: nil, keyEquivalent: "")
        desktopItem.image = symbol("rectangle.on.rectangle", template: true)
        let desktopMenu = NSMenu()
        let mode = desktopPresentationMode
        let cardMode = NSMenuItem(title: "桌面卡片", action: #selector(selectCardMode), keyEquivalent: "")
        cardMode.target = self
        cardMode.state = mode == "card" ? .on : .off
        desktopMenu.addItem(cardMode)
        let petMode = NSMenuItem(title: "桌面宠物", action: #selector(selectPetMode), keyEquivalent: "")
        petMode.target = self
        petMode.state = mode == "pet" ? .on : .off
        desktopMenu.addItem(petMode)
        let hiddenMode = NSMenuItem(title: "隐藏", action: #selector(selectHiddenMode), keyEquivalent: "")
        hiddenMode.target = self
        hiddenMode.state = mode == "hidden" ? .on : .off
        desktopMenu.addItem(hiddenMode)
        desktopItem.submenu = desktopMenu
        menu.addItem(desktopItem)
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
        let refresh = NSMenuItem(title: "刷新", action: #selector(doRefresh), keyEquivalent: "r")
        refresh.target = self
        refresh.image = symbol("arrow.clockwise", template: true)
        menu.addItem(refresh)
        menu.addItem(.separator())
        let legend = NSMenuItem(title: "C=Codex App  X=Codex CLI  K=Kimi  L=Claude  H=Hermes  Z=ZCode", action: nil, keyEquivalent: "")
        legend.isEnabled = false
        legend.attributedTitle = NSAttributedString(string: legend.title, attributes: [
            .font: NSFont.systemFont(ofSize: 10),
            .foregroundColor: NSColor.secondaryLabelColor,
        ])
        menu.addItem(legend)
        let quit = NSMenuItem(title: "退出", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.image = symbol("power", color: .systemRed)
        menu.addItem(quit)
    }

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
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 320, height: 200),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.identifier = NSUserInterfaceItemIdentifier("AIStatusPanel")
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
        // 拖动结束（含实时拖动过程中）持久化位置
        NotificationCenter.default.addObserver(forName: NSWindow.didMoveNotification,
                                               object: panel, queue: .main) { [weak self] _ in
            guard let self else { return }
            let f = self.panel.frame
            // 桌宠模式的详情卡位置只是临时跟随，不覆盖独立卡片模式的位置记忆。
            if self.desktopPresentationMode == "card" {
                UserDefaults.standard.set(NSStringFromPoint(f.origin), forKey: "panelOrigin")
            }
            self.scheduleAppearanceRecheck()  // 拖动后重采背景亮度（去抖，见该方法注释）
        }

        // 面板外观：每 3 秒走一次模式入口（adaptive 模式下检测面板下方亮度）
        let appearanceTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            self?.applyPanelAppearanceMode()
        }
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
        RunLoop.main.add(fullscreenTimer, forMode: .common)
        // 设置改动（外观模式切换）立即生效，不等下个 3 秒周期
        NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.applyPanelAppearanceMode()
            self?.applyDesktopPresentationMode()
        }

        hosting.layout()
        panel.setContentSize(hosting.fittingSize)

        restoreCardPanelPosition()

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
            let origin = self.petPanel.frame.origin
            UserDefaults.standard.set(NSStringFromPoint(origin), forKey: "petOrigin")
            if self.petDetailsExpanded && self.desktopPresentationMode == "pet" {
                self.positionDetailsPanelNextToPet()
            }
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

    private func restoreCardPanelPosition() {
        guard panel != nil else { return }
        restoreWindowPosition(panel, key: "panelOrigin") { screen, size in
            NSPoint(
                x: screen.visibleFrame.minX + 24,
                y: screen.visibleFrame.maxY - size.height - 24
            )
        }
    }

    /// 桌宠模式的详情卡优先放在宠物右侧，空间不足时自动换到左侧，
    /// 并始终限制在宠物所在屏幕的可见区域内。
    private func positionDetailsPanelNextToPet() {
        guard let panel, let petPanel else { return }
        let petFrame = petPanel.frame
        let screen = NSScreen.screens.first(where: { $0.visibleFrame.intersects(petFrame) })
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
        panel.setFrameOrigin(origin)
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
        panel?.orderOut(nil)
        petPanel?.orderOut(nil)
    }

    private func applyDesktopPresentationMode() {
        guard panel != nil, petPanel != nil else { return }
        let mode = desktopPresentationMode
        // 页签/用量范围等 @AppStorage 写入也会触发本方法（UserDefaults.didChange），
        // 此时窗口尺寸正随内容自适应（顶边锚定）；若每次都恢复记忆位置或重摆详情卡，
        // 会把窗口拽回旧 origin，顶边来回跳。只在模式真正切换时才动位置。
        let modeChanged = lastDesktopMode != mode
        lastDesktopMode = mode
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
            petPanel.orderFront(nil)
            if petDetailsExpanded {
                if modeChanged { positionDetailsPanelNextToPet() }
                panel.orderFront(nil)
            } else {
                panel.orderOut(nil)
            }
        case "hidden":
            petDetailsExpanded = false
            hideDesktopWindows()
        default:
            petDetailsExpanded = false
            petPanel.orderOut(nil)
            if modeChanged { restoreCardPanelPosition() }
            panel.orderFront(nil)
        }
    }

    @objc private func selectCardMode() { setDesktopPresentationMode("card") }
    @objc private func selectPetMode() { setDesktopPresentationMode("pet") }
    @objc private func selectHiddenMode() { setDesktopPresentationMode("hidden") }

    @objc private func togglePetDetails() {
        guard desktopPresentationMode == "pet" else { return }
        petDetailsExpanded.toggle()
        if petDetailsExpanded {
            positionDetailsPanelNextToPet()
            panel.orderFront(nil)
        } else {
            panel.orderOut(nil)
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
            w.contentView = NSHostingView(rootView: SettingsView(store: store, settings: settings, catalog: petCatalog))
            w.isReleasedWhenClosed = false
            w.center()
            settingsWindow = w
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    @objc private func togglePin() {
        let current = UserDefaults.standard.object(forKey: "panelPinned") == nil
            ? true : UserDefaults.standard.bool(forKey: "panelPinned")
        let pinned = !current
        UserDefaults.standard.set(pinned, forKey: "panelPinned")
        applyWindowLevel(to: panel)
        applyWindowLevel(to: petPanel)
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
        let referenceFrame = desktopPresentationMode == "pet" ? petPanel?.frame : panel?.frame
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

    private func buildPetContextMenu() -> NSMenu {
        let menu = NSMenu()
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
