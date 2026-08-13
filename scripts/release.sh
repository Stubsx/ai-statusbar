#!/bin/bash
# 发版：打 tag 并构建 DMG 安装包。
# 日常 commit 只会替换本地 /Applications/灵眸.app（见 install-local.sh）；
# 只有发版时通过本脚本才会打 DMG，避免 dist/ 累积无用安装包。
# 用法: ./scripts/release.sh <tag>   例如 ./scripts/release.sh v1.0.52
set -euo pipefail
ROOT="$(git -C "$(dirname "$0")" rev-parse --show-toplevel)"
TAG="${1:?用法: $0 <tag>，例如 v1.0.52}"
if [[ ! "$TAG" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "错误：tag 必须是 vX.Y.Z 格式" >&2
  exit 1
fi
if [[ -n "$(git -C "$ROOT" status --porcelain)" ]]; then
  echo "错误：工作区不干净，请先提交或妥善保存改动" >&2
  exit 1
fi
if git -C "$ROOT" rev-parse -q --verify "refs/tags/$TAG" >/dev/null; then
  echo "错误：tag $TAG 已存在" >&2
  exit 1
fi

APP_VERSION="${TAG#v}" "$ROOT/scripts/build-dmg.sh"
git -C "$ROOT" tag -a "$TAG" -m "Release $TAG"
echo "✅ 本地发版完成: $TAG（尚未推送 tag 或创建 GitHub Release）"
