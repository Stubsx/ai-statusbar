import Cocoa
import Combine
import SwiftUI

// MARK: - 桌宠素材槽位
// 一个形象 = 一组按约定命名的 PNG：{状态}.png 为主姿势，
// {状态}-blink.png 为闭眼帧，working-type-left/right.png 为打字动画帧。
// 槽位名即文件名（不含扩展名），内置与用户自定义形象共用同一套约定。

enum PetSlot: String, CaseIterable, Identifiable, Equatable {
    case idle, working, loading, sleeping, celebrating, error
    case idleBlink = "idle-blink"
    case workingBlink = "working-blink"
    case loadingBlink = "loading-blink"
    case celebratingBlink = "celebrating-blink"
    case errorBlink = "error-blink"
    case workingTypeLeft = "working-type-left"
    case workingTypeRight = "working-type-right"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .idle: return "空闲"
        case .working: return "工作"
        case .loading: return "加载"
        case .sleeping: return "睡觉"
        case .celebrating: return "庆祝"
        case .error: return "错误"
        case .idleBlink: return "空闲·眨眼"
        case .workingBlink: return "工作·眨眼"
        case .loadingBlink: return "加载·眨眼"
        case .celebratingBlink: return "庆祝·眨眼"
        case .errorBlink: return "错误·眨眼"
        case .workingTypeLeft: return "工作·左手"
        case .workingTypeRight: return "工作·右手"
        }
    }

    /// 上传页里的用途说明，让用户知道这张图什么时候出现。
    var detail: String {
        switch self {
        case .idle: return "AI 工具空闲待命时展示"
        case .working: return "有任务正在处理时展示"
        case .loading: return "还没读到工具状态时短暂展示"
        case .sleeping: return "所有工具都没有运行时展示（本身闭眼，无需眨眼帧）"
        case .celebrating: return "任务完成时展示约 3 秒"
        case .error: return "状态采集出错时展示"
        case .idleBlink: return "空闲姿势的闭眼帧，缺失则空闲时不眨眼"
        case .workingBlink: return "工作姿势的闭眼帧，缺失则工作时不眨眼"
        case .loadingBlink: return "加载姿势的闭眼帧，缺失则加载时不眨眼"
        case .celebratingBlink: return "庆祝姿势的闭眼帧，缺失则庆祝时不眨眼"
        case .errorBlink: return "错误姿势的闭眼帧，缺失则错误时不眨眼"
        case .workingTypeLeft: return "工作打字动画的左手帧，与右手帧配对使用"
        case .workingTypeRight: return "工作打字动画的右手帧，与左手帧配对使用"
        }
    }

    /// 除空闲外的槽位都可缺省：主姿势回退到空闲图，变体帧直接关闭对应动画。
    var isOptional: Bool { self != .idle }

    /// 上传页占位图标（macOS 12 可用的 SF Symbol，取不到时会退化为空占位）。
    var symbolName: String {
        switch self {
        case .idle: return "person"
        case .working: return "keyboard"
        case .loading: return "hourglass"
        case .sleeping: return "zzz"
        case .celebrating: return "hands.clap"
        case .error: return "exclamationmark.triangle"
        case .idleBlink, .workingBlink, .loadingBlink, .celebratingBlink, .errorBlink:
            return "eye.slash"
        case .workingTypeLeft: return "arrow.left"
        case .workingTypeRight: return "arrow.right"
        }
    }
}

extension PetMood {
    /// 状态机到素材槽位的映射；文件解析与兜底都由 PetTheme 完成。
    var baseSlot: PetSlot {
        switch self {
        case .loading: return .loading
        case .working: return .working
        case .idle: return .idle
        case .sleeping: return .sleeping
        case .celebrating: return .celebrating
        case .error: return .error
        }
    }
}

// MARK: - 桌宠形象

/// 一个可用的桌宠形象：内置（app bundle 内 Pet/{id}/）或用户自定义（~/.ai-statusbar/Pets/{id}/）。
struct PetTheme: Identifiable, Equatable {
    let id: String
    let displayName: String
    let folderURL: URL
    let isBuiltIn: Bool
    /// 已提供素材的槽位名集合（不含扩展名）。
    let filledSlots: Set<String>

    func url(forSlot slot: PetSlot) -> URL? {
        filledSlots.contains(slot.rawValue)
            ? folderURL.appendingPathComponent(slot.rawValue + ".png") : nil
    }

