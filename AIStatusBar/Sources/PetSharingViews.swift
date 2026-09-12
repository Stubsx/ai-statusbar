import Cocoa
import SwiftUI
import UniformTypeIdentifiers

struct PetSharingControls: View {
    @ObservedObject var settings: SettingsStore
    @ObservedObject var catalog: PetCatalog
    @State private var message: String?
    @State private var gallery = false
    @State private var exporting = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let theme = catalog.currentTheme(id: settings.petAppearance) {
                let metadata = PetMetadata(manifest: PetSharing.manifest(at: theme.folderURL))
                Text("\(metadata.author.isEmpty ? "作者未填写" : metadata.author) · v\(metadata.version)")
                    .font(.system(size: 11, weight: .medium))
                Text(metadata.license.isEmpty ? "授权信息未填写，可在自定义形象编辑器中补充。" : "授权：\(metadata.license)")
                    .font(.system(size: 10)).foregroundColor(.secondary)
                HStack(spacing: 12) {
                    Button(exporting ? "导出中…" : "导出 ZIP…") { export(theme) }.disabled(exporting)
                    Button("检查素材") {
                        let issues = PetSharing.validate(theme)
                        message = issues.isEmpty ? "检查通过：图片尺寸、透明留白与动画位置未发现问题。" :
                            issues.map { "\($0.blocking ? "需修复" : "建议")：\($0.message)" }.joined(separator: "\n")
                    }
                }.controlSize(.small)
            }
            Divider().opacity(0.4)
            HStack {
                Button("作品目录与模板") { gallery = true }
                Spacer()
                Button("导出创作模板…") { export(nil) }.disabled(exporting)
            }.controlSize(.small)
            Text("导出包含预览图、作者、版本与授权信息。只分享你有权分发的素材。")
                .font(.system(size: 10)).foregroundColor(.secondary)
        }
        .padding(14)
        .alert("桌宠分享", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("好", role: .cancel) {}
        } message: { Text(message ?? "") }
        .sheet(isPresented: $gallery) { PetGalleryView(settings: settings, catalog: catalog) }
    }

    private func export(_ theme: PetTheme?) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.zip]
        panel.nameFieldStringValue = (theme?.displayName ?? "灵眸创作模板").replacingOccurrences(of: "/", with: "-") + ".zip"
        panel.title = theme == nil ? "导出创作模板" : "导出桌宠"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        exporting = true
        DispatchQueue.global(qos: .userInitiated).async {
            let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("lingmou-template-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: temporary) }
            var result = "已导出，可通过“从 ZIP 导入形象”安装。"
            do {
                if let theme { try PetSharing.export(theme, to: url) }
                else {
                    try PetSharing.makeTemplate(at: temporary)
                    guard let template = PetThemeStore.loadTheme(folder: temporary, isBuiltIn: false) else {
                        throw PetSharing.SharingError.invalid("无法读取创作模板。")
                    }
                    try PetSharing.export(template, to: url)
                }
            } catch { result = error.localizedDescription }
            DispatchQueue.main.async {
                exporting = false
                message = result
            }
        }
    }
}

struct PetGalleryEntry: Decodable, Identifiable {
    let id: String
    let name: String
    let author: String
    let version: String
    let license: String
    let summary: String
    let template: Bool?
    let directory: String?

    static func load() -> [Self] {
        guard let url = Bundle.main.url(forResource: "index", withExtension: "json", subdirectory: "PetGallery"),
              let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([Self].self, from: data)) ?? []
    }
}

struct PetGalleryView: View {
    @ObservedObject var settings: SettingsStore
    @ObservedObject var catalog: PetCatalog
    @Environment(\.dismiss) private var dismiss
    @State private var message: String?
    private let entries = PetGalleryEntry.load()

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("作品目录").font(.custom("PingFangSC-Semibold", size: 20))
                Spacer()
                Button("完成") { dismiss() }
            }
            Text("从一个可编辑的模板开始。社区作品通过目录清单与素材包加入。")
                .font(.system(size: 12)).foregroundColor(.secondary)
            ScrollView {
                VStack(spacing: 10) {
                    ForEach(entries) { entry in
                        HStack(alignment: .top, spacing: 14) {
                            ZStack {
                                Circle().fill(Color(red: 0.20, green: 0.57, blue: 0.94))
                                HStack(spacing: 9) {
                                    Capsule().fill(.white).frame(width: 5, height: 15)
                                    Capsule().fill(.white).frame(width: 5, height: 15)
                                }
                            }.frame(width: 52, height: 52)
                            VStack(alignment: .leading, spacing: 5) {
                                Text(entry.name).font(.system(size: 13, weight: .semibold))
                                Text("\(entry.author) · v\(entry.version) · \(entry.license)")
                                    .font(.system(size: 10)).foregroundColor(.secondary)
                                Text(entry.summary).font(.system(size: 11)).foregroundColor(.secondary)
                            }
                            Spacer()
                            Button("安装") { install(entry) }.controlSize(.small)
                        }
                        .padding(14).background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.045)))
                    }
                }
            }
            if let message { Text(message).font(.system(size: 11)).foregroundColor(.secondary) }
            Button("打开创作与贡献指南") {
                if let url = Bundle.main.url(forResource: "PETS", withExtension: "md", subdirectory: "Guides") {
                    NSWorkspace.shared.open(url)
                }
            }.controlSize(.small)
        }.padding(24).frame(width: 500, height: 340)
    }

    private func install(_ entry: PetGalleryEntry) {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("lingmou-gallery-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: temporary) }
        do {
            let source: URL
            if entry.template == true {
                try PetSharing.makeTemplate(at: temporary)
                source = temporary
            } else if let relative = entry.directory, !relative.hasPrefix("/"),
                      !relative.split(separator: "/").contains(".."), let root = Bundle.main.resourceURL {
                source = root.appendingPathComponent(relative)
            } else { throw PetSharing.SharingError.invalid("目录条目缺少有效素材位置。") }
            guard let theme = PetThemeStore.loadTheme(folder: source, isBuiltIn: false),
                  let draft = catalog.makeDraft(editing: theme) else {
                throw PetSharing.SharingError.invalid("素材包无法安装，请检查本地素材库。")
            }
            defer { catalog.discardDraft(draft.draftURL) }
            guard let installed = catalog.install(draftAt: draft.draftURL, name: entry.name, replacing: nil) else {
                throw PetSharing.SharingError.invalid("无法写入素材库，请检查目录权限。")
            }
            settings.petAppearance = installed.id
            message = "已安装到自定义素材库，可以继续编辑或导出分享。"
        } catch { message = error.localizedDescription }
    }
}
