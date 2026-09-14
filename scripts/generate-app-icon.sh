#!/bin/bash
# 从晴蓝绘制代码生成静态 App 图标，所有尺寸均来自同一张 1024px 源图。
set -euo pipefail
TASK_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TASK_OUTPUT="$TASK_ROOT/output/app-icon"
mkdir -p "$TASK_OUTPUT"
"$TASK_ROOT/scripts/with-xcode.sh" swiftc -O \
    "$TASK_ROOT/AIStatusBar/Sources/BallInkDrawing.swift" \
    "$TASK_ROOT/scripts/render-app-icon.swift" \
    -o "$TASK_OUTPUT/render-app-icon"
"$TASK_OUTPUT/render-app-icon" "$TASK_OUTPUT"
iconutil -c icns "$TASK_OUTPUT/AppIcon.iconset" -o "$TASK_OUTPUT/AppIcon.icns"
cp "$TASK_OUTPUT/AppIcon-1024.png" "$TASK_ROOT/icons/AppIcon-1024.png"
cp "$TASK_OUTPUT/AppIcon.icns" "$TASK_ROOT/icons/AppIcon.icns"
cp "$TASK_OUTPUT/AppIcon.iconset/"*.png "$TASK_ROOT/icons/AppIcon.iconset/"
echo "App icon assets updated; preview: $TASK_OUTPUT/preview.png"