    /// 画廊/编辑器缩略图：优先空闲姿势，其次任意一张已有素材。
    var previewURL: URL? {
        url(forSlot: .idle) ?? PetSlot.allCases.lazy.compactMap { url(forSlot: $0) }.first
    }

    /// 主姿势兜底链：缺哪个状态都用空闲图顶替；空闲本身缺失时反向用工作图，
    /// 再不行就用任意一张，保证任何时刻都有图可显示。
    func imageURL(for mood: PetMood) -> URL? {
        let base = mood.baseSlot
        if let url = url(forSlot: base) { return url }
        let fallback: PetSlot = base == .idle ? .working : .idle
        if let url = url(forSlot: fallback) { return url }
        return previewURL
    }

    /// 睡觉姿势本身闭眼；眨眼帧只有在该姿势主图真实存在（未被兜底）时才有意义。
    func blinkURL(for mood: PetMood) -> URL? {
        let base = mood.baseSlot
        guard base != .sleeping, url(forSlot: base) != nil,
              let blinkSlot = PetSlot(rawValue: base.rawValue + "-blink")
        else { return nil }
        return url(forSlot: blinkSlot)
    }

    /// 工作状态的两帧打字动画；任一帧缺失就整体不启用。
    func typingURLs(for mood: PetMood) -> [URL] {
        guard case .working = mood, url(forSlot: .working) != nil else { return [] }
        return [url(forSlot: .workingTypeLeft), url(forSlot: .workingTypeRight)]
            .compactMap { $0 }
    }
}

// MARK: - 形象目录扫描

enum PetThemeStore {
    /// 从 bundle（内置）或 ~/.ai-statusbar/Pets（自定义）读取一个形象目录。
    /// 目录里没有任何约定命名的 PNG 时返回 nil（扫描时跳过）。
    static func loadTheme(folder: URL, isBuiltIn: Bool) -> PetTheme? {
        let fm = FileManager.default
        let files = (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        let knownSlots = Set(PetSlot.allCases.map(\.rawValue))
        let pngNames = Set(
            files
                .filter { $0.pathExtension.lowercased() == "png" }
                .map { $0.deletingPathExtension().lastPathComponent }
        )
        let filled = pngNames.intersection(knownSlots)
        guard !filled.isEmpty else { return nil }

        var displayName = folder.lastPathComponent
        if let jsonURL = files.first(where: { $0.lastPathComponent == "pet.json" }),
           let data = try? Data(contentsOf: jsonURL),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let name = obj["name"] as? String, !name.isEmpty
        {
            displayName = name
        }
        return PetTheme(
            id: folder.lastPathComponent,
            displayName: displayName,
            folderURL: folder,
            isBuiltIn: isBuiltIn,
            filledSlots: filled
        )
    }

    /// 扫描根目录下的所有形象子目录（跳过隐藏目录，如编辑过程中的 .draft-*）。
    static func scan(root: URL, isBuiltIn: Bool) -> [PetTheme] {
        let fm = FileManager.default
        guard let dirs = try? fm.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        return dirs
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true }
            .compactMap { loadTheme(folder: $0, isBuiltIn: isBuiltIn) }
    }
}

// MARK: - 形象目录管理（内置 + 用户自定义）

/// 编辑器的一次会话：草稿目录 + 可能正在改的已有形象。
struct PetEditorContext: Identifiable {
    let id = UUID()
    let draftURL: URL
    let editingThemeID: String?
    let initialName: String
}

final class PetCatalog: ObservableObject {
    static let defaultThemeID = "rem"
    /// 用户自定义形象目录：与 settings.json 同级，app 更新不丢失，也不影响代码签名。
    static let defaultUserPetsDirectory = URL(
        fileURLWithPath: NSHomeDirectory() + "/.ai-statusbar/Pets", isDirectory: true
    )

    @Published private(set) var themes: [PetTheme] = []

    /// 可注入用户目录，便于测试自定义形象的完整生命周期。
    let userPetsDirectory: URL

    private let fm = FileManager.default

