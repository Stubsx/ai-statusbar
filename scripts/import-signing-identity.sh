#!/bin/bash
# 统一多台构建机的自签名身份 "Lingmou Local"。
#
# 背景：macOS 的屏幕录制/通知等授权（TCC）跟随 App 的签名证书哈希。
# 两台机器各自创建的同名证书是不同身份，本地构建与对方机器签出的 release
# 混装时系统会当成两个 App，各自重新弹授权框。统一用同一张证书即可避免。
#
# 用法（在"缺少证书"的机器上执行，p12 从主力构建机导出）：
#   ./scripts/import-signing-identity.sh /path/to/lingmou-local.p12
#
# 在主力构建机上导出 p12（二选一）：
#   GUI：钥匙串访问 → 我的证书 → Lingmou Local → 文件 → 导出项目 → .p12
#   CLI：security export -k ~/Library/Keychains/login.keychain-db \
#          -t identities -f pkcs12 -o ~/lingmou-local.p12
set -euo pipefail

P12="${1:-}"
NAME="Lingmou Local"
LOGIN_KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if [[ -z "$P12" || ! -f "$P12" ]]; then
  echo "用法: $0 /path/to/lingmou-local.p12" >&2
  exit 1
fi

# 先清掉本机同名旧证书（含私钥）：同名多张证书会让 codesign 的身份匹配产生歧义
while read -r hash; do
  echo "删除本机旧身份: ${hash:0:12}…"
  security delete-identity -Z "$hash" "$LOGIN_KEYCHAIN"
done < <(security find-identity -p codesigning 2>/dev/null \
  | awk -v n="\"${NAME}\"" 'index($0, n) {print $2}')

echo "导入证书: ${P12}"
security import "$P12" -k "$LOGIN_KEYCHAIN" -T /usr/bin/codesign

echo ""
echo "导入完成，当前签名身份："
security find-identity -p codesigning | grep -F "$NAME" || true
LEAF=$(security find-certificate -c "$NAME" -Z 2>/dev/null \
  | sed -nE 's/^SHA-1 hash: ([0-9A-F]{40}).*/\1/p' | head -1)
echo "证书指纹: ${LEAF:-未读取到}"
echo ""
echo "下一步：重新运行 ./AIStatusBar/build.sh，确认输出里的 leaf 指纹与上面一致；"
echo "之后本机构建与导出方机器签名的产物共享同一系统授权身份。"
