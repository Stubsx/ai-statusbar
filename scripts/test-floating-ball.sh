#!/bin/bash
set -euo pipefail
TASK_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TASK_OUTPUT="$TASK_ROOT/output/floating-ball"
mkdir -p "$TASK_OUTPUT"
"$TASK_ROOT/scripts/with-xcode.sh" swiftc -target arm64-apple-macosx13.0 \
    "$TASK_ROOT/AIStatusBar/Sources/BallView.swift" \
    "$TASK_ROOT/AIStatusBar/Sources/BallGazeTracking.swift" \
    "$TASK_ROOT/AIStatusBar/Sources/BallInkDrawing.swift" \
    "$TASK_ROOT/AIStatusBar/Sources/BallInkFlow.swift" \
    "$TASK_ROOT/AIStatusBar/Sources/StatusBubble.swift" \
    "$TASK_ROOT/tests/FloatingBallVisualTests/PlaybackChecks.swift" \
    "$TASK_ROOT/tests/FloatingBallVisualTests/main.swift" \
    -o "$TASK_OUTPUT/floating-ball-tests"
"$TASK_OUTPUT/floating-ball-tests" "$TASK_OUTPUT"
"$TASK_OUTPUT/floating-ball-tests" "$TASK_OUTPUT" --playback