    init(userPetsDirectory: URL = PetCatalog.defaultUserPetsDirectory) {
        self.userPetsDirectory = userPetsDirectory
        try? fm.createDirectory(
            at: userPetsDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        removeStaleDrafts()
        reload()
    }

    /// 选中的形象可能已被删除；取不到时回退到默认内置形象。
    func currentTheme(id: String) -> PetTheme? {
        themes.first { $0.id == id }
            ?? themes.first { $0.id == Self.defaultThemeID }
            ?? themes.first
    }

    func reload() {
        var all: [PetTheme] = []
        if let petRoot = Bundle.main.resourceURL?.appendingPathComponent("Pet", isDirectory: true),
           fm.fileExists(atPath: petRoot.path)
        {
            all += PetThemeStore.scan(root: petRoot, isBuiltIn: true)
        }
        all += PetThemeStore.scan(root: userPetsDirectory, isBuiltIn: false)
        // 空目录（比如只剩 pet.json）不会出现在列表里，但会把 id 占住；去掉重复 id 保留第一个。
        var seen = Set<String>()
        themes = all.filter { seen.insert($0.id).inserted }
    }

    // MARK: 编辑草稿
    // 编辑（含新建）都在独立草稿目录里进行：取消直接丢弃，保存时整体替换目标目录，
    // 这样编辑已有形象时中途取消不会破坏原始素材。

    /// 新建草稿；editing 传入已有自定义形象时先复制其素材，用于“编辑”。
    func makeDraft(editing source: PetTheme? = nil) -> PetEditorContext? {
        let draftURL = userPetsDirectory
            .appendingPathComponent(".draft-\(UUID().uuidString)", isDirectory: true)
        do {
            try fm.createDirectory(at: draftURL, withIntermediateDirectories: true)
            if let source {
                for slot in PetSlot.allCases {
                    if let url = source.url(forSlot: slot) {
                        let dest = draftURL.appendingPathComponent(slot.rawValue + ".png")
                        try? fm.copyItem(at: url, to: dest)
                    }
                }
            }
            return PetEditorContext(
                draftURL: draftURL,
                editingThemeID: source?.id,
                initialName: source?.displayName ?? ""
            )
        } catch {
            return nil
        }
    }

    /// 丢弃草稿目录。
    func discardDraft(_ draftURL: URL) {
        try? fm.removeItem(at: draftURL)
    }

    /// 把一张图片导入草稿的指定槽位；统一转成 PNG 再落盘。
    @discardableResult
    func importImage(_ source: URL, toSlot slot: PetSlot, draftURL: URL) -> Bool {
        guard let image = NSImage(contentsOf: source),
              let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:])
        else { return false }
        let dest = draftURL.appendingPathComponent(slot.rawValue + ".png")
        do {
            PetImageCache.remove(at: dest)
            try? fm.removeItem(at: dest)
            try png.write(to: dest, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    /// 清空草稿槽位（仅删文件，目录保留）。
    func clearSlot(_ slot: PetSlot, draftURL: URL) {
        let url = draftURL.appendingPathComponent(slot.rawValue + ".png")
        PetImageCache.remove(at: url)
        try? fm.removeItem(at: url)
    }

    /// 草稿目录的即时快照，供编辑器预览（可能一张图都没有，也返回有效主题）。
    func draftTheme(at draftURL: URL) -> PetTheme {
        PetThemeStore.loadTheme(folder: draftURL, isBuiltIn: false)
            ?? PetTheme(
                id: ".draft",
                displayName: "",
                folderURL: draftURL,
                isBuiltIn: false,
                filledSlots: []
            )
    }

    /// 保存草稿：写 manifest、替换目标目录、刷新列表。返回安装后的形象。
    @discardableResult
    func install(draftAt draftURL: URL, name: String, replacing editingThemeID: String?) -> PetTheme? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let id = editingThemeID ?? UUID().uuidString
        let dest = userPetsDirectory.appendingPathComponent(id, isDirectory: true)
        do {
            let manifest: [String: Any] = ["id": id, "name": trimmed]
            let data = try JSONSerialization.data(
                withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys]
            )
            try data.write(to: draftURL.appendingPathComponent("pet.json"), options: .atomic)
            try? fm.removeItem(at: dest)
            try fm.moveItem(at: draftURL, to: dest)
            reload()
            return themes.first { $0.id == id }
        } catch {
            return nil
        }
    }

    /// 删除用户自定义形象（内置形象不可删）。
    func delete(theme: PetTheme) {
        guard !theme.isBuiltIn else { return }
        try? fm.removeItem(at: theme.folderURL)
        reload()
    }

    /// 上次异常退出留下的草稿目录在启动时清理。
    private func removeStaleDrafts() {
        let contents = (try? fm.contentsOfDirectory(
            at: userPetsDirectory, includingPropertiesForKeys: nil
        )) ?? []
        for url in contents where url.lastPathComponent.hasPrefix(".draft-") {
            try? fm.removeItem(at: url)
        }
    }
}
