import SwiftUI

enum PanelPage: String, CaseIterable, Identifiable {
    case status, usage, heat, quota

    var id: String { rawValue }
    var title: String {
        switch self {
        case .status: return "状态"
        case .usage: return "用量"
        case .heat: return "活跃"
        case .quota: return "配额"
        }
    }
    var shortcut: String {
        switch self {
        case .status: return "1"
        case .usage: return "2"
        case .heat: return "3"
        case .quota: return "4"
        }
    }

    static func restored(_ value: String?) -> Self {
        value.flatMap(Self.init(rawValue:)) ?? .status
    }
}

/// Compact direct navigation, with frosted overflow edges on the native scroll strip.
struct PanelPageTabs: View {
    @Binding var selection: PanelPage
    @State private var contentFrame = CGRect.zero

    // 42pt 按钮 + 5pt 间距：162pt 一次露出三个半按钮，半截提示可继续滚动
    private let stripWidth: CGFloat = 162
    private let edgeWidth: CGFloat = 18

    private var leadingOverflow: Double { min(1, max(0, -contentFrame.minX / 8)) }
    private var trailingOverflow: Double { min(1, max(0, (contentFrame.maxX - stripWidth) / 8)) }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 5) {
                    ForEach(PanelPage.allCases) { page in
                        Button { selection = page } label: {
                            Text(page.title)
                                .font(.system(size: 11, weight: selection == page ? .semibold : .medium))
                                .foregroundColor(selection == page ? .accentColor : .secondary)
                                .frame(width: 42, height: 24)
                                .background(RoundedRectangle(cornerRadius: 6).fill(
                                    selection == page ? Color.accentColor.opacity(0.12) : Color.primary.opacity(0.045)))
                                .contentShape(RoundedRectangle(cornerRadius: 6))
                        }
                        .buttonStyle(.plain)
                        .keyboardShortcut(KeyEquivalent(Character(page.shortcut)), modifiers: .command)
                        .accessibilityIdentifier("panel-tab-\(page.rawValue)")
                        .accessibilityAddTraits(selection == page ? .isSelected : [])
                        .help("\(page.title)（⌘\(page.shortcut)）· 左右滚动可选择其他页面")
                        .id(page)
                    }
                }
                .background(GeometryReader { geometry in
                    // Read within the native scroll content: preferences do not
                    // cross its hosting boundary on supported macOS versions.
                    Color.clear
                        .onAppear { contentFrame = geometry.frame(in: .named("panel-page-strip")) }
                        .onChange(of: geometry.frame(in: .named("panel-page-strip"))) { contentFrame = $0 }
                })
            }
            .onAppear { proxy.scrollTo(selection, anchor: .center) }
            .onChange(of: selection) { page in proxy.scrollTo(page, anchor: .center) }
        }
        .frame(width: stripWidth, height: 24)
        .coordinateSpace(name: "panel-page-strip")
        .overlay(alignment: .leading) { frostedEdge(leading: true).opacity(leadingOverflow) }
        .overlay(alignment: .trailing) { frostedEdge(leading: false).opacity(trailingOverflow) }
        .mask(LinearGradient(stops: [
            .init(color: .white.opacity(1 - leadingOverflow), location: 0),
            .init(color: .white, location: edgeWidth / stripWidth),
            .init(color: .white, location: 1 - edgeWidth / stripWidth),
            .init(color: .white.opacity(1 - trailingOverflow), location: 1)
        ], startPoint: .leading, endPoint: .trailing))
        .accessibilityIdentifier("panel-page-tabs")
    }

    /// The material blurs passing labels; the outer mask blends the glass back
    /// into the panel. Only edges with more content receive this treatment.
    private func frostedEdge(leading: Bool) -> some View {
        Rectangle()
            .fill(.ultraThinMaterial)
            .frame(width: edgeWidth)
            .mask(LinearGradient(colors: [.white, .clear],
                                 startPoint: leading ? .leading : .trailing,
                                 endPoint: leading ? .trailing : .leading))
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}
