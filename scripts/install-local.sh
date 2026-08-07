#!/bin/bash
# 构建 AIStatusBar，替换本地安装的 /Applications/灵眸.app，并重启运行实例。
# post-commit hook 后台调用；也可手动执行：./scripts/install-local.sh
set -euo pipefail
ROOT="$(git -C "$(dirname "$0")" rev-parse --show-toplevel)"
APP_NAME="灵眸"
BUNDLE_ID="com.jabber1.aistatusbar"
SRC_APP="$ROOT/AIStatusBar/AIStatusBar.app"
INSTALLED_APP="/Applications/${APP_NAME}.app"

# 1) 构建。失败则 set -e 直接退出 —— 绝不动正在运行的可用版本
"$ROOT/AIStatusBar/build.sh" >/dev/null

# 2) 退出运行实例（osascript 优先，给 app 清理/保存的机会；失败回退 pkill）
osascript -e 'quit app id "'"${BUNDLE_ID}"'"' 2>/dev/null \
  || pkill -x AIStatusBar 2>/dev/null \
  || pkill -f "${INSTALLED_APP}" 2>/dev/null || true
# 等待进程退出，最多约 3 秒
for _ in $(seq 1 10); do
  pgrep -f "${INSTALLED_APP}" >/dev/null || break
  sleep 0.3
done

# 3) 替换安装版（先删后拷，保留 build.sh 写入的签名 / 权限）
rm -rf "${INSTALLED_APP}"
cp -R "$SRC_APP" "${INSTALLED_APP}"

# 4) 启动新版本（同 bundle id + 同 Lingmou Local 签名身份 → TCC 授权延续）
open "${INSTALLED_APP}"
echo "✅ 已安装并启动: ${INSTALLED_APP}"
