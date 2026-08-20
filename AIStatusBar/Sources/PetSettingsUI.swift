import Cocoa
import SwiftUI
import UniformTypeIdentifiers

// MARK: - 设置窗口「桌宠」页
// 形象画廊（内置 + 自定义）+ 宠物大小 + 素材上传编辑器。
// 分区/行布局沿用 SettingsView 的样式，但作为独立页面自带轻量版组件。

struct PetSettingsTab: View {
    @ObservedObject var settings: SettingsStore
    @ObservedObject var catalog: PetCatalog
    @State private var editor: PetEditorContext?
    @State private var themePendingDelete: PetTheme?
    @State private var showDeleteConfirm = false

    private let columns = [
        GridItem(.flexible(), spacing: 10),
        GridItem(.flexible(), spacing: 10),
        GridItem(.flexible(), spacing: 10),
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                section("形象") { gallery }
                section("宠物大小") { sizeRow }
                Spacer(minLength: 2)
            }
            .padding(.horizontal, 24)
            .padding(.top, 16)
            .padding(.bottom, 20)
        }
        .sheet(item: $editor) { context in
            PetEditorView(context: context, catalog: catalog) { installed in
                settings.petAppearance = installed.id
            }
        }
        .alert("删除自定义形象？", isPresented: $showDeleteConfirm) {
            Button("删除", role: .destructive) { confirmDelete() }
            Button("取消", role: .cancel) { themePendingDelete = nil }
        } message: {
            Text("将删除「\(themePendingDelete?.displayName ?? "")」的全部素材，无法恢复。")
        }
    }

    private var gallery: some View {
        VStack(alignment: .leading, spacing: 12) {
            LazyVGrid(columns: columns, spacing: 10) {
                ForEach(catalog.themes) { theme in
                    PetThemeCard(
                        theme: theme,
                        selected: theme.id == settings.petAppearance,
                        onSelect: { settings.petAppearance = theme.id },
                        onEdit: theme.isBuiltIn ? nil : { beginEditing(theme) },
                        onDelete: theme.isBuiltIn ? nil : {
                            themePendingDelete = theme
                            showDeleteConfirm = true
                        }
                    )
                }
                newThemeCard
            }

            // 右键卡片也可编辑/删除；这里给选中的自定义形象一个显式入口，避免只能靠右键发现。
            if let selected = catalog.currentTheme(id: settings.petAppearance),
               !selected.isBuiltIn
            {
                HStack(spacing: 10) {
                    Button("编辑「\(selected.displayName)」素材…") { beginEditing(selected) }
                    Button("删除…") {
                        themePendingDelete = selected
                        showDeleteConfirm = true
                    }
                }
                .controlSize(.small)
                .font(.system(size: 11))
            }

            Text("自定义形象保存在 ~/.ai-statusbar/Pets，App 更新不会丢失。点击「新建形象」按槽位逐张上传素材，缺省姿势会自动用空闲图代替。")
                .font(.system(size: 10))
                .foregroundColor(.secondary.opacity(0.8))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
    }

    private var newThemeCard: some View {
        Button(action: { editor = catalog.makeDraft() }) {
            VStack(spacing: 7) {
                Image(systemName: "plus")
                    .font(.system(size: 20, weight: .medium))
                    .foregroundColor(.secondary.opacity(0.7))
                Text("新建形象")
                    .font(.system(size: 11.5))
                    .foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 118)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.primary.opacity(0.02))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(
                        Color.primary.opacity(0.14),
                        style: StrokeStyle(lineWidth: 1, dash: [4, 3])
                    )
            )
        }
        .buttonStyle(.plain)
        .help("上传一组图片，创建自己的桌宠形象")
    }

    private var sizeRow: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text("拖动调整桌宠显示比例")
                    .font(.system(size: 12.5, weight: .medium))
                Text("脚底位置保持不变，放大后文字与徽标仍原生渲染")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary.opacity(0.85))
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 6) {
                Slider(
                    value: $settings.petScale,
                    in: SettingsStore.petScaleRange,
                    step: 0.05
                )
                .controlSize(.small)
                .frame(width: 88)
                Text("\(Int(settings.petScale * 100))%")
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundColor(.secondary)
                    .frame(width: 34, alignment: .trailing)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private func beginEditing(_ theme: PetTheme) {
        editor = catalog.makeDraft(editing: theme)
    }

    private func confirmDelete() {
        guard let theme = themePendingDelete else { return }
        catalog.delete(theme: theme)
        // 删掉的可能是当前选中的形象；currentTheme 对失效 id 会回退到默认形象，取其 id 写回。
        if settings.petAppearance == theme.id,
           let fallback = catalog.currentTheme(id: theme.id)
        {
            settings.petAppearance = fallback.id
        }
        themePendingDelete = nil
    }

    // MARK: 轻量布局组件（与 SettingsView 的样式一致）

    private func section<Content: View>(_ title: String,
                                        @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.secondary.opacity(0.9))
                .padding(.leading, 2)
            VStack(spacing: 0) { content() }
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.primary.opacity(0.045)))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(Color.primary.opacity(0.07), lineWidth: 0.5))
        }
    }
}

