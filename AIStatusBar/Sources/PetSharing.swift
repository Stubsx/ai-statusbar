import Cocoa
import ImageIO

struct PetMetadata {
    var author = ""
    var version = "1.0.0"
    var license = ""
    var description = ""

    init(manifest: [String: Any] = [:]) {
        author = manifest["author"] as? String ?? ""
        version = manifest["version"] as? String ?? "1.0.0"
        license = manifest["license"] as? String ?? ""
        description = manifest["description"] as? String ?? ""
    }

    func applying(to manifest: [String: Any]) -> [String: Any] {
        var value = manifest
        value["author"] = String(author.trimmingCharacters(in: .whitespacesAndNewlines).prefix(120))
        value["version"] = String(version.trimmingCharacters(in: .whitespacesAndNewlines).prefix(40))
        value["license"] = String(license.trimmingCharacters(in: .whitespacesAndNewlines).prefix(160))
        value["description"] = String(description.prefix(1_000))
        return value
    }
}

struct PetAssetIssue {
    let blocking: Bool
    let message: String
}

enum PetSharing {
    enum SharingError: LocalizedError {
        case invalid(String)
        var errorDescription: String? {
            if case .invalid(let message) = self { return message }
            return nil
        }
    }

    static func manifest(at folder: URL) -> [String: Any] {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent("pet.json")),
              data.count <= 65_536 else { return [:] }
        return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    static func validate(_ theme: PetTheme) -> [PetAssetIssue] {
        var issues: [PetAssetIssue] = []
        var dimensions: [String: CGSize] = [:]
        var centers: [String: CGPoint] = [:]
        if theme.url(forSlot: .idle) == nil {
            issues.append(PetAssetIssue(blocking: false, message: "缺少空闲图，部分姿势将使用其他图片回退。"))
        }
        var assets = PetSlot.allCases.compactMap { slot in theme.url(forSlot: slot).map { (slot.rawValue, slot.displayName, $0) } }
        let preview = theme.folderURL.appendingPathComponent("preview.png")
        if FileManager.default.fileExists(atPath: preview.path) { assets.append(("preview", "预览图", preview)) }
        for (name, label, url) in assets {
            guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isSymbolicLinkKey]),
                  values.isSymbolicLink != true, (values.fileSize ?? 0) <= 32 * 1_024 * 1_024,
                  let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                  let width = properties[kCGImagePropertyPixelWidth] as? Int,
                  let height = properties[kCGImagePropertyPixelHeight] as? Int,
                  width > 0, height > 0, width <= 4_096, height <= 4_096 else {
                issues.append(PetAssetIssue(blocking: true, message: "\(label)：图片不可读、尺寸超过 4096 或文件超过 32 MB。"))
                continue
            }
            dimensions[name] = CGSize(width: width, height: height)
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: 128,
            ]
            if let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary),
               let bounds = alphaBounds(image) {
                centers[name] = CGPoint(x: bounds.midX, y: bounds.midY)
                if bounds.width > 0.98 || bounds.height > 0.98 {
                    issues.append(PetAssetIssue(blocking: false, message: "\(label)：图像贴近画布边缘，请确认透明背景与留白。"))
                }
            } else {
                issues.append(PetAssetIssue(blocking: true, message: "\(label)：没有可见像素或无法解析透明通道。"))
            }
        }
        if Set(dimensions.values.map { "\($0.width)x\($0.height)" }).count > 1 {
            issues.append(PetAssetIssue(blocking: false, message: "不同姿势的画布尺寸不一致，切换动作时可能跳动。"))
        }
        for (name, center) in centers where name.contains("-") {
            let base = String(name.split(separator: "-")[0])
            if let origin = centers[base], hypot(origin.x - center.x, origin.y - center.y) > 0.08 {
                issues.append(PetAssetIssue(blocking: false, message: "\(name)：主体位置偏移较大，请在动画预览中检查对齐。"))
            }
        }
        return issues
    }

    private static func alphaBounds(_ image: CGImage) -> CGRect? {
        let width = image.width, height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        return pixels.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height,
                                          bitsPerComponent: 8, bytesPerRow: width * 4,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            let bytes = buffer.bindMemory(to: UInt8.self)
            var minX = width, minY = height, maxX = -1, maxY = -1
            for y in 0..<height {
                for x in 0..<width where bytes[(y * width + x) * 4 + 3] > 12 {
                    minX = min(minX, x); maxX = max(maxX, x)
                    minY = min(minY, y); maxY = max(maxY, y)
                }
            }
            guard maxX >= minX else { return nil }
            return CGRect(x: Double(minX) / Double(width), y: Double(minY) / Double(height),
                          width: Double(maxX - minX + 1) / Double(width), height: Double(maxY - minY + 1) / Double(height))
        }
    }

    static func export(_ theme: PetTheme, to destination: URL) throws {
        let errors = validate(theme).filter(\.blocking)
        guard errors.isEmpty else { throw SharingError.invalid(errors.map(\.message).joined(separator: "\n")) }
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("lingmou-export-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: temporary) }
        let folder = temporary.appendingPathComponent("pet")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for slot in PetSlot.allCases {
            if let source = theme.url(forSlot: slot) {
                try FileManager.default.copyItem(at: source, to: folder.appendingPathComponent(slot.rawValue + ".png"))
            }
        }
        var value = manifest(at: theme.folderURL)
        value["name"] = theme.displayName
        value["nsfw"] = theme.isNSFW
        value["schema_version"] = 1
        value["preview"] = "preview.png"
        if value["version"] == nil { value["version"] = "1.0.0" }
        if value["author"] == nil { value["author"] = "未注明" }
        if value["license"] == nil { value["license"] = "未声明，请向作者确认分发授权" }
        try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys])
            .write(to: folder.appendingPathComponent("pet.json"), options: .atomic)
        let existingPreview = theme.folderURL.appendingPathComponent("preview.png")
        if let preview = FileManager.default.fileExists(atPath: existingPreview.path) ? existingPreview : theme.previewURL {
            try FileManager.default.copyItem(at: preview, to: folder.appendingPathComponent("preview.png"))
        }
        try templateGuide.write(to: folder.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        let zip = temporary.appendingPathComponent("pet.zip")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-c", "-k", "--norsrc", "--noextattr", "--keepParent", folder.path, zip.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw SharingError.invalid("无法生成桌宠 ZIP。") }
        // Atomic replace after a successful export; NSSavePanel owns any overwrite confirmation.
        try Data(contentsOf: zip).write(to: destination, options: .atomic)
    }

    /// Extract only known data files to paths chosen by us; never honor archive paths or symlinks.
    static func extractPackage(_ archive: URL, to destination: URL) throws {
        let size = try archive.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= 100 * 1_024 * 1_024 else { throw SharingError.invalid("桌宠包超过 100 MB。") }
        let listing = try output("/usr/bin/unzip", ["-Z1", archive.path], maximum: 256 * 1_024)
        let members = String(decoding: listing, as: UTF8.self).split(whereSeparator: \.isNewline).map(String.init)
        let allowed = Set(PetSlot.allCases.map { $0.rawValue + ".png" } + ["pet.json", "preview.png"])
        var selected: [String: String] = [:]
        var roots = Set<String>()
        for member in members {
            let pieces = member.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
            guard !member.hasPrefix("/"), !pieces.contains(".."),
                  !member.contains("\\"), !member.contains("*"), !member.contains("?"),
                  !member.contains("["), !member.contains("]") else {
                throw SharingError.invalid("桌宠包包含不支持的路径。")
            }
            guard !member.hasSuffix("/"), !pieces.contains("__MACOSX"),
                  let name = pieces.last, allowed.contains(name) else { continue }
            guard pieces.count <= 2, selected[name] == nil else {
                throw SharingError.invalid("请在 ZIP 根目录或单层文件夹中放置一套桌宠素材。")
            }
            roots.insert(pieces.dropLast().joined(separator: "/"))
            selected[name] = member
        }
        guard roots.count == 1, !selected.isEmpty else { throw SharingError.invalid("没有找到单套有效的桌宠素材。") }
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        for (name, member) in selected {
            let data = try output("/usr/bin/unzip", ["-p", archive.path, member],
                                  maximum: name == "pet.json" ? 65_536 : 32 * 1_024 * 1_024)
            try data.write(to: destination.appendingPathComponent(name), options: .atomic)
        }
        guard let theme = PetThemeStore.loadTheme(folder: destination, isBuiltIn: false) else {
            throw SharingError.invalid("桌宠包没有有效的姿势图片。")
        }
        let errors = validate(theme).filter(\.blocking)
        guard errors.isEmpty else { throw SharingError.invalid(errors.map(\.message).joined(separator: "\n")) }
    }

    private static func output(_ executable: String, _ arguments: [String], maximum: Int) throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        var data = Data()
        while let chunk = try pipe.fileHandleForReading.read(upToCount: 65_536), !chunk.isEmpty {
            guard data.count + chunk.count <= maximum else {
                process.terminate()
                try? pipe.fileHandleForReading.close()
                process.waitUntilExit()
                throw SharingError.invalid("桌宠包解压后的素材过大。")
            }
            data.append(chunk)
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw SharingError.invalid("无法读取 ZIP，请检查文件是否完整。") }
        return data
    }

    static func makeTemplate(at folder: URL) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        guard let context = CGContext(data: nil, width: 512, height: 512, bitsPerComponent: 8,
                                      bytesPerRow: 512 * 4, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw SharingError.invalid("无法创建模板画布。")
        }
        context.setFillColor(CGColor(red: 0.20, green: 0.57, blue: 0.94, alpha: 1))
        context.fillEllipse(in: CGRect(x: 66, y: 66, width: 380, height: 380))
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fillEllipse(in: CGRect(x: 183, y: 224, width: 38, height: 90))
        context.fillEllipse(in: CGRect(x: 291, y: 224, width: 38, height: 90))
        guard let image = context.makeImage(),
              let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
            throw SharingError.invalid("无法创建模板图片。")
        }
        try data.write(to: folder.appendingPathComponent("idle.png"), options: .atomic)
        try data.write(to: folder.appendingPathComponent("preview.png"), options: .atomic)
        let manifest: [String: Any] = [
            "name": "蓝点 · 创作起点", "author": "灵眸项目", "version": "1.0.0", "license": "MIT",
            "description": "替换空闲姿势开始创作，其余动作可逐步补齐。", "preview": "preview.png", "schema_version": 1,
        ]
        try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
            .write(to: folder.appendingPathComponent("pet.json"), options: .atomic)
        try templateGuide.write(to: folder.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
    }

    static let templateGuide = """
    # 灵眸桌宠创作模板
    1. idle.png 是推荐的基础姿势，其他姿势缺失时会自动回退。
    2. 所有图片使用相同画布，推荐 1024 × 1024、透明背景；主体中心与脚底位置保持一致。
    3. 可选 working/loading/sleeping/celebrating/error.png。
    4. 可选姿势名-blink.png，以及 working-type-left.png、working-type-right.png。
    5. 在 pet.json 填写 name、author、version、license、description；保留素材本身的授权说明。
    6. 在灵眸预览全部动作并检查素材，然后导出 ZIP。ZIP 根目录或单层文件夹只放一套素材。
    单张图片不超过 4096 × 4096 与 32 MB，压缩包不超过 100 MB。
    """
}
