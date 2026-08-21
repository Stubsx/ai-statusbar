# 参与贡献

感谢你帮助改进灵眸。

## 开始之前

- 不要提交真实会话日志、数据库、访问令牌、账号信息或个人绝对路径。
- 测试数据必须匿名化，并尽量缩减为只覆盖目标行为的最小样本。
- 修改 JSON 字段时同步检查 Swift 核心、原生 App 和 Übersicht 前端。
- 对厂商接口或本地格式的兼容改动，请说明验证过的工具版本。

## 本地检查

```bash
./scripts/with-xcode.sh swift test
./scripts/with-xcode.sh swift run lingmou-collector --json
./scripts/check-open-source.sh
./AIStatusBar/build.sh
```

界面改动还应检查菜单栏、桌面卡片、设置窗口和通知。不要提交 `灵眸.app` 或 `dist/` 下的构建产物。

## 提交与 Pull Request

提交主题保持简短并说明行为变化。Pull Request 请写明：

- 修改原因和用户可见影响；
- 验证命令和测试环境；
- 受影响的工具或前端；
- 涉及界面时附不含敏感信息的前后截图。
