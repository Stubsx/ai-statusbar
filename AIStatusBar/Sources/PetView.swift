import Cocoa
import SwiftUI

// MARK: - 桌面宠物状态

enum PetMood: Equatable {
    case loading
    case working(taskCount: Int)
    case idle
    case sleeping
    case celebrating
    case error

    static func current(data: StatusData?, error: String?) -> PetMood {
        if error != nil { return .error }
        guard let data else { return .loading }
        let busyCount = data.tools.reduce(0) { total, tool in
            total + (tool.state == "busy" ? tool.busyCount : 0)
        }
        if busyCount > 0 { return .working(taskCount: busyCount) }
        if data.tools.contains(where: { $0.state == "idle" }) { return .idle }
        return .sleeping
    }

    var blinkDelayRange: ClosedRange<Double> {
        switch self {
        case .celebrating: return 0.85...1.25
        case .loading: return 2.2...4.0
        case .working: return 2.8...4.8
        case .idle: return 3.8...6.2
        case .error: return 3.2...5.4
        case .sleeping: return 10...10
        }
    }

    var doubleBlinkChance: Double {
        switch self {
        case .loading: return 0.25
        case .working, .idle: return 0.16
        case .celebrating: return 0.22
        case .error, .sleeping: return 0
        }
    }

    var summary: String {
        switch self {
        case .loading: return "正在观察 AI 工具…"
        case .working(let taskCount): return "正在处理 \(taskCount) 个任务"
        case .idle: return "AI 工具正在空闲"
        case .sleeping: return "AI 工具都没有运行"
        case .celebrating: return "任务完成啦！"
        case .error: return "状态采集遇到了问题"
        }
    }
}

// MARK: - 宠物内容

struct PetView: View {
    @ObservedObject var store: StatusStore
    @ObservedObject var settings: SettingsStore
    @ObservedObject var catalog: PetCatalog
    let onOpenDetails: () -> Void

    @State private var hovered = false
    @State private var celebratingSerial = 0
    @State private var celebrationMessage = "任务完成啦！"

    private var liveMood: PetMood {
        PetMood.current(data: store.data, error: store.collectorError)
    }

    private var mood: PetMood {
        celebratingSerial > 0 ? .celebrating : liveMood
    }

    /// 形象完全由目录数据驱动：内置 + ~/.ai-statusbar/Pets 下的自定义形象。
    private var theme: PetTheme? {
        catalog.currentTheme(id: settings.petAppearance)
    }

    /// 桌宠显示比例（设置里可调）。
    /// 所有尺寸/字号/偏移直接乘比例（而不是 scaleEffect 位图放大），
    /// 保证放大后文字、徽标等仍以最终分辨率原生渲染，保持清晰。
    private var scale: CGFloat {
        CGFloat(settings.petScale)
    }

    private func s(_ v: CGFloat) -> CGFloat { v * scale }

    var body: some View {
        // 提示/庆祝气泡是浮层而不是布局成员：相对形象顶部定位、随缩放自适应，
        // 不出现时不占任何空间（原方案用 30pt 透明占位防跳动，窗口顶部常驻一段空白）。
        PetSprite(mood: mood, theme: theme, scale: scale)
            .frame(width: s(220), height: s(236), alignment: .bottom)
            .overlay(alignment: .top) {
                if celebratingSerial > 0 {
                    celebrationBubble
                } else if hovered {
                    hoverBubble
                }
            }
            .contentShape(Rectangle())
            .onTapGesture(perform: onOpenDetails)
            .onHover { inside in
                withAnimation(.easeOut(duration: 0.16)) { hovered = inside }
            }
            .onChange(of: store.completedEventSerial) { serial in
                guard serial > 0 else { return }
                celebrationMessage = store.completedEventMessage
                celebratingSerial = serial
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                    if celebratingSerial == serial {
                        celebratingSerial = 0
                        celebrationMessage = "任务完成啦！"
                    }
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(
            "\(celebratingSerial > 0 ? celebrationMessage : mood.summary)，单击展开详情"
        )
    }

    /// 任务完成后的庆祝气泡（浮层，3 秒自动消失）
    private var celebrationBubble: some View {
        Text(celebrationMessage)
            .font(.system(size: s(10.5), weight: .semibold, design: .rounded))
            .foregroundColor(Color(red: 0.25, green: 0.40, blue: 0.65))
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(maxWidth: s(184))
            .padding(.horizontal, s(10))
            .padding(.vertical, s(6))
            .background(
                Capsule()
                    .fill(Color(red: 0.92, green: 0.96, blue: 1.0).opacity(0.96))
                    .overlay(Capsule().stroke(Color.white.opacity(0.96), lineWidth: s(1.3)))
                    .overlay(
                        Capsule()
                            .stroke(
                                Color(red: 0.55, green: 0.72, blue: 0.92).opacity(0.58),
                                lineWidth: s(0.6)
                            )
                            .padding(s(1))
                    )
            )
            .shadow(
                color: Color(red: 0.34, green: 0.59, blue: 0.88).opacity(0.22),
                radius: s(6),
                y: s(2)
            )
            .padding(.top, s(2))
            .transition(.opacity.combined(with: .move(edge: .bottom)))
    }

    /// hover 时的状态提示气泡（浮层，覆盖在形象上沿，不挤占布局）
    private var hoverBubble: some View {
        Text(mood.summary)
            .font(.system(size: s(11), weight: .medium))
            .foregroundColor(.primary)
            .padding(.horizontal, s(11))
            .padding(.vertical, s(6))
            .background(
                Capsule()
                    .fill(.ultraThinMaterial)
                    .overlay(Capsule().stroke(Color.primary.opacity(0.12), lineWidth: s(0.5)))
            )
            .shadow(color: .black.opacity(0.18), radius: s(7), y: s(3))
            .padding(.top, s(2))
            .transition(.opacity.combined(with: .move(edge: .bottom)))
    }
}

/// 设置里的形象编辑器也复用这个 Sprite 做实时预览，因此不能是 private。
struct PetSprite: View {
    let mood: PetMood
    /// nil（一个素材都没有）时显示占位图标。
    let theme: PetTheme?
    let scale: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var blinking = false
    @State private var blinkTask: Task<Void, Never>?
    @State private var typingFrame = 0
    @State private var typingTask: Task<Void, Never>?

