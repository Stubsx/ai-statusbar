# 灵眸

灵眸是一个 macOS 菜单栏工具，用来汇总本机 AI 编程工具的运行状态、最近任务、Token 用量和配额。目前支持 Codex App/CLI、Kimi Code、Kimi Work、Claude Code、Hermes 和 ZCode。

> 灵眸不是上述产品的官方组件，也不隶属于 OpenAI、Moonshot AI、Anthropic 或其他工具厂商。各产品名称和商标归其权利人所有。

## 功能

- 在菜单栏和可选桌面卡片中显示工作中、空闲、未运行状态。
- 显示近期任务标题、当日 Token 用量和近十周活跃热力图。
- 默认联网查询已登录工具的配额（可在设置中关闭）；接口不可用时自动降级。
- Kimi Code 显示 7天/5小时配额；检测到 Kimi Work 时自动显示其本月会员额度。
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
cp -R AIStatusBar/灵眸.app /Applications/灵眸.app
open /Applications/灵眸.app
```

可选的 Übersicht 小组件位于 `uebersicht-widgets/ai-status.widget/`，它读取 `/Applications/灵眸.app` 中同一份采集器，因此需要先把原生 App 安装到“应用程序”目录。

可选的 SwiftBar 启动器位于 `swiftbar-plugins/ai-cli-status.10s.sh`。它优先使用同目录的 `lingmou-collector`，否则读取已安装“灵眸”中的同一份 Swift 采集器。

开发者可运行 `./scripts/install-local.sh` 构建并替换本机 `/Applications/灵眸.app`。该脚本会关闭同 Bundle ID 的现有实例，不建议用作普通用户安装器。

如果下载的是未经 Apple 公证的构建，macOS 可能阻止首次打开。请只使用你信任的源码或发布包；正式发布应优先使用 Developer ID 签名和 Apple 公证。

## 权限说明

- **通知**：仅在用户启用任务完成提醒后申请。任务标题可能出现在通知中心或锁屏上。
- **屏幕录制**：仅在用户选择“背景自适应”外观时申请，用于截取桌面卡片下方的低分辨率区域并计算明暗；截图不保存、不上传。授权跟随 App 的签名证书：更换签名（如本地构建、不同机器签出的安装包混装）后，系统会视作新 App 重新请求一次；每个签名身份只会自动弹一次授权框，之后可随时在设置里重新触发引导。
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

本地构建默认用自签名身份 `Lingmou Local` 签名，系统授权（录屏/通知）跟随该证书跨构建保留。多台机器协作时请共用同一张证书：在主力构建机导出 `.p12`，其他机器执行 `./scripts/import-signing-identity.sh lingmou-local.p12` 导入，避免各机器各签各的导致授权反复失效。

## 版本与发布

App 的公开版本号来自最近的 `vX.Y.Z` tag，普通 commit 只更新内部构建号，不会改变用户看到的版本。正式发布由维护者在 `main` 已推送、Developer ID 和公证配置就绪后执行：

```bash
SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" \
NOTARY_PROFILE="lingmou-notary" \
./scripts/release.sh v1.0.1
```

脚本会构建 `Lingmou-1.0.1.dmg`、推送 annotated tag，并创建附带 SHA-256 校验文件的 GitHub Release。

## 卸载

退出灵眸后删除 `/Applications/灵眸.app`。如需同时删除设置和统计缓存，再删除 `~/.ai-statusbar/`。系统设置中的通知和屏幕录制授权可在“隐私与安全性”中撤销。

## 已知限制

- 各工具的本地数据库和非公开配额接口可能随版本变化，某项数据暂时缺失不代表账号异常。
- 任务标题来自本机工具，可能包含敏感项目名称；可以关闭通知或在系统中隐藏通知预览。

## 许可证

本项目采用 [MIT License](LICENSE)。
源码仓库和 App 发布包均附带完整许可文本。

维护者准备公开或发布新版本时，请逐项检查 [OPEN_SOURCE_CHECKLIST.md](OPEN_SOURCE_CHECKLIST.md)。
