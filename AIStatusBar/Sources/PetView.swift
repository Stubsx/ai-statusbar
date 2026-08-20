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
        VStack(spacing: s(4)) {
            if celebratingSerial > 0 {
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
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            } else if hovered {
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
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            } else {
                Color.clear.frame(height: s(30))
            }

            // 保持同一个 Sprite 实例，状态换图时沿用当前动画相位，避免动作重新起步。
            PetSprite(mood: mood, theme: theme, scale: scale)
        }
        .frame(width: s(220), height: s(270), alignment: .bottom)
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
}

/// 设置里的形象编辑器也复用这个 Sprite 做实时预览，因此不能是 private。
struct PetSprite: View {
    let mood: PetMood
    /// nil（一个素材都没有）时显示占位图标。
    let theme: PetTheme?
    let scale: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var animating = false
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
        let active = animating && !reduceMotion
        ZStack(alignment: .topTrailing) {
            PetBackdropEffects(mood: mood, active: active, scale: scale)

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

            PetForegroundEffects(mood: mood, active: active, scale: scale)

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
            startAnimations()
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
            restartAnimations()
            restartBlinking(newMood, theme: theme)
            restartTyping(newMood, theme: theme)
        }
        .onChange(of: theme) { newTheme in
            restartAnimations()
            restartBlinking(mood, theme: newTheme)
            restartTyping(mood, theme: newTheme)
        }
        .onChange(of: reduceMotion) { _ in
            restartBlinking(mood, theme: theme)
            restartTyping(mood, theme: theme)
        }
        // 窗口被 orderOut（如全屏自动隐藏）时，repeatForever 的层动画会被系统丢弃；
        // 恢复显示时 animating 值没变，.animation(value:) 不会重新提交，特效永久冻结。
        // 遮挡状态恢复可见时主动重启一轮动画，眨眼/打字任务也一并兜底重启。
        .onReceive(
            NotificationCenter.default.publisher(for: NSWindow.didChangeOcclusionStateNotification)
        ) { note in
            guard let window = note.object as? NSWindow,
                  window.occlusionState.contains(.visible)
            else { return }
            restartAnimations()
            restartBlinking(mood, theme: theme)
            restartTyping(mood, theme: theme)
        }
    }

    private func startAnimations() {
        guard !reduceMotion else { return }
        DispatchQueue.main.async { animating = true }
    }

    private func restartAnimations() {
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) { animating = false }
        startAnimations()
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

/// 放在原画后方的效果，避免改变人物 PNG 的透明边缘。
private struct PetBackdropEffects: View {
    let mood: PetMood
    let active: Bool
    let scale: CGFloat

    private func s(_ v: CGFloat) -> CGFloat { v * scale }

    @ViewBuilder
    var body: some View {
        if mood != .error {
            Ellipse()
                .fill(Color.black.opacity(active ? 0.055 : 0.10))
                .frame(width: s(72), height: s(8))
                .scaleEffect(x: active ? shadowScale : 1, y: 1)
                .offset(x: s(-69), y: s(218))
                .animation(
                    .easeInOut(duration: shadowDuration).repeatForever(autoreverses: true),
                    value: active
                )
        }

    }

    private var shadowScale: CGFloat {
        switch mood {
        case .celebrating: return 0.76
        case .working: return 0.88
        case .loading: return 0.92
        case .idle: return 0.96
        case .sleeping: return 0.98
        case .error: return 1
        }
    }

    private var shadowDuration: Double {
        switch mood {
        case .celebrating: return 0.46
        case .working: return 0.92
        case .loading: return 1.2
        case .idle: return 2.1
        case .sleeping: return 2.6
        case .error: return 1
        }
    }
}

/// 徽标、粒子都是独立图层；增加动态感时不会让人物本身产生残影。
private struct PetForegroundEffects: View {
    let mood: PetMood
    let active: Bool
    let scale: CGFloat

    private func s(_ v: CGFloat) -> CGFloat { v * scale }

    @ViewBuilder
    var body: some View {
        switch mood {
        case .loading:
            HStack(spacing: s(4)) {
                ForEach(0..<3, id: \.self) { index in
                    Circle()
                        .fill(Color.blue.opacity(active ? 0.84 : 0.42))
                        .frame(width: s(6), height: s(6))
                        .scaleEffect(active ? 1.0 : 0.75)
                        .animation(
                            .easeInOut(duration: 0.62)
                                .repeatForever(autoreverses: true)
                                .delay(Double(index) * 0.20),
                            value: active
                        )
                }
            }
            .padding(.horizontal, s(8))
            .padding(.vertical, s(6))
            .background(Capsule().fill(.ultraThinMaterial))
            .offset(x: s(-4), y: s(8))

        case .sleeping:
            driftingZ("Z", size: 18, delay: 0, x: -9)
            driftingZ("z", size: 14, delay: 0.7, x: -25)
            driftingZ("z", size: 11, delay: 1.4, x: -39)

        case .celebrating:
            sparkle(size: 19, delay: 0, duration: 0.52, x: -12, y: 4, color: .yellow)
            sparkle(size: 14, delay: 0.18, duration: 0.52, x: -172, y: 35, color: .yellow)
            sparkle(size: 12, delay: 0.36, duration: 0.52, x: -155, y: 96, color: .orange)

        case .error:
            Image(systemName: "exclamationmark")
                .font(.system(size: s(13), weight: .black))
                .foregroundColor(.white)
                .frame(width: s(25), height: s(25))
                .background(Circle().fill(Color.red))
                .overlay(Circle().stroke(Color.white.opacity(0.85), lineWidth: s(1.5)))
                .shadow(color: .red.opacity(0.35), radius: s(5))
                .scaleEffect(active ? 1.0 : 0.95)
                .animation(.easeInOut(duration: 0.75).repeatForever(autoreverses: true), value: active)
                .padding(.top, s(10))
                .padding(.trailing, s(8))

        case .working:
            sparkle(size: 15, delay: 0, duration: 0.92, x: -137, y: 108, color: .cyan)
            sparkle(size: 11, delay: 0.46, duration: 0.92, x: -169, y: 132, color: .green)

        case .idle:
            EmptyView()
        }
    }

    private func driftingZ(_ text: String, size: CGFloat, delay: Double, x: CGFloat) -> some View {
        Text(text)
            .font(.system(size: s(size), weight: .bold, design: .rounded))
            .foregroundColor(Color.blue.opacity(active ? 0.25 : 0.85))
            .offset(x: s(x), y: active ? s(-7) : s(16))
            .animation(
                .easeOut(duration: 1.45).repeatForever(autoreverses: false).delay(delay),
                value: active
            )
    }

    private func sparkle(
        size: CGFloat,
        delay: Double,
        duration: Double,
        x: CGFloat,
        y: CGFloat,
        color: Color
    ) -> some View {
        Image(systemName: "sparkle")
            .font(.system(size: s(size), weight: .semibold))
            .foregroundColor(color)
            .shadow(color: color.opacity(0.30), radius: s(3))
            .scaleEffect(active ? 0.96 : 0.62)
            .opacity(active ? 0.88 : 0.30)
            .offset(x: s(x), y: s(y))
            .animation(
                .easeInOut(duration: duration).repeatForever(autoreverses: true).delay(delay),
                value: active
            )
    }
}