    private func s(_ v: CGFloat) -> CGFloat { v * scale }

    private var displayedImageURL: URL? {
        guard let theme else { return nil }
        if blinking, let blinkURL = theme.blinkURL(for: mood) { return blinkURL }
        let typingURLs = theme.typingURLs(for: mood)
        if typingFrame > 0, typingURLs.indices.contains(typingFrame - 1) {
            return typingURLs[typingFrame - 1]
        }
        return theme.imageURL(for: mood)
    }

    private var image: NSImage {
        if let url = displayedImageURL, let image = PetImageCache.image(at: url) {
            return image
        }
        return NSImage(systemSymbolName: "eye.fill", accessibilityDescription: nil) ?? NSImage()
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            PetEffectsBackdrop(mood: mood, scale: scale)

            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .frame(width: s(200), height: s(226))
                // 只替换 Image 实例，并禁用默认交叉淡化；否则两种姿势会短暂叠在一起。
                .id(displayedImageURL)
                .transition(.identity)
                .transaction { transaction in
                    transaction.disablesAnimations = true
                }

            PetEffectsForeground(mood: mood, scale: scale)

            if case .working(let taskCount) = mood {
                Text("×\(taskCount)")
                    .font(.system(size: s(11), weight: .semibold, design: .rounded).monospacedDigit())
                    .foregroundColor(Color(red: 0.25, green: 0.40, blue: 0.65))
                    .padding(.horizontal, s(8))
                    .frame(height: s(23))
                    .background(
                        Capsule()
                            .fill(Color(red: 0.92, green: 0.96, blue: 1.0).opacity(0.94))
                            .overlay(
                                Capsule()
                                    .stroke(Color.white.opacity(0.96), lineWidth: s(1.4))
                            )
                            .overlay(
                                Capsule()
                                    .stroke(
                                        Color(red: 0.55, green: 0.72, blue: 0.92).opacity(0.65),
                                        lineWidth: s(0.65)
                                    )
                                    .padding(s(1))
                            )
                    )
                    .shadow(
                        color: Color(red: 0.34, green: 0.59, blue: 0.88).opacity(0.24),
                        radius: s(5),
                        y: s(2)
                    )
                    .padding(.top, s(12))
                    .padding(.trailing, s(7))
            }
        }
        .frame(width: s(210), height: s(232))
        .onAppear {
            restartBlinking(mood, theme: theme)
            restartTyping(mood, theme: theme)
        }
        .onDisappear {
            blinkTask?.cancel()
            blinkTask = nil
            typingTask?.cancel()
            typingTask = nil
        }
        // onChange 闭包捕获的是上一次渲染的 view 拷贝，直接读 self.mood 会拿到旧值
        // （例如 loading→working 时仍是 loading），敲键盘任务就永远不会被创建。
        // 必须把回传的新 mood 显式传给动画启动函数。
        .onChange(of: mood) { newMood in
            restartBlinking(newMood, theme: theme)
            restartTyping(newMood, theme: theme)
        }
        .onChange(of: theme) { newTheme in
            restartBlinking(mood, theme: newTheme)
            restartTyping(mood, theme: newTheme)
        }
        .onChange(of: reduceMotion) { _ in
            restartBlinking(mood, theme: theme)
            restartTyping(mood, theme: theme)
        }
        // 窗口被 orderOut（如全屏自动隐藏）时眨眼/打字任务照常计时但切图无意义，
        // 恢复可见时兜底重启一轮；层动效（PetEffectsView）自己监听遮挡恢复。
        .onReceive(
            NotificationCenter.default.publisher(for: NSWindow.didChangeOcclusionStateNotification)
        ) { note in
            guard let window = note.object as? NSWindow,
                  window.occlusionState.contains(.visible)
            else { return }
            restartBlinking(mood, theme: theme)
            restartTyping(mood, theme: theme)
        }
    }

