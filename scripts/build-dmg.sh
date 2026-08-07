#!/bin/bash
# 构建 AIStatusBar.app 并打包为 DMG（发版时由 scripts/release.sh 调用，也可手动执行）
set -e
ROOT="$(git -C "$(dirname "$0")" rev-parse --show-toplevel)"
cd "$ROOT"

"$ROOT/AIStatusBar/build.sh"

VER=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" \
    "$ROOT/AIStatusBar/AIStatusBar.app/Contents/Info.plist")
PRODUCT_NAME="灵眸"
mkdir -p dist
DMG="dist/${PRODUCT_NAME}-${VER}.dmg"
# 清理当前版本的产物，包括改用中文命名前遗留的英文 DMG，避免误装旧包。
rm -f "$DMG" "dist/AIStatusBar-${VER}.dmg"

STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT
cp -R "AIStatusBar/AIStatusBar.app" "$STAGE/${PRODUCT_NAME}.app"
ln -s /Applications "$STAGE/应用程序"

hdiutil create -volname "${PRODUCT_NAME}安装" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null

# 只保留最近 3 个 DMG（按版本号倒序），删除其余历史产物。
# 版本号格式为 x.y.z；sort -t. -k1,1n -k2,2n -k3,3n 按数字段排序，
# 跳过文件名前缀差异（中文 灵眸- 与遗留英文 AIStatusBar-）。
KEEP=3
mapfile -t DMG_LIST < <(ls -1 dist/*.dmg 2>/dev/null \
  | sed -E 's#.*/[^-]+-([0-9]+\.[0-9]+\.[0-9]+)\.dmg$#\1 &#' \
  | sort -t. -k1,1n -k2,2n -k3,3nr \
  | cut -d' ' -f2-)
if (( ${#DMG_LIST[@]} > KEEP )); then
  printf '%s\n' "${DMG_LIST[@]:KEEP}" | while IFS= read -r f; do
    [ -n "$f" ] && rm -f "$f"
  done
fi

echo "✅ DMG 打包完成: $ROOT/$DMG"
