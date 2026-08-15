#!/bin/bash
# 构建独立的 AIStatusBar.app（不依赖 SwiftBar / Übersicht）
# 通用二进制（arm64 + x86_64）；本地默认自签名，公开发布支持 Developer ID 签名
set -euo pipefail
cd "$(dirname "$0")"
APP="灵眸.app"  # 产物名与 release/安装版一致，避免本地出现英文 AIStatusBar.app 与授权列表名不一致

for tool in swift swiftc lipo codesign security git; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "错误：缺少 $tool。请先安装 Xcode Command Line Tools：xcode-select --install" >&2
    exit 1
  fi
done
rm -rf "$APP" .build
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" .build

# 构建共享 Swift 采集器（arm64 + x86_64），原生 App、SwiftBar 和 Übersicht 共用。
swift build --package-path .. -c release --arch arm64 --arch x86_64
cp ../.build/apple/Products/Release/lingmou-collector "$APP/Contents/Resources/"
chmod 755 "$APP/Contents/Resources/lingmou-collector"

for arch in arm64 x86_64; do
  swiftc -O -target "${arch}-apple-macosx12.0" -o ".build/AIStatusBar-${arch}" Sources/main.swift
done
lipo -create .build/AIStatusBar-arm64 .build/AIStatusBar-x86_64 -output "$APP/Contents/MacOS/AIStatusBar"
rm -rf .build

cp ../LICENSE "$APP/Contents/Resources/LICENSE.txt"
cp ../PRIVACY.md "$APP/Contents/Resources/PRIVACY.md"
cp Info.plist "$APP/Contents/"
[ -f ../icons/AppIcon.icns ] && cp ../icons/AppIcon.icns "$APP/Contents/Resources/"

# 写入真实版本号：未提交的本地构建使用下一个版本号，确保反复调试图标时
# LaunchServices/usernoted 不会因为版本号未变而继续命中旧通知缓存。
VER_COUNT=$(git -C .. rev-list --count HEAD 2>/dev/null || echo 0)
SOURCE_VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Info.plist)
SOURCE_PATCH=${SOURCE_VERSION##*.}
if [[ "$SOURCE_PATCH" =~ ^[0-9]+$ ]] && (( SOURCE_PATCH > VER_COUNT )); then
  VER_COUNT=$SOURCE_PATCH
fi
if ! git -C .. diff --quiet --ignore-submodules -- \
    || ! git -C .. diff --cached --quiet --ignore-submodules --; then
  VER_COUNT=$((VER_COUNT + 1))
fi
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString 1.0.${VER_COUNT}" \
    -c "Set :CFBundleVersion ${VER_COUNT}" "$APP/Contents/Info.plist"

VERSION="${APP_VERSION:-1.0.${VER_COUNT}}"
if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "错误：APP_VERSION 必须是 x.y.z 格式，当前为 $VERSION" >&2
  exit 1
fi
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString ${VERSION}" \
    "$APP/Contents/Info.plist"

# 固定自签名（Lingmou Local）：签名身份跨构建稳定，TCC 授权（录屏/通知）不会随重建失效；
# 证书不存在时（如换机分发）回退 ad-hoc 临时签名
SIGN_IDENTITY="${SIGN_IDENTITY:-Lingmou Local}"
if security find-identity -p codesigning | grep -Fq "$SIGN_IDENTITY"; then
  if [[ "$SIGN_IDENTITY" == "Developer ID Application:"* ]]; then
    codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" \
      "$APP/Contents/Resources/lingmou-collector"
    codesign --force --deep --options runtime --timestamp --sign "$SIGN_IDENTITY" "$APP"
  else
    codesign --force --sign "$SIGN_IDENTITY" "$APP/Contents/Resources/lingmou-collector"
    codesign --force --deep --sign "$SIGN_IDENTITY" "$APP"
  fi
else
  if [[ "$SIGN_IDENTITY" == "Developer ID Application:"* ]]; then
    echo "错误：未找到指定的 Developer ID 签名身份：$SIGN_IDENTITY" >&2
    exit 1
  fi
  echo "提示：未找到本地签名身份 '$SIGN_IDENTITY'，使用 ad-hoc 签名（不适合直接公开分发）。" >&2
  codesign --force --sign - "$APP/Contents/Resources/lingmou-collector"
  codesign --force --deep --sign - "$APP"
fi
codesign --verify --deep --strict "$APP"

echo "✅ 构建完成: $(pwd)/${APP}（版本 ${VERSION}）"
lipo -info "$APP/Contents/MacOS/AIStatusBar"