    /// 每轮用 0...99 随机数选择短眨、慢眨或双眨；图片切换禁用动画，避免重影。
    private func restartBlinking(_ activeMood: PetMood, theme: PetTheme?) {
        blinkTask?.cancel()
        blinkTask = nil
        setBlinking(false)
        guard !reduceMotion,
              let theme,
              let blinkURL = theme.blinkURL(for: activeMood),
              let baseURL = theme.imageURL(for: activeMood)
        else { return }

        PetImageCache.preload(urls: [baseURL, blinkURL])
        blinkTask = Task { @MainActor in
            var firstCycle = true
            while !Task.isCancelled {
                var delay: Double
                if firstCycle, case .celebrating = activeMood {
                    // 庆祝仅展示 3 秒，首眨提前并保证一定能被看到。
                    delay = Double.random(in: 0.35...0.65)
                } else {
                    delay = Double.random(in: activeMood.blinkDelayRange)
                }
                firstCycle = false
                // 偶尔多停一会儿，避免长期落在相似的眨眼节拍上。
                if case .celebrating = activeMood {
                    // 短暂庆祝期间不加入长停顿。
                } else if Int.random(in: 0..<100) < 12 {
                    delay += Double.random(in: 1.0...2.4)
                }
                guard await pause(seconds: delay) else { return }

                let rhythmRoll = Int.random(in: 0..<100)
                let doubleBlink = rhythmRoll < Int(activeMood.doubleBlinkChance * 100)
                let slowBlink = !doubleBlink && rhythmRoll >= 88
                let firstHold = slowBlink
                    ? Double.random(in: 0.145...0.195)
                    : Double.random(in: 0.075...0.125)

                setBlinking(true)
                guard await pause(seconds: firstHold) else { return }
                setBlinking(false)

                if doubleBlink {
                    guard await pause(seconds: Double.random(in: 0.115...0.205)) else {
                        return
                    }
                    setBlinking(true)
                    guard await pause(seconds: Double.random(in: 0.065...0.110)) else {
                        return
                    }
                    setBlinking(false)
                }
            }
        }
    }

    private func pause(seconds: Double) async -> Bool {
        do {
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            return !Task.isCancelled
        } catch {
            return false
        }
    }

    private func setBlinking(_ value: Bool) {
        if value { setTypingFrame(0) }
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) { blinking = value }
    }

    /// 工作状态随机连敲 3～8 下，再停顿片刻；眨眼时手会自然回到中间帧。
    private func restartTyping(_ activeMood: PetMood, theme: PetTheme?) {
        typingTask?.cancel()
        typingTask = nil
        setTypingFrame(0)
        guard !reduceMotion, let theme else { return }
        let typingURLs = theme.typingURLs(for: activeMood)
        guard !typingURLs.isEmpty else { return }

        PetImageCache.preload(urls: [theme.imageURL(for: activeMood)].compactMap { $0 } + typingURLs)
        typingTask = Task { @MainActor in
            guard await pause(seconds: Double.random(in: 0.30...0.70)) else { return }
            while !Task.isCancelled {
                let tapCount = Int.random(in: 4...8)
                let startingFrame = Bool.random() ? 1 : 2
                for tap in 0..<tapCount {
                    while blinking && !Task.isCancelled {
                        setTypingFrame(0)
                        guard await pause(seconds: 0.045) else { return }
                    }
                    let frame = ((startingFrame - 1 + tap) % 2) + 1
                    setTypingFrame(frame)
                    guard await pause(seconds: Double.random(in: 0.135...0.220)) else {
                        return
                    }
                }
                setTypingFrame(0)
                guard await pause(seconds: Double.random(in: 0.35...1.00)) else { return }
            }
        }
    }

    private func setTypingFrame(_ frame: Int) {
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) { typingFrame = frame }
    }
}

/// NSImage(contentsOf:) 首次解码可能让短促的闭眼帧漏掉；缓存后再启动眨眼循环。
/// 画廊/编辑器也用它读缩略图，因此不能是 private。
enum PetImageCache {
    private static let cache = NSCache<NSURL, NSImage>()

    static func image(at url: URL) -> NSImage? {
        if let cached = cache.object(forKey: url as NSURL) { return cached }
        guard let image = NSImage(contentsOf: url) else { return nil }
        cache.setObject(image, forKey: url as NSURL)
        return image
    }

    /// 编辑器覆盖/清空槽位后按路径失效缓存，否则预览会继续显示旧图。
    static func remove(at url: URL) {
        cache.removeObject(forKey: url as NSURL)
    }

    static func preload(urls: [URL]) {
        for url in urls { _ = image(at: url) }
    }
}
