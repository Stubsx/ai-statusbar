#!/bin/bash
# 发版：打 tag 并构建 DMG 安装包。
# 日常 commit 只会替换本地 /Applications/灵眸.app（见 install-local.sh）；
# 只有发版时通过本脚本才会打 DMG，避免 dist/ 累积无用安装包。
# 用法: ./scripts/release.sh <tag>   例如 ./scripts/release.sh v1.0.52
set -euo pipefail
ROOT="$(git -C "$(dirname "$0")" rev-parse --show-toplevel)"
TAG="${1:?用法: $0 <tag>，例如 v1.0.52}"

git -C "$ROOT" tag "$TAG"
"$ROOT/scripts/build-dmg.sh"
echo "✅ 发版完成: $TAG"
