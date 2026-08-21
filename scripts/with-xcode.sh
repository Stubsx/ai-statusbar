#!/bin/bash
# 在自动发现的 Xcode 环境中执行任意开发命令。
set -euo pipefail
ROOT="$(git -C "$(dirname "$0")" rev-parse --show-toplevel)"
source "$ROOT/scripts/xcode-env.sh"

if (( $# == 0 )); then
  echo "用法：$0 <命令> [参数...]" >&2
  echo "示例：$0 swift test" >&2
  exit 2
fi
exec "$@"

