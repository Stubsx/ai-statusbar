# 工具适配贡献指南

灵眸当前通过源码接入工具，不扫描或执行第三方插件。基础数据由 `Sources/LingmouCollectorCore` 生成，原生 App、SwiftBar、Übersicht 共用。任何来源数据都只能用于解析，不能当成指令执行。

## 最小接入

实现公开的 `ToolAdapter` 协议：固定 `key`、`letter`、`name` 和 `ToolCapabilities`，在 `collect(environment:settings:)` 中返回 `ToolStatus`，读取失败抛出错误。调用方使用 `LingmouCollector(adapters: [MyAdapter()])` 注册。内置工具和重复标识不会被覆盖。`AdapterContract.collect` 单独捕获每个适配器的错误，返回脱敏的 error 健康信息，其他工具继续采集。

参考实现 `JSONFileToolAdapter` 读取最多 2 MB 的本机 JSON，不启用联网和动态执行；正式 CLI 默认不注册示例。`examples/adapter-snapshot.json` 是完全虚构的样例。参考测试见 `tests/LingmouCollectorCoreTests/EcosystemTests.swift`，可直接运行：

```bash
./scripts/with-xcode.sh swift test --filter EcosystemTests
```

## 数据契约

| 字段 | 约束 |
| --- | --- |
| key | 固定小写 ASCII 字母、数字、连字符，最长 64 字符；不得包含账号/设备信息 |
| state | busy / idle / off；采集错误另用 health.state=error 表达 |
| busy_count / busy_items | 完整数量 + 最多 5 条预览；保留兼容性 |
| active_items | 完整活动列表，ID 唯一且非空；数量等于 busy_count |
| activities | 会话的当前信号；id 来自会话 + 来源事件时间/轮次 + phase，反复采集不改变 |
| evidence | 明确信号 explicit；仅 inactive 可以是 inferred |
| capabilities | 如实声明 event_phases、usage、quota、navigation，未知能力视为不支持 |
| health | state/message/checked_at；source_updated_at 用源数据时间；quota_state 区分支持、登录、关闭、过期和失败 |
| collected_at | 整份状态的采集 Unix 秒；updated_at 保留原显示字段 |

`TaskActivity`、`ToolCapabilities`、`ToolHealth` 的共享 Swift 定义同时编译进原生 App。JSON 采集契约用 snake_case，旧字段不改名，新增元数据均为可选。历史缓存缺少新字段时前端保守回退。当前订阅接口单独使用 [LOCAL_EVENTS.md](LOCAL_EVENTS.md) 的 v1 字段，不应把两个协议混用。

仅当来源明确结束才产生 ended，不判断业务是否成功。中断用 interrupted。未返回的一般工具调用、长时间无输出、进程退出、文件不可读都不能证明等待权限、成功完成或任务失败。等待输入需要明确调用类型及对应未返回状态；一旦来源恢复执行，撤销等待信号。没有明确事件的工具仍能提供活动和用量，event_phases 留空。

## 集成清单

1. 新增只读 collector 和虚构 fixture；所有路径从 `CollectorEnvironment` 解析，时钟可注入。
2. 在 CLI 的 collector 初始化处注册适配器。状态列表自动展示；原生设置中的开关、菜单栏图标映射和 `Navigation.swift` 需要按新工具补充。未知工具默认不能自动跳转，也不能假称精确会话跳转。
3. 用量经现有 `UsageCollector` 聚合，保持输入/输出/缓存口径；配额接入 `QuotaCollector` 并明确厂商域名、凭据边界与缓存时效。最小适配器可以声明 usage=false、quota=false。
4. 契约测试覆盖正常、缺失、空文件、错误版本、重复 ID、截断快照、结束/中断/等待/恢复和进程退出。一个适配器失败不能令其他适配器丢失。
5. 更新工具支持矩阵、隐私说明、SwiftBar/Übersicht 兼容测试；运行 `./scripts/check-open-source.sh` 并构建 App。

源码适配器不是沙箱：不得加入无限循环、无期限网络请求、UI 权限申请或任意命令执行；任何进程查询必须有上限。动态二进制插件安装、远程插件市场和任意执行权限不属于当前接口。
