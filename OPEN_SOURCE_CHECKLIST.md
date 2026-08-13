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
- [ ] 用 Developer ID Application 身份签名 App 和 DMG。
- [ ] 使用 Apple notarytool 公证并 stapler 装订。
- [ ] 在另一台未安装 Python 的 Mac 上验证首次打开、状态刷新、通知和录屏权限。
- [ ] 检查 DMG 中不包含日志、数据库、设置、证书或其他本地文件。
- [ ] 创建 GitHub Release，附校验和与变更说明。

示例发布命令：

```bash
SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" \
NOTARY_PROFILE="lingmou-notary" \
./scripts/release.sh v1.0.0
```

脚本只在本地构建并创建 tag，不会自动推送或公开仓库。
