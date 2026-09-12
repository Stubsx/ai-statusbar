import Cocoa

/// 菜单栏只提供紧凑的状态入口与任务跳转，统计和提醒详情仍由桌面面板承载。
enum MenuBarPresentation {
    static func update(_ button: NSStatusBarButton, data: StatusData?,
                       collectorError: String?, unreadCount: Int) {
        let tools = data?.tools ?? []
        let running = tools.filter { $0.state == "busy" && $0.health?.state != "error" }
            .reduce(0) { $0 + max(0, $1.busyCount) }
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
        if unreadCount > 0 { summary.append("\(unreadCount) 条未读事件") }
        for tool in tools where tool.state != "off" || tool.health?.state == "error" {
            let state = tool.health?.state == "error" ? "读取异常" :
                (tool.state == "busy" ? "\(max(0, tool.busyCount)) 个任务运行中" : "空闲")
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
    static func appendTools(to menu: NSMenu, tools: [ToolStatus], target: AnyObject,
                            openTool: Selector, openConnections: Selector,
                            displayTitle: (String) -> String) {
        let visible = tools.filter { $0.state != "off" || $0.health?.state == "error" }
        let foreground = visible.filter { $0.state == "busy" || $0.health?.state == "error" }
        let idle = visible.filter { $0.state != "busy" && $0.health?.state != "error" }

        func taskItem(_ task: BusyItem, tool: ToolStatus) -> NSMenuItem {
            let title = displayTitle(task.title)
            let item = NSMenuItem(title: fittedTitle(title), action: openTool, keyEquivalent: "")
            item.target = target
            item.image = symbol("play", size: 10, template: true)
            item.attributedTitle = NSAttributedString(string: item.title, attributes: [
                .font: NSFont.menuFont(ofSize: 12),
            ])
            item.representedObject = ToolDestination(toolKey: tool.key, sessionId: task.id)
            item.toolTip = title + " · " + NotificationRouter.destinationLabel(forToolKey: tool.key, sessionId: task.id)
            return item
        }

        func append(_ tool: ToolStatus, to destination: NSMenu) {
            let failed = tool.health?.state == "error"
            let detail = failed ? "读取异常" :
                (tool.state == "busy" ? "\(max(0, tool.busyCount)) 个任务" : "空闲")
            let header = NSMenuItem(title: "\(tool.name) · \(detail)",
                                    action: failed ? openConnections : openTool, keyEquivalent: "")
            header.target = target
            header.representedObject = tool.key
            header.image = failed ? symbol("exclamationmark.circle", color: .systemOrange) :
                symbol("circle.fill", color: tool.state == "busy" ? .systemGreen : .systemGray, size: 7)
            header.toolTip = failed ? tool.health?.message : NotificationRouter.destinationLabel(forToolKey: tool.key)
            destination.addItem(header)
            guard !failed else { return }

            // busyItems 是限长预览，activeItems 才包含全部任务；溢出项仍可逐个跳转。
            let tasks = tool.state == "busy" ? (tool.activeItems ?? tool.busyItems) : []
            for task in tasks.prefix(3) {
                let item = taskItem(task, tool: tool)
                item.indentationLevel = 1
                destination.addItem(item)
            }
            if tasks.count > 3 {
                let more = NSMenuItem(title: "其余 \(tasks.count - 3) 个任务", action: nil, keyEquivalent: "")
                more.image = symbol("ellipsis", size: 11, template: true)
                more.indentationLevel = 1
                let submenu = NSMenu()
                for task in tasks.dropFirst(3) { submenu.addItem(taskItem(task, tool: tool)) }
                more.submenu = submenu
                destination.addItem(more)
            }
            if tool.state == "idle", let latest = tool.latestTitle {
                let title = displayTitle(latest)
                let item = NSMenuItem(title: "最近：\(fittedTitle(title, maxWidth: 270))",
                                      action: openTool, keyEquivalent: "")
                item.target = target
                item.image = symbol("clock", size: 11, template: true)
                item.representedObject = ToolDestination(toolKey: tool.key, sessionId: tool.latestSessionId)
                item.indentationLevel = 1
                item.toolTip = title + (tool.latestAge.map { " · \($0)" } ?? "")
                destination.addItem(item)
            }
        }

        for (index, tool) in foreground.enumerated() {
            if index > 0 { menu.addItem(.separator()) }
            append(tool, to: menu)
        }
        if foreground.isEmpty {
            let empty = NSMenuItem(title: visible.isEmpty ? "当前没有运行中的工具" : "当前没有运行中的任务",
                                   action: nil, keyEquivalent: "")
            empty.image = symbol("moon", template: true)
            menu.addItem(empty)
        }
        if !idle.isEmpty {
            let item = NSMenuItem(title: "空闲工具 · \(idle.count)", action: nil, keyEquivalent: "")
            item.image = symbol("pause.circle", template: true)
            let submenu = NSMenu()
            for (index, tool) in idle.enumerated() {
                if index > 0 { submenu.addItem(.separator()) }
                append(tool, to: submenu)
            }
            item.submenu = submenu
            menu.addItem(item)
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
