import Cocoa

/// 菜单栏与桌面面板共用按 Harness 分组的会话列表。
enum MenuBarPresentation {
    static func update(_ button: NSStatusBarButton, data: StatusData?,
                       collectorError: String?, unreadCount: Int) {
        let tools = data?.tools ?? []
        let running = tools.reduce(0) { $0 + HarnessConversations.workingItems(for: $1).count }
        let hasError = collectorError != nil || tools.contains { $0.health?.state == "error" }
        button.image = image(marked: hasError || unreadCount > 0)
        button.imagePosition = .imageLeading
        button.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        button.title = running > 0 ? " \(running > 99 ? "99+" : String(running))" : ""
        var summary = ["灵眸"]
        if collectorError != nil {
            summary.append("状态暂未更新")
        } else if data == nil {
            summary.append("正在读取工具状态")
        } else {
            summary.append(running > 0 ? "\(running) 个任务运行中" : "当前没有运行中的任务")
        }
        if unreadCount > 0 { summary.append("\(unreadCount) 条会话待查看") }
        for tool in tools where tool.state != "off" || tool.health?.state == "error" {
            let state = tool.health?.state == "error" ? "读取异常" :
                (tool.state == "busy" ? "\(HarnessConversations.workingItems(for: tool).count) 个任务运行中" : "空闲")
            summary.append("\(tool.name) · \(state)")
        }
        button.toolTip = summary.joined(separator: "\n")
        button.setAccessibilityLabel("灵眸")
        button.setAccessibilityValue(summary.dropFirst().joined(separator: "，"))
    }

    /// 固定画布上的模板图，角标出现时不改变图标或数字的位置；随系统高亮反色。
    static func image(marked: Bool) -> NSImage {
        let eye = NSImage(systemSymbolName: "eye", accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 15, weight: .regular))
        let result = NSImage(size: NSSize(width: 22, height: 18), flipped: false) { _ in
            if let eye {
                let ratio = min(17 / eye.size.width, 13 / eye.size.height)
                let size = NSSize(width: eye.size.width * ratio, height: eye.size.height * ratio)
                eye.draw(in: NSRect(x: (18 - size.width) / 2, y: (18 - size.height) / 2,
                                    width: size.width, height: size.height))
            }
            if marked {
                NSColor.black.setFill()
                NSBezierPath(ovalIn: NSRect(x: 18, y: 12, width: 4, height: 4)).fill()
            }
            return true
        }
        result.isTemplate = true
        return result
    }

    /// 保留原生菜单的键盘导航、高亮、子菜单与任务路由。
    static func appendTools(to menu: NSMenu, tools: [ToolStatus], events: [TaskRecord] = [], target: AnyObject,
                            openTool: Selector, openConnections: Selector,
                            displayTitle: (String) -> String) {
        let groups = HarnessConversations.groups(tools: tools, events: events)

        func taskItem(_ conversation: HarnessConversation) -> NSMenuItem {
            let title = displayTitle(conversation.title)
            let item = NSMenuItem(title: "\(fittedTitle(title, maxWidth: 240)) · \(conversation.label)",
                                  action: openTool, keyEquivalent: "")
            item.target = target
            item.image = symbol(conversation.symbol, size: 10, template: true)
            item.attributedTitle = NSAttributedString(string: item.title, attributes: [
                .font: NSFont.menuFont(ofSize: 12),
            ])
            item.representedObject = conversation
            item.toolTip = title + " · " + conversation.label + "\n"
                + NotificationRouter.destinationLabel(forToolKey: conversation.toolKey, sessionId: conversation.sessionId)
                + (conversation.needsAttention ? "，并清除此会话的提醒" : "")
            if conversation.needsAttention {
                item.onStateImage = symbol("circle.fill", color: .controlAccentColor, size: 5)
                item.state = .on
            }
            return item
        }

        for (index, group) in groups.enumerated() {
            if index > 0 { menu.addItem(.separator()) }
            let tool = group.tool
            let failed = tool.health?.state == "error"
            let detail = group.statusLabel
            let header = NSMenuItem(title: "\(tool.name) · \(detail)",
                                    action: failed ? openConnections : openTool, keyEquivalent: "")
            header.target = target
            header.representedObject = tool.key
            header.image = failed ? symbol("exclamationmark.circle", color: .systemOrange) :
                symbol("circle.fill", color: tool.state == "busy" ? .systemGreen : .systemGray, size: 7)
            header.toolTip = failed ? tool.health?.message : NotificationRouter.destinationLabel(forToolKey: tool.key)
            menu.addItem(header)
            for conversation in group.preview {
                let item = taskItem(conversation)
                item.indentationLevel = 1
                menu.addItem(item)
            }
            let visibleIDs = Set(group.preview.map(\.id))
            let remaining = group.conversations.filter { !visibleIDs.contains($0.id) }
            if !remaining.isEmpty {
                let more = NSMenuItem(title: "其余 \(remaining.count) 条会话", action: nil, keyEquivalent: "")
                more.image = symbol("ellipsis", size: 11, template: true)
                more.indentationLevel = 1
                let submenu = NSMenu()
                for conversation in remaining { submenu.addItem(taskItem(conversation)) }
                more.submenu = submenu
                menu.addItem(more)
            }
        }
        if groups.isEmpty {
            let empty = NSMenuItem(title: "当前没有会话", action: nil, keyEquivalent: "")
            empty.image = symbol("moon", template: true)
            menu.addItem(empty)
        }
    }

    /// 按原生菜单的实际字体限宽，中英文混排不会把整张菜单撑得过宽。
    static func fittedTitle(_ title: String, maxWidth: CGFloat = 300) -> String {
        let line = title.components(separatedBy: .newlines).joined(separator: " ")
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.menuFont(ofSize: 0)]
        guard (line as NSString).size(withAttributes: attributes).width > maxWidth else { return line }
        var result = ""
        for character in line {
            let candidate = result + String(character)
            if ((candidate + "…") as NSString).size(withAttributes: attributes).width > maxWidth { break }
            result = candidate
        }
        return result + "…"
    }
}
