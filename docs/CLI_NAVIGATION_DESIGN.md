# CLI 会话定位与恢复方案

日期：2026-09-12。状态：Claude / Kimi 的会话位置方案尚未实施。设计基线为构建 120；构建 121 已贯通任务/事件的会话 ID，并为 Codex App 单独接入官方本地对话深链，详见 TOOLS.md。

## 结论

以「会话当前所在的位置」决定跳转。CLI 的启动父进程只能用来推断宿主，不能代表用户当前操作的界面。保持灵眸的轻量定位：正常点击直接返回原位置，存在多个有效位置时才显示短列表；增强连接放在现有「连接与诊断」中。

## 构建 120 的实现与缺口

`Navigation.swift` 只接收工具 key，扫描进程并沿父进程查找 GUI 应用。一个宿主直接激活，多个宿主显示选择。任务事件虽然保存了 `sessionId`，但 `Stores.openEvent` 只把 `toolKey` 交给路由；任务行也没有携带会话定位信息。

因此 Claude Code / Kimi CLI 在 iTerm 与 VS Code 中都只能打开宿主应用。同一宿主下无法区分窗口、标签或分屏；历史会话的原进程退出后也无法定位。CLI 包装进程还可能重复计数。

本机调查发现一个实际运行的 Kimi Web 实例：实例登记有 PID、端口、服务 ID 和心跳，健康检查返回 200；其父进程链最终指向 iTerm，`ps` 中的进程标题是 `kimi-cod`。当前严格名称匹配会漏掉它，简单改成前缀匹配又可能引入误报。应使用实例登记及真实可执行文件路径作为证据。此时直接激活 iTerm 会显示服务终端，而不是用户工作的 Web 会话。

2026-09-13 更新：已补齐上述 Web 运行状态漏报。采集器以实例心跳、PID、内核提供的可执行文件路径及启动时间验证服务，再由会话主／子代理 wire 日志判断忙碌；同时兼容新会话的 `cwd` 字段。会话位置登记和 Web 跳转仍未实施，下文保留其设计。

## 不同启动途径的处理

| 使用方式 | 如何找到原位置 | 点击行为 | 原位置不存在时 |
| --- | --- | --- | --- |
| Claude / Kimi 在 iTerm 内运行 | 会话 ID → CLI 进程及启动时间 → TTY / iTerm session ID | 选择原窗口、标签和分屏，再激活 iTerm | 明确显示原终端已关闭，提供恢复历史会话 |
| Claude / Kimi 在 VS Code 集成终端运行 | 会话 ID → shell 进程 → 扩展登记的终端对象和窗口实例 | 配套扩展选择终端并使所属窗口获得焦点 | 打开已知工作区；精确定位不可用时清楚标注 |
| Kimi Web 中启动或恢复历史会话 | 会话 ID + 当前承载它的 server ID / origin | 打开该服务的 `/sessions/{id}` | 服务离线则显示离线；由用户选择启动服务或改用 CLI 恢复 |
| 从 Web 真正切换到外部终端运行 | 新的 CLI 生命周期登记覆盖当前运行位置 | 返回新终端里的会话 | 保留 Web 作为可选查看入口 |
| tmux、SSH、容器或远程 VS Code | 需要额外的远程/复用器适配及设备标识 | 第一阶段只提供已验证的宿主或恢复入口 | 不把远程 PID、TTY 当成本机对象 |

Kimi Web 页面中打开历史记录，可能只是由同一个服务进程加载该会话，并不一定产生一个独立 CLI 进程。判断依据应是当前承载关系，而不是会话创建于哪里，也不是进程数量。

## 共享定位信息

建议新增本机 `SessionLocationStore`，把会话的业务身份与运行位置分开。

- 业务身份：`toolKey`、数据根目录标识、`sessionId`。
- 运行身份：本次运行标识、PID 与进程启动时间、宿主应用标识、位置类型。
- 终端位置：shell PID、TTY、iTerm session ID 或 VS Code 窗口实例/终端标识。
- Web 位置：server ID、经过验证的实际 origin；浏览器增强连接可另外保存浏览器配置与标签身份。
- 有效性：登记来源、最后确认时间、会话结束/终端关闭状态；多个有效位置允许并存。

