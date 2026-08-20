import Cocoa

// 应用入口。各类型定义按职责拆分到同目录其他文件：
// Models / Stores / UIHelpers / PanelView / SettingsView / AppDelegate。

// MARK: - 入口

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)  // 无 Dock 图标，纯菜单栏 App
app.run()
