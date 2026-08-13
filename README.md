# 灵眸

灵眸是一个 macOS 菜单栏工具，用来汇总本机 AI 编程工具的运行状态、最近任务、Token 用量和配额。目前支持 Codex App/CLI、Kimi Code、Claude Code、Hermes 和 ZCode。

> 灵眸不是上述产品的官方组件，也不隶属于 OpenAI、Moonshot AI、Anthropic 或其他工具厂商。各产品名称和商标归其权利人所有。

## 功能

- 在菜单栏和可选桌面卡片中显示工作中、空闲、未运行状态。
- 显示近期任务标题、当日 Token 用量和近十周活跃热力图。
- 查询已登录工具的配额；接口不可用时自动降级。
- 可选任务完成通知、Dock 图标和背景自适应外观。
- 缺少某个工具或本地数据格式不兼容时，不影响其他工具运行。

## 系统要求

- macOS 12 或更高版本；背景自适应截图需要 macOS 14 或更高版本。
- 安装版不需要 Python 或其他额外运行时。
- 从源码构建需要支持目标系统的 Xcode Command Line Tools；使用 macOS 26 液态玻璃源码构建时需要包含相关 SDK 的新版 Xcode。

先确认环境：

```bash
xcode-select -p
swift --version
```

## 从源码安装

```bash
git clone https://github.com/Stubsx/ai-statusbar.git
cd ai-statusbar
./AIStatusBar/build.sh
cp -R AIStatusBar/AIStatusBar.app /Applications/灵眸.app
open /Applications/灵眸.app
```

可选的 Übersicht 小组件位于 `uebersicht-widgets/ai-status.widget/`，它读取 `/Applications/灵眸.app` 中同一份采集器，因此需要先把原生 App 安装到“应用程序”目录。

可选的 SwiftBar 启动器位于 `swiftbar-plugins/ai-cli-status.10s.sh`。它优先使用同目录的 `lingmou-collector`，否则读取已安装“灵眸”中的同一份 Swift 采集器。

开发者可运行 `./scripts/install-local.sh` 构建并替换本机 `/Applications/灵眸.app`。该脚本会关闭同 Bundle ID 的现有实例，不建议用作普通用户安装器。

如果下载的是未经 Apple 公证的构建，macOS 可能阻止首次打开。请只使用你信任的源码或发布包；正式发布应优先使用 Developer ID 签名和 Apple 公证。

## 权限说明

- **通知**：仅在用户启用任务完成提醒后申请。任务标题可能出现在通知中心或锁屏上。
- **屏幕录制**：仅在用户选择“背景自适应”外观时申请，用于截取桌面卡片下方的低分辨率区域并计算明暗；截图不保存、不上传。
- **本地文件**：读取各工具保存的会话元数据、日志、数据库和登录状态，以判断任务状态和计算用量。

详细的数据范围、联网地址和本地缓存见 [PRIVACY.md](PRIVACY.md)。

## 开发与验证

```bash
swift test
swift run lingmou-collector --json
./scripts/check-open-source.sh
./AIStatusBar/build.sh
./scripts/build-dmg.sh
```

状态采集器和原生界面均使用 Swift 与 macOS 系统框架，没有第三方运行时包依赖。`LingmouCollectorCore` 提供共享采集逻辑，`lingmou-collector` 提供 JSON 和 SwiftBar 命令行输出。提交代码前请阅读 [CONTRIBUTING.md](CONTRIBUTING.md)。安全问题请按 [SECURITY.md](SECURITY.md) 报告。

## 卸载

退出灵眸后删除 `/Applications/灵眸.app`。如需同时删除设置和统计缓存，再删除 `~/.ai-statusbar/`。系统设置中的通知和屏幕录制授权可在“隐私与安全性”中撤销。

## 已知限制

- 各工具的本地数据库和非公开配额接口可能随版本变化，某项数据暂时缺失不代表账号异常。
- 任务标题来自本机工具，可能包含敏感项目名称；可以关闭通知或在系统中隐藏通知预览。

## 许可证

本项目采用 [MIT License](LICENSE)。
源码仓库和 App 发布包均附带完整许可文本。

维护者准备公开或发布新版本时，请逐项检查 [OPEN_SOURCE_CHECKLIST.md](OPEN_SOURCE_CHECKLIST.md)。
