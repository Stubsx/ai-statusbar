#!/bin/bash
# <swiftbar.title>AI CLI Status</swiftbar.title>
# <swiftbar.version>3.0</swiftbar.version>
# <swiftbar.desc>显示 Codex / Kimi Code / ZCode 的运行状态（工作中/空闲/未运行）和最近任务</swiftbar.desc>
exec /usr/bin/env python3 "$(dirname "$0")/ai_status.py"
