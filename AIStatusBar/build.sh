#!/bin/bash
# 构建独立的 AIStatusBar.app（不依赖 SwiftBar / Übersicht）
# 通用二进制（arm64 + x86_64）+ 临时签名，便于分发
set -e
cd "$(dirname "$0")"
APP="AIStatusBar.app"
rm -rf "$APP" .build
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" .build

for arch in arm64 x86_64; do
  swiftc -O -target ${arch}-apple-macosx12.0 -o ".build/AIStatusBar-${arch}" Sources/main.swift
done
lipo -create .build/AIStatusBar-arm64 .build/AIStatusBar-x86_64 -output "$APP/Contents/MacOS/AIStatusBar"
rm -rf .build

cp ../swiftbar-plugins/ai_status.py "$APP/Contents/Resources/"
cp Info.plist "$APP/Contents/"
[ -f ../icons/AppIcon.icns ] && cp ../icons/AppIcon.icns "$APP/Contents/Resources/"

# 写入真实版本号（与 DMG 命名一致）：CFBundleVersion 恒为 1 会让
# LaunchServices/usernoted 永远命中旧缓存，通知里的名称和图标不更新
VER_COUNT=$(git -C .. rev-list --count HEAD 2>/dev/null || echo 0)
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString 1.0.${VER_COUNT}" \
    -c "Set :CFBundleVersion ${VER_COUNT}" "$APP/Contents/Info.plist"

# 固定自签名（Lingmou Local）：签名身份跨构建稳定，TCC 授权（录屏/通知）不会随重建失效；
# 证书不存在时（如换机分发）回退 ad-hoc 临时签名
SIGN_IDENTITY="Lingmou Local"
if security find-identity -p codesigning | grep -q "$SIGN_IDENTITY"; then
  codesign --force --deep --sign "$SIGN_IDENTITY" "$APP" >/dev/null 2>&1 || true
else
  codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || true
fi

echo "✅ 构建完成: $(pwd)/$APP"
lipo -info "$APP/Contents/MacOS/AIStatusBar"

# 重新注册 LaunchServices，刷新缓存的应用名称/图标（否则通知仍显示旧值）
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
[ -x "$LSREGISTER" ] && "$LSREGISTER" -f "$APP" || true
