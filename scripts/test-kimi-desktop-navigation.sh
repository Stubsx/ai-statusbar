#!/bin/bash
set -euo pipefail
TASK_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TASK_OUTPUT="$(mktemp -d "${TMPDIR:-/tmp}/lingmou-kimi-navigation.XXXXXX")"
trap 'rm -rf "$TASK_OUTPUT"' EXIT
"$TASK_ROOT/scripts/with-xcode.sh" swiftc -target arm64-apple-macosx12.0 \
    "$TASK_ROOT/Sources/LingmouCollectorCore/KimiWebNavigation.swift" \
    "$TASK_ROOT/AIStatusBar/Sources/KimiDesktopNavigation.swift" \
    "$TASK_ROOT/tests/KimiDesktopNavigationTests/main.swift" -o "$TASK_OUTPUT/tests"
if [[ $# -eq 0 ]] && command -v node >/dev/null 2>&1; then
    "$TASK_OUTPUT/tests" --expression "$TASK_OUTPUT/navigation.js"
    node "$TASK_ROOT/tests/KimiDesktopNavigationTests/renderer.mjs" "$TASK_OUTPUT/navigation.js"
else
    "$TASK_OUTPUT/tests" "$@"
fi
