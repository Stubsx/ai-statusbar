#!/bin/bash
set -euo pipefail
TASK_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TASK_OUTPUT="$TASK_ROOT/output/experience"
TASK_APP="$TASK_OUTPUT/ExperiencePreview.app"
mkdir -p "$TASK_APP/Contents/MacOS"
cat > "$TASK_APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd"><plist version="1.0"><dict><key>CFBundleExecutable</key><string>experience-visuals</string><key>CFBundleIdentifier</key><string>io.github.stubsx.lingmou.visual-tests</string><key>CFBundleName</key><string>ExperiencePreview</string><key>CFBundlePackageType</key><string>APPL</string></dict></plist>
PLIST
mkdir -p "$TASK_APP/Contents/Resources"
cp -R "$TASK_ROOT/AIStatusBar/Resources/PetGallery" "$TASK_APP/Contents/Resources/"
TASK_SOURCES=()
for TASK_FILE in "$TASK_ROOT"/AIStatusBar/Sources/*.swift; do
    [[ "$(basename "$TASK_FILE")" == main.swift ]] || TASK_SOURCES+=("$TASK_FILE")
done
"$TASK_ROOT/scripts/with-xcode.sh" swiftc -target arm64-apple-macosx13.0 \
    "${TASK_SOURCES[@]}" \
    "$TASK_ROOT/Sources/LingmouCollectorCore/ActivityModels.swift" \
    "$TASK_ROOT/Sources/LingmouCollectorCore/EventFeed.swift" \
    "$TASK_ROOT/Sources/LingmouCollectorCore/KimiWebNavigation.swift" \
    "$TASK_ROOT/tests/ExperienceVisualTests/main.swift" -o "$TASK_APP/Contents/MacOS/experience-visuals"
"$TASK_APP/Contents/MacOS/experience-visuals" "$TASK_OUTPUT"
