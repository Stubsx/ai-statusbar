#!/bin/bash
# 签名身份优先级：显式环境变量 > 本机配置 > 仓库默认自签名。
# 配置仅保存证书名称，不含私钥；按纯文本读取，绝不执行其中的内容。
if [[ -z "${SIGN_IDENTITY:-}" ]]; then
  _lingmou_signing_config="${LINGMOU_SIGNING_CONFIG:-$HOME/.ai-statusbar/signing-identity}"
  if [[ -f "$_lingmou_signing_config" ]]; then
    SIGN_IDENTITY="$(cat "$_lingmou_signing_config")"
    if [[ -z "$SIGN_IDENTITY" || "$SIGN_IDENTITY" == *$'\n'* || "$SIGN_IDENTITY" == *$'\r'* ]]; then
      echo "错误：本机签名配置必须是单行、非空的证书名称" >&2
      return 1 2>/dev/null || exit 1
    fi
  else
    SIGN_IDENTITY="Lingmou Local"
  fi
  unset _lingmou_signing_config
fi
export SIGN_IDENTITY
