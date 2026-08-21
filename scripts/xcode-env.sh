#!/bin/bash
# 为仓库脚本选择可用的 Apple 开发工具链。
# 优先尊重显式 DEVELOPER_DIR；否则检查 xcode-select、系统应用目录和外置磁盘。

lingmou_xcode_is_usable() {
  local developer_dir="${1:-}"
  [[ -n "$developer_dir" && -d "$developer_dir" ]] || return 1
  DEVELOPER_DIR="$developer_dir" /usr/bin/xcrun --sdk macosx \
    --show-sdk-platform-path >/dev/null 2>&1
}

lingmou_find_developer_dir() {
  local selected=""
  local candidate=""
  local -a candidates=()

  if [[ -n "${DEVELOPER_DIR:-}" ]]; then
    candidates+=("$DEVELOPER_DIR")
  fi
  selected=$(/usr/bin/xcode-select -p 2>/dev/null || true)
  if [[ -n "$selected" ]]; then
    candidates+=("$selected")
  fi

  shopt -s nullglob
  candidates+=(
    /Applications/Xcode*.app/Contents/Developer
    /Volumes/*/Applications/Xcode*.app/Contents/Developer
    /Volumes/*/应用程序/Xcode*.app/Contents/Developer
  )
  shopt -u nullglob

  for candidate in "${candidates[@]}"; do
    if lingmou_xcode_is_usable "$candidate"; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done
  return 1
}

_lingmou_original_developer_dir="${DEVELOPER_DIR:-}"
if _lingmou_resolved_developer_dir=$(lingmou_find_developer_dir); then
  export DEVELOPER_DIR="$_lingmou_resolved_developer_dir"
  if [[ "$DEVELOPER_DIR" != "$_lingmou_original_developer_dir" ]]; then
    echo "提示：使用 Xcode 开发工具：${DEVELOPER_DIR%/Contents/Developer}" >&2
  fi
else
  echo "错误：找不到可用的 Xcode 开发工具。" >&2
  echo "请安装 Xcode/Command Line Tools，挂载包含 Xcode.app 的外置磁盘，或设置 DEVELOPER_DIR。" >&2
  return 1 2>/dev/null || exit 1
fi
unset _lingmou_original_developer_dir _lingmou_resolved_developer_dir