路由改为接受 `toolKey + sessionId + 可选运行位置引用`。事件点击使用事件对应的运行位置，避免历史事件误跳到同名工具的另一个任务；工具名称点击没有具体会话时，才使用最近明确交互的位置或展示候选项。不能用日志最后修改时间推断用户当前选中的窗口。

构建 121 已补充可选的 `latestSessionId` 并由 Codex 采集器填充；其他工具仍需补充。共享 JSON 只追加可选字段，兼容旧 SwiftBar / Übersicht；具体机器的 PID、TTY、绝对路径和认证信息不进入用量同步与默认事件导出。

位置记录按终端关闭和进程退出及时失效。恢复选择需复核 PID 启动时间与终端身份，防止系统复用 PID/TTY 后跳到别的窗口。同一历史会话在两个终端同时打开时保留两个位置，无法确认事件来自哪个位置就显示选择。

## 位置登记与宿主适配

### Claude Code / Kimi 的生命周期登记

优先用官方 hooks 在会话启动、恢复和结束时登记会话 ID 与工作目录；通过 hook 的进程祖先定位实际 CLI 进程，仅读取需要的终端标识。Kimi 文档明确有 `SessionStart`（startup/resume）、`SessionEnd`、`SessionHeartbeat`，输入含 `session_id`、`cwd`、`client_type`。Claude 官方插件开发示例也包含 `session_id`、`transcript_path`、`cwd` 及启动/结束事件。

Hook 只写少量本机定位元数据并立即退出，不输出上下文、不触发采集或网络请求，不干预主任务。保留用户已有 hook 配置，增强连接可关闭和卸载。历史上已启动、尚未接入登记的会话继续使用宿主兜底；首次注册不能伪造原位置。恢复/切换会话时更新绑定，不能只在 shell 启动一次时登记。

`client_type` 不能独立证明终端或 Web 归属，需要联合服务实例、CLI 进程和宿主登记判断；多个会话由一个 Web 服务承载时不能把一个 PID 当成一个会话。

### iTerm：原生选择具体 session

本机 iTerm 脚本字典公开了 `session.tty`、session ID 和 `select` 动作，可按 CLI 的 TTY 匹配 session，再选择对应分屏/标签/窗口。优先考虑原生 Apple Events，避免附带 Python 环境；iTerm Python API 可作为已有环境的替代适配。

精确控制属于增强连接，可能需要 macOS 自动化授权或 iTerm API 授权；未连接时继续提供「打开 iTerm」。这与已有的无额外授权应用激活能力分开。连接测试只选择已有测试终端，不向终端输入命令。

### VS Code：小型配套扩展

扩展通过公开的 `window.terminals`、`Terminal.processId` 和终端开关事件登记本窗口的终端；定位后调用 `Terminal.show(false)`。各窗口有独立本地连接，灵眸把请求发给持有该终端对象的扩展实例，再执行受支持的窗口聚焦命令。

普通 `vscode://` 的 `registerUriHandler` 默认由最前面的窗口处理，不能单独保证多窗口定位。VS Code 源码存在 `workbench.action.focusWindow`；实现时需对安装版本探测，并实际验证多窗口聚焦。扩展返回处理结果，灵眸不能把「请求发出」视为已定位。

桥接只接受已登记终端的定位请求，不提供任意命令执行。没有扩展时的 `code --reuse-window <目录>` 只能算工作区兜底，不能声称定位了原终端，也不能保证选择正确的已有窗口。

### Kimi Web：实例登记 + 会话深链

本机安装的 Kimi 0.41.0 和实际 Web 静态资源确认支持 `/sessions/{sessionId}`。官方 `webSessionUrl` 使用相同路径；多个服务默认从 58627 开始递增端口，并在 `~/.kimi-code/server/instances/` 登记。应动态读取健康的实例，不能写死端口。

服务实例的 PID、启动时间、心跳及只读健康检查共同用于验证存活。会话归属优先使用生命周期登记；需要补充时使用该版本公开的 API。多个实例共享历史目录，所以「该服务能列出这个历史会话」不能证明它是原来的承载服务。

