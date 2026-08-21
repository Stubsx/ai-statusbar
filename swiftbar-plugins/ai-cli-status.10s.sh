#!/bin/bash
# <swiftbar.title>AI CLI Status</swiftbar.title>
# <swiftbar.version>4.0</swiftbar.version>
# <swiftbar.desc>显示 Codex / Kimi / Claude / Hermes / ZCode / DSH 的运行状态和最近任务</swiftbar.desc>
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
if [[ -x "$HERE/lingmou-collector" ]]; then
  exec "$HERE/lingmou-collector"
fi
exec "/Applications/灵眸.app/Contents/Resources/lingmou-collector"