// MARK: - 形象卡片

private struct PetThemeCard: View {
    let theme: PetTheme
    let selected: Bool
    let onSelect: () -> Void
    let onEdit: (() -> Void)?
    let onDelete: (() -> Void)?

    var body: some View {
        Button(action: onSelect) {
            VStack(spacing: 6) {
                thumbnail
                    .frame(height: 64)
                    .frame(maxWidth: .infinity)
                VStack(spacing: 2) {
                    Text(theme.displayName)
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundColor(.primary)
                        .lineLimit(1)
                    Text(theme.isBuiltIn ? "内置" : "自定义")
                        .font(.system(size: 9.5))
                        .foregroundColor(.secondary.opacity(0.75))
                }
            }
            .padding(8)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(selected ? Color.accentColor.opacity(0.12) : Color.primary.opacity(0.045))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(
                        selected ? Color.accentColor.opacity(0.55) : Color.primary.opacity(0.07),
                        lineWidth: selected ? 1.2 : 0.5
                    )
            )
        }
        .buttonStyle(.plain)
        .contextMenu {
            if let onEdit { Button("编辑素材…", action: onEdit) }
            if let onDelete { Button("删除…", action: onDelete) }
        }
    }

    @ViewBuilder
    private var thumbnail: some View {
        if let url = theme.previewURL, let image = PetImageCache.image(at: url) {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
        } else {
            Image(systemName: "eye.fill")
                .font(.system(size: 20))
                .foregroundColor(.secondary.opacity(0.5))
                .frame(maxHeight: .infinity)
        }
    }
}

// MARK: - 素材上传编辑器

/// 新建/编辑自定义形象：按槽位说明逐张上传，实时预览，保存后立即启用。
struct PetEditorView: View {
    let context: PetEditorContext
    @ObservedObject var catalog: PetCatalog
    let onSaved: (PetTheme) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var name: String
    @State private var draftTheme: PetTheme
    @State private var previewIndex: Int = 0
    @State private var showImportError = false

    private static let previewMoods: [(String, PetMood)] = [
        ("空闲", .idle),
        ("工作", .working(taskCount: 2)),
        ("加载", .loading),
        ("睡觉", .sleeping),
        ("庆祝", .celebrating),
        ("错误", .error),
    ]

