#!/bin/bash
# 原生 App 会话跟踪回归：不启动采集器、不读取用户数据、不发送通知。
set -euo pipefail
TASK_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TASK_OUTPUT="$(mktemp -d "${TMPDIR:-/tmp}/lingmou-busy-tests.XXXXXX")"
trap 'rm -rf "$TASK_OUTPUT"' EXIT
"$TASK_ROOT/scripts/with-xcode.sh" swiftc \
    "$TASK_ROOT/AIStatusBar/Sources/Models.swift" \
    "$TASK_ROOT/Sources/LingmouCollectorCore/ActivityModels.swift" \
    "$TASK_ROOT/AIStatusBar/Sources/BusySessionTracker.swift" \
    "$TASK_ROOT/tests/BusySessionTrackerTests/main.swift" \
    -o "$TASK_OUTPUT/busy-session-tests"
"$TASK_OUTPUT/busy-session-tests"
