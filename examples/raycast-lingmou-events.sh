#!/bin/bash
# @raycast.schemaVersion 1
# @raycast.title 灵眸最近事件
# @raycast.mode fullOutput
# @raycast.packageName 灵眸
# @raycast.description 只读查看本机任务事件，需要先在灵眸设置开启接口
set -euo pipefail
exec "/Applications/灵眸.app/Contents/Resources/lingmou-collector" --events