    init(context: PetEditorContext, catalog: PetCatalog, onSaved: @escaping (PetTheme) -> Void) {
        self.context = context
        _catalog = ObservedObject(wrappedValue: catalog)
        self.onSaved = onSaved
        _name = State(initialValue: context.initialName)
        _draftTheme = State(initialValue: catalog.draftTheme(at: context.draftURL))
    }

    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !draftTheme.filledSlots.isEmpty
    }

    private var previewMood: PetMood {
        Self.previewMoods.indices.contains(previewIndex)
            ? Self.previewMoods[previewIndex].1 : .idle
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    header
                    nameRow
                    previewBlock
                    slotGrid
                    legend
                }
                .padding(20)
            }
            Divider()
            footer
        }
        .frame(width: 560, height: 640)
        .alert("图片读取失败", isPresented: $showImportError) {
            Button("好", role: .cancel) {}
        } message: {
            Text("请选择 PNG、JPG 等常见图片文件后重试。")
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(context.editingThemeID == nil ? "新建自定义形象" : "编辑自定义形象")
                .font(.system(size: 14, weight: .semibold))
            Text("桌宠会按 AI 工具状态切换姿势。先上传「空闲」，其余姿势按需补充；缺省的姿势会自动用空闲图代替。")
                .font(.system(size: 10))
                .foregroundColor(.secondary.opacity(0.85))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var nameRow: some View {
        HStack {
            Text("形象名称")
                .font(.system(size: 12.5, weight: .medium))
            Spacer()
            TextField("例如：我的小猫", text: $name)
                .textFieldStyle(.roundedBorder)
                .frame(width: 190)
        }
    }

    private var previewBlock: some View {
        HStack(alignment: .center, spacing: 20) {
            PetSprite(mood: previewMood, theme: draftTheme, scale: 0.55)
                .frame(width: 140, height: 150)

            VStack(alignment: .leading, spacing: 10) {
                Picker("", selection: $previewIndex) {
                    ForEach(Array(Self.previewMoods.enumerated()), id: \.offset) { index, item in
                        Text(item.0).tag(index)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)

                Text("预览实时反映已上传的素材，眨眼、打字动画也会照常播放。")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary.opacity(0.85))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.primary.opacity(0.03))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.primary.opacity(0.06), lineWidth: 0.5)
        )
    }

    private var slotGrid: some View {
        LazyVGrid(columns: [
            GridItem(.flexible(), spacing: 10),
            GridItem(.flexible(), spacing: 10),
            GridItem(.flexible(), spacing: 10),
        ], spacing: 10) {
            ForEach(PetSlot.allCases) { slot in
                PetSlotCard(
                    slot: slot,
                    imageURL: draftTheme.url(forSlot: slot),
                    onImport: { importImage($0, for: slot) },
                    onClear: { clearSlot(slot) }
                )
            }
        }
    }

    private var legend: some View {
        Text("主姿势建议全部提供：缺省时用「空闲」代替；眨眼帧缺失则对应状态不眨眼；打字左右手帧需成对提供，缺失则不打字。建议使用透明背景 PNG，宽高比接近 200:226（其余比例会自动等比缩放）。")
            .font(.system(size: 10))
            .foregroundColor(.secondary.opacity(0.85))
            .fixedSize(horizontal: false, vertical: true)
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Text("已上传 \(draftTheme.filledSlots.count)/\(PetSlot.allCases.count) 张")
                .font(.system(size: 11).monospacedDigit())
                .foregroundColor(.secondary)
            Spacer()
            Button("取消", action: cancel)
            Button("保存并使用", action: save)
                .disabled(!canSave)
                .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private func importImage(_ source: URL, for slot: PetSlot) {
        if catalog.importImage(source, toSlot: slot, draftURL: context.draftURL) {
            draftTheme = catalog.draftTheme(at: context.draftURL)
        } else {
            showImportError = true
        }
    }

    private func clearSlot(_ slot: PetSlot) {
        catalog.clearSlot(slot, draftURL: context.draftURL)
        draftTheme = catalog.draftTheme(at: context.draftURL)
    }

    private func cancel() {
        catalog.discardDraft(context.draftURL)
        dismiss()
    }

    private func save() {
        guard let installed = catalog.install(
            draftAt: context.draftURL,
            name: name,
            replacing: context.editingThemeID
        ) else { return }
        onSaved(installed)
        dismiss()
    }
}

// MARK: - 素材槽位卡片

private struct PetSlotCard: View {
    let slot: PetSlot
    let imageURL: URL?
    let onImport: (URL) -> Void
    let onClear: () -> Void

    @State private var dropTargeted = false

    var body: some View {
        VStack(spacing: 6) {
            ZStack(alignment: .topTrailing) {
                preview
                    .frame(height: 60)
                    .frame(maxWidth: .infinity)
                    .frame(maxHeight: .infinity, alignment: .center)
                if imageURL != nil {
                    Button(action: onClear) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 13))
                            .foregroundColor(.secondary.opacity(0.8))
                    }
                    .buttonStyle(.plain)
                    .padding(4)
                }
            }
            VStack(spacing: 2) {
                Text(slot.displayName)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundColor(.primary)
                    .lineLimit(1)
                Text(slot.isOptional ? "可选" : "建议提供")
                    .font(.system(size: 9.5))
                    .foregroundColor(
                        slot.isOptional ? Color.secondary.opacity(0.7) : Color.accentColor.opacity(0.85)
                    )
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, minHeight: 116, alignment: .top)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(imageURL == nil ? Color.primary.opacity(0.02) : Color.primary.opacity(0.045))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(
                    imageURL == nil
                        ? Color.primary.opacity(dropTargeted ? 0.45 : 0.14)
                        : Color.primary.opacity(0.07),
                    lineWidth: 1
                )
        )
        .contentShape(Rectangle())
        .onTapGesture(perform: chooseImage)
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            handleDrop(providers)
        }
        .help("\(slot.detail)。点击选择或直接拖入图片。")
    }

    @ViewBuilder
    private var preview: some View {
        if let imageURL, let image = PetImageCache.image(at: imageURL) {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
        } else {
            VStack(spacing: 4) {
                Image(systemName: slot.symbolName)
                    .font(.system(size: 18))
                    .foregroundColor(.secondary.opacity(0.55))
                Text("点击或拖入")
                    .font(.system(size: 9.5))
                    .foregroundColor(.secondary.opacity(0.7))
            }
        }
    }

    private func chooseImage() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.image]
        panel.title = "选择「\(slot.displayName)」素材"
        panel.message = slot.detail
        if panel.runModal() == .OK, let url = panel.url {
            onImport(url)
        }
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first(where: { $0.canLoadObject(ofClass: URL.self) }) else {
            return false
        }
        _ = provider.loadObject(ofClass: URL.self) { url, _ in
            guard let url else { return }
            DispatchQueue.main.async { onImport(url) }
        }
        return true
    }
}
