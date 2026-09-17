# 公开发布检查清单

## 第一次公开前

- [ ] 确认 `LICENSE` 中的版权所有者名称符合预期。
- [ ] 确认 App 图标和截图拥有公开分发权，并记录素材来源。
- [ ] 把 Git 提交邮箱改为愿意公开的地址，推荐 GitHub noreply 邮箱。
- [ ] 在备份仓库后，清理历史中的旧 `.app` 二进制和不希望公开的提交邮箱。
- [ ] 审查历史清理后的完整仓库，而不只是当前文件。
- [ ] 在 GitHub 启用 Private vulnerability reporting。
- [ ] 确认 README 中的系统要求和安装步骤在一台干净 Mac 上实测通过。
- [ ] 将仓库改为公开前，再运行一次 `./scripts/check-open-source.sh`。

## 每次发布

- [ ] 工作区干净，CI 全部通过。
- [ ] 使用符合 `vX.Y.Z` 的新版本号。
- [ ] 按 [版本发布规范](docs/RELEASING.md) 提交 `docs/releases/<tag>.md`，只说明相对上一个正式版本的具体更新；不可复制完整功能介绍或仅保留比较链接。
- [ ] 使用稳定的 `Lingmou Local` 身份签名；若选择 Developer ID 分发，则签名 App 和 DMG。
- [ ] 若配置 Apple 公证，使用 notarytool 公证并 stapler 装订；说明中不得宣称未执行的公证。
- [ ] 在另一台未安装 Python 的 Mac 上验证首次打开、状态刷新、通知和录屏权限。
- [ ] 检查 DMG 中不包含日志、数据库、设置、证书或其他本地文件。
- [ ] 创建 GitHub Release，附校验和与变更说明。
- [ ] 发布后回读正文，确认与已提交的说明一致；核对 tag、安装包版本、DMG 与 SHA-256 附件。

示例发布命令：

```bash
./scripts/release.sh v1.3.2
```

脚本会检查版本说明已提交且非空、`main` 已推送到远端，构建 DMG，创建并推送 annotated tag，
最后通过 `--notes-file` 创建带更新正文和 SHA-256 校验文件的 GitHub Release。设置 Developer ID 的
`SIGN_IDENTITY` 与 `NOTARY_PROFILE` 后才会公证 DMG。失败后可用同一 tag 重试；已发布的
Release 不会被覆盖。