基础版可直接打开会话 URL；浏览器已登录时复用其认证。复用原标签和原浏览器配置需要专用浏览器连接，单纯系统 `open URL` 可能新开标签，必须分别标明能力。增强连接只对已登记的本机 Kimi 页面按 origin + 会话 ID 匹配；同一会话有多个可见位置时遵循用户最后选择或列出候选。

访问 token 不进入普通位置文件、日志和分享链接。无有效浏览器认证时走正常登录/连接流程，不轮换 token 或绕过认证。Kimi API 标注为实验性，版本不兼容时退回可验证的页面入口。

## 原进程退出后的历史恢复

「回到原窗口」和「重新启动历史会话」应为不同动作。前者不发送提示词、不启动模型任务、不新建终端。原进程已退出时，提供明确的恢复按钮：

- Claude Code：在原工作目录运行 `claude --resume <sessionId>`。
- Kimi：在原工作目录运行 `kimi --session <sessionId>`。

两个参数均由本机 CLI 帮助确认。恢复时保留原权限模式的正常机制，不添加自动执行或跳过确认参数。使用参数数组和可靠路径处理；需要终端执行时在新建的专用终端中运行，不能把命令塞进一个可能正在运行任务的现有终端。

已关闭的历史会话不可仅因用户点击一条通知就自动在另一个服务/终端里重新运行。界面明确显示「原终端已关闭 · 恢复会话」，让点击语义与实际行为一致。

## 建议实施顺序与验收

1. 先贯通会话 ID、位置模型与有效性判断；修正 Kimi Web 的进程识别和错误宿主归属。无需扩大主面板。
2. 实现 Kimi Web 会话 URL 与 iTerm 终端选择，接入可选 hooks，完成历史恢复按钮。
3. 补充 VS Code 配套扩展，最后按需求增加浏览器标签复用和 tmux/远程适配。

核心验收：同一项目里两个 Claude 会话；iTerm 两标签与分屏；两个 VS Code 窗口；Kimi 在 TUI 内切换历史；Kimi Web 从历史加载会话；两个不同端口的 Web 服务；Web 转外部 CLI；进程退出、PID/TTY 复用、原工作目录失效；hooks/扩展关闭。点击必须指向对应会话，不能重复创建会话或向已有终端发送意外输入。

精确定位只在接口明确响应且目标位置通过验证时记录成功；未接入宿主、多个候选或位置过期都应明确降级。此次仅完成现有代码、本机元数据/健康检查、官方文档及源码核验，未安装 hooks、扩展或执行历史恢复测试。

## 依据

- 仓库：`AIStatusBar/Sources/Navigation.swift`、`Stores.swift`、`PanelView.swift` 和 `Sources/LingmouCollectorCore/LocalCollectors.swift`。
- [Kimi 浏览器模式](https://moonshotai.github.io/kimi-code/en/guides/web)、[Hooks](https://moonshotai.github.io/kimi-code/en/customization/hooks)、[Server API](https://moonshotai.github.io/kimi-code/en/reference/server-api)。
- [Kimi 会话 URL 源码](https://github.com/MoonshotAI/kimi-code/blob/main/apps/kimi-code/src/tui/commands/web.ts)、[服务实例登记](https://github.com/MoonshotAI/kimi-code/blob/main/packages/kap-server/src/instanceRegistry.ts)。
- [VS Code Terminal API](https://code.visualstudio.com/api/references/vscode-api#Terminal)、[URI Handler](https://code.visualstudio.com/api/references/vscode-api#window.registerUriHandler)、[窗口聚焦命令实现](https://github.com/microsoft/vscode/blob/main/src/vs/workbench/electron-browser/actions/windowActions.ts)。
- [Claude 官方 Hook 测试示例](https://github.com/anthropics/claude-code/blob/main/plugins/plugin-dev/skills/hook-development/scripts/test-hook.sh)。Claude 文档站本次访问受限，未据此宣称完成所有版本兼容性验证。
- 本机 iTerm `iTerm2.sdef` 脚本字典，以及 `kimi --help`、`kimi web --help`、`claude --help` 的实际输出。
