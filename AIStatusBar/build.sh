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

# 临时签名（ad-hoc）：保证文件完整性可校验，减少 Gatekeeper 报“已损坏”的概率
codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || true

echo "✅ 构建完成: $(pwd)/$APP"
lipo -info "$APP/Contents/MacOS/AIStatusBar"
