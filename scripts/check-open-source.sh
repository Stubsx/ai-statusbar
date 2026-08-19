#!/bin/bash
# 开源前的只读检查：语法、单元测试、个人路径和常见密钥模式。
set -euo pipefail
ROOT="$(git -C "$(dirname "$0")" rev-parse --show-toplevel)"
cd "$ROOT"

swift test
swift run lingmou-collector --json \
  | swift -e 'import Foundation; let d=FileHandle.standardInput.readDataToEndOfFile(); guard (try? JSONSerialization.jsonObject(with:d)) != nil else { exit(1) }'
plutil -lint AIStatusBar/Info.plist
test -s LICENSE
test -s PRIVACY.md
swiftc -typecheck -target arm64-apple-macosx12.0 AIStatusBar/Sources/*.swift
/bin/bash -n AIStatusBar/build.sh scripts/build-dmg.sh scripts/install-local.sh scripts/release.sh
/bin/bash -n swiftbar-plugins/ai-cli-status.10s.sh

if rg -n --hidden \
    -g '*.swift' -g '*.sh' -g '*.jsx' -g '*.plist' -g '*.md' -g '*.yml' -g '.gitignore' \
    -g '!AGENTS.md' -g '!scripts/check-open-source.sh' -g '!AIStatusBar/灵眸.app/**' -g '!AIStatusBar/AIStatusBar.app/**' -g '!dist/**' \
    '(/Users/[^/]+/|BEGIN (RSA |EC |OPENSSH )?PRIVATE KEY|AKIA[0-9A-Z]{16}|xox[baprs]-|gh[pousr]_[A-Za-z0-9_]{20,})' .; then
  echo "错误：发现个人绝对路径或疑似凭据，请核查以上结果" >&2
  exit 1
fi

git diff --check
echo "✅ 开源前检查通过"
