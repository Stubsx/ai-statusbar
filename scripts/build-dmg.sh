#!/bin/bash
# 构建 AIStatusBar.app 并打包为 DMG（发版时由 scripts/release.sh 调用，也可手动执行）
set -euo pipefail
ROOT="$(git -C "$(dirname "$0")" rev-parse --show-toplevel)"
cd "$ROOT"
source "$ROOT/scripts/xcode-env.sh"

# 先校验发布参数，避免配置错误时已经生成 DMG 或清理历史产物。
SIGN_IDENTITY="${SIGN_IDENTITY:-}"
if [[ -n "${NOTARY_PROFILE:-}" && "$SIGN_IDENTITY" != "Developer ID Application:"* ]]; then
  echo "错误：使用 NOTARY_PROFILE 公证时必须同时指定 Developer ID Application 签名身份" >&2
  exit 1
fi

"$ROOT/AIStatusBar/build.sh"

VER=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" \
    "$ROOT/AIStatusBar/灵眸.app/Contents/Info.plist")
PRODUCT_NAME="灵眸"
mkdir -p dist
# Release 附件使用 ASCII 文件名，避免托管平台把中文前缀清理成空字符串。
DMG="dist/Lingmou-${VER}.dmg"
# 清理当前版本的产物，包括历史中文名和旧英文名，避免误装旧包。
rm -f "$DMG" "dist/${PRODUCT_NAME}-${VER}.dmg" "dist/AIStatusBar-${VER}.dmg"

STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT
cp -R "AIStatusBar/灵眸.app" "$STAGE/${PRODUCT_NAME}.app"
ln -s /Applications "$STAGE/应用程序"

hdiutil create -volname "${PRODUCT_NAME}安装" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null

# Developer ID 发布可通过环境变量启用 DMG 签名和 Apple 公证：
# SIGN_IDENTITY="Developer ID Application: ..." NOTARY_PROFILE="profile" ./scripts/build-dmg.sh
if [[ "$SIGN_IDENTITY" == "Developer ID Application:"* ]]; then
  codesign --force --timestamp --sign "$SIGN_IDENTITY" "$DMG"
fi
if [[ -n "${NOTARY_PROFILE:-}" ]]; then
  xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$DMG"
fi

# 当前刚构建的 DMG 始终保留；其余历史产物只保留版本号最高的 2 个。
# 版本号格式为 x.y.z；sort -t. -k1,1n -k2,2n -k3,3n 按数字段排序，
# 跳过文件名前缀差异（Lingmou-、中文 灵眸- 与遗留英文 AIStatusBar-）。
KEEP_OLD=2
index=0
find dist -maxdepth 1 -type f \( -name 'Lingmou-*.dmg' -o -name "${PRODUCT_NAME}-*.dmg" -o -name 'AIStatusBar-*.dmg' \) \
  | sed -nE 's#(.*-([0-9]+\.[0-9]+\.[0-9]+)\.dmg)$#\2 \1#p' \
  | sort -t. -k1,1nr -k2,2nr -k3,3nr \
  | cut -d' ' -f2- \
  | while IFS= read -r f; do
      [[ "$f" == "$DMG" ]] && continue
      index=$((index + 1))
      if (( index > KEEP_OLD )) && [[ -n "$f" ]]; then
        rm -f -- "$f"
      fi
    done

if [[ ! -s "$DMG" ]]; then
  echo "错误：DMG 产物在构建后缺失：$DMG" >&2
  exit 1
fi

echo "✅ DMG 打包完成: ${ROOT}/${DMG}"
