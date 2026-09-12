# 本地事件接口 v1

在「设置 → 数据 → 本地事件接口」开启订阅。灵眸 App 是唯一写入方，必须保持运行；SwiftBar 或单独运行采集器不会产生事件。默认关闭，不开放网络端口，不执行用户脚本。标题需要另外开启；演示模式会立即移除接口保留的标题。已经被外部脚本复制的内容不能撤回。

## 读取与订阅

```bash
# 一次读取当前保留的事件
"/Applications/灵眸.app/Contents/Resources/lingmou-collector" --events

# 持续订阅：默认从当前末尾开始，不回放旧事件
"/Applications/灵眸.app/Contents/Resources/lingmou-collector" --events --follow

# 从上次成功处理后保存的游标恢复
"/Applications/灵眸.app/Contents/Resources/lingmou-collector" --events --follow --after 'epoch:sequence'
```

每行输出一个 JSON 批次（JSON Lines），字段名称如下：

```json
{"schema":1,"enabled":true,"cursor":"example-epoch:12","gap":false,"events":[{"sequence":12,"id":"codex-cli|session:ended:timestamp","tool":"codex-cli","session":"sample-session","timestamp":2000000000,"phase":"ended","evidence":"explicit"}]}
```

- `schema`：主版本；只在能识别版本时处理，忽略未知附加字段。
- `cursor`：不透明的 `epoch:sequence` 字符串；处理成功后保存整个字符串。顺序号只在同一 epoch 内递增。按 `id` 去重，防止处理成功但保存游标前崩溃导致重复动作。
- `gap`：游标无效、接口重新开启、数据被重置或超过保留范围时为 true。返回仍可读取的记录；有副作用的接入应先提示人工核对，再从新游标恢复，不能声称没有漏事件。
- `events`：最多保留 500 条或 7 天，以先到者为准。首次接入/恢复采集时只建立基线，不回放原工具的历史通知；轮询间隔内开始又结束且被后续事件覆盖的回合可能无法发现。这不是完整审计日志。
- `tool`、`session`、`timestamp`：工具标识、来源会话标识、Unix 秒。`id` 是稳定事件标识，不能当作文件路径或可执行命令。
- `phase`：`ended`、`interrupted`、`waiting_input`、`waiting_permission`、`failed`、`inactive`。各工具真实支持范围见 [TOOLS.md](TOOLS.md)。`ended` 只证明本轮结束；`inactive` 只是停止活动的推断，不证明成功。
- `title`：可选。默认缺省；不能依赖该字段。

文件 `~/.ai-statusbar/events-v1.json` 使用原子替换，权限 0600，所在目录 0700。不应直接修改它。订阅器每秒读取一次，无锁、不阻塞采集。退出码：0 正常单次读取、1 文件错误或不兼容、2 缺少参数、3 接口关闭（会先输出 `enabled:false` 的空批次，follow 随即退出）。关闭会清空保留事件；重新开启生成新的 epoch。灵眸退出期间无新事件，但已开启的接口仍允许读取保留记录；用状态 JSON 的 `collected_at` 判断采集是否仍在运行。

## 快捷指令

创建 macOS 快捷指令，加入「运行 Shell 脚本」，执行上述单次 `--events` 命令；下一步「从输入获取字典」，读取 `events` 或 `enabled`。用于查看时可直接呈现结果。需要自动动作时，由你配置运行方式、保存游标和去重；不要每次对整个保留列表重复执行动作。灵眸不自动安装或启用快捷指令。

## Raycast

仓库 [examples/raycast-lingmou-events.sh](../examples/raycast-lingmou-events.sh) 是只读 Script Command，将文件加入你的 Raycast Script Directory 后可手动查看事件。不依赖 jq，不注册后台任务。

## 用户脚本

[examples/read-events.py](../examples/read-events.py) 提供游标读取示例：首次运行建立基线，后续只打印新事件，检测 gap 时停止。它不执行外部命令或发送消息。可以通过 `--reset` 明确跳到当前末尾。实际自动化必须自行定义失败重试和幂等策略；不要将标题拼接到 shell 命令中。
