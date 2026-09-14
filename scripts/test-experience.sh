#!/bin/bash
set -euo pipefail
TASK_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TASK_OUTPUT="$(mktemp -d "${TMPDIR:-/tmp}/lingmou-experience-tests.XXXXXX")"
trap 'rm -rf "$TASK_OUTPUT"' EXIT
"$TASK_ROOT/scripts/with-xcode.sh" swiftc \
    "$TASK_ROOT/Sources/LingmouCollectorCore/ActivityModels.swift" \
    "$TASK_ROOT/AIStatusBar/Sources/Models.swift" \
    "$TASK_ROOT/AIStatusBar/Sources/BusySessionTracker.swift" \
    "$TASK_ROOT/AIStatusBar/Sources/EventJournal.swift" \
    "$TASK_ROOT/AIStatusBar/Sources/HarnessConversations.swift" \
    "$TASK_ROOT/AIStatusBar/Sources/QuotaPresentation.swift" \
    "$TASK_ROOT/AIStatusBar/Sources/ExperiencePreferences.swift" \
    "$TASK_ROOT/tests/ExperienceTests/main.swift" -o "$TASK_OUTPUT/tests"
"$TASK_OUTPUT/tests"
