#!/bin/bash
# 构建 AIStatusBar.app 并打包为 DMG（由 post-commit hook 调用，也可手动执行）
set -e
ROOT="$(git -C "$(dirname "$0")" rev-parse --show-toplevel)"
cd "$ROOT"

"$ROOT/AIStatusBar/build.sh"

VER="1.0.$(git rev-list --count HEAD)"
mkdir -p dist
DMG="dist/AIStatusBar-${VER}.dmg"
rm -f "$DMG"

STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT
cp -R "AIStatusBar/AIStatusBar.app" "$STAGE/"
ln -s /Applications "$STAGE/Applications"

hdiutil create -volname "AIStatusBar" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
echo "✅ DMG 打包完成: $ROOT/$DMG"
