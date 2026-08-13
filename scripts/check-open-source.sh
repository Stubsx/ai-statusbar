#!/bin/bash
# 开源前的只读检查：语法、单元测试、个人路径和常见密钥模式。
set -euo pipefail
ROOT="$(git -C "$(dirname "$0")" rev-parse --show-toplevel)"
cd "$ROOT"

python3 -m py_compile swiftbar-plugins/ai_status.py
python3 -m unittest discover -s tests -v
plutil -lint AIStatusBar/Info.plist
test -s LICENSE
test -s PRIVACY.md
swiftc -typecheck -target arm64-apple-macosx12.0 AIStatusBar/Sources/main.swift
/bin/bash -n AIStatusBar/build.sh scripts/build-dmg.sh scripts/install-local.sh scripts/release.sh

if rg -n --hidden \
    -g '*.swift' -g '*.py' -g '*.sh' -g '*.jsx' -g '*.plist' -g '*.md' -g '*.yml' -g '.gitignore' \
    -g '!AGENTS.md' -g '!scripts/check-open-source.sh' -g '!AIStatusBar/AIStatusBar.app/**' -g '!dist/**' \
    '(/Users/[^/]+/|BEGIN (RSA |EC |OPENSSH )?PRIVATE KEY|AKIA[0-9A-Z]{16}|xox[baprs]-|gh[pousr]_[A-Za-z0-9_]{20,})' .; then
  echo "错误：发现个人绝对路径或疑似凭据，请核查以上结果" >&2
  exit 1
fi

git diff --check
echo "✅ 开源前检查通过"
