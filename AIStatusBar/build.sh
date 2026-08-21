#!/bin/bash
# 构建独立的 AIStatusBar.app（不依赖 SwiftBar / Übersicht）
# 通用二进制（arm64 + x86_64）；本地默认自签名，公开发布支持 Developer ID 签名
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/../scripts/xcode-env.sh"
cd "$SCRIPT_DIR"
APP="灵眸.app"  # 产物名与 release/安装版一致，避免本地出现英文 AIStatusBar.app 与授权列表名不一致

for tool in swift swiftc lipo codesign security git; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "错误：缺少 $tool。请先安装 Xcode Command Line Tools：xcode-select --install" >&2
    exit 1
  fi
done
rm -rf "$APP" .build
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" .build

# 构建共享 Swift 采集器（arm64 + x86_64），原生 App、SwiftBar 和 Übersicht 共用。
swift build --package-path .. -c release --arch arm64 --arch x86_64
cp ../.build/apple/Products/Release/lingmou-collector "$APP/Contents/Resources/"
chmod 755 "$APP/Contents/Resources/lingmou-collector"

for arch in arm64 x86_64; do
  swiftc -O -target "${arch}-apple-macosx12.0" -o ".build/AIStatusBar-${arch}" Sources/*.swift
done
lipo -create .build/AIStatusBar-arm64 .build/AIStatusBar-x86_64 -output "$APP/Contents/MacOS/AIStatusBar"
rm -rf .build

cp ../LICENSE "$APP/Contents/Resources/LICENSE.txt"
cp ../PRIVACY.md "$APP/Contents/Resources/PRIVACY.md"
cp Info.plist "$APP/Contents/"
[ -f ../icons/AppIcon.icns ] && cp ../icons/AppIcon.icns "$APP/Contents/Resources/"
[ -d Resources/Pet ] && cp -R Resources/Pet "$APP/Contents/Resources/"

# 对外版本只由 SemVer tag 决定。日常 commit 沿用最近的正式版本，不再把
# commit 数拼进补丁号；APP_VERSION 仅供 CI 或发版脚本显式覆盖。
SOURCE_VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Info.plist)
VERSION="${APP_VERSION:-}"
if [[ -z "$VERSION" ]]; then
  TAG=$(git -C .. describe --tags --match 'v[0-9]*.[0-9]*.[0-9]*' --abbrev=0 HEAD 2>/dev/null || true)
  if [[ "$TAG" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    VERSION="${TAG#v}"
  else
    VERSION="$SOURCE_VERSION"
  fi
fi
if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "错误：APP_VERSION 必须是 x.y.z 格式，当前为 $VERSION" >&2
  exit 1
fi

# 内部构建号与对外版本分离。它可以随提交递增，以规避 LaunchServices 和
# usernoted 的旧缓存，但不会出现在用户看到的 x.y.z 版本号中。
SOURCE_BUILD=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" Info.plist)
BUILD_NUMBER="${APP_BUILD:-$(git -C .. rev-list --count HEAD 2>/dev/null || echo "$SOURCE_BUILD")}"
if [[ -z "${APP_BUILD:-}" ]] && [[ "$SOURCE_BUILD" =~ ^[0-9]+$ ]] \
    && (( SOURCE_BUILD > BUILD_NUMBER )); then
  BUILD_NUMBER=$SOURCE_BUILD
fi
if [[ -z "${APP_BUILD:-}" ]] \
    && { ! git -C .. diff --quiet --ignore-submodules -- \
      || ! git -C .. diff --cached --quiet --ignore-submodules --; }; then
  BUILD_NUMBER=$((BUILD_NUMBER + 1))
fi
if [[ ! "$BUILD_NUMBER" =~ ^[1-9][0-9]*$ ]]; then
  echo "错误：APP_BUILD 必须是正整数，当前为 $BUILD_NUMBER" >&2
  exit 1
fi
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString ${VERSION}" \
    -c "Set :CFBundleVersion ${BUILD_NUMBER}" \
    "$APP/Contents/Info.plist"

# 固定自签名（Lingmou Local）：签名身份跨构建稳定，TCC 授权（录屏/通知）不会随重建失效。
# 注意：TCC 授权跟随签名证书哈希。ad-hoc 或换了证书的构建会被系统当成新 app，
# 首次运行会重新请求录屏授权——本地构建、下载安装的 release 签名不同时就各自要授权一次。
SIGN_IDENTITY="${SIGN_IDENTITY:-Lingmou Local}"
if [[ "$SIGN_IDENTITY" == "Developer ID Application:"* ]]; then
  if ! security find-identity -p codesigning | grep -Fq "$SIGN_IDENTITY"; then
    echo "错误：未找到指定的 Developer ID 签名身份：$SIGN_IDENTITY" >&2
    exit 1
  fi
  codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" \
    "$APP/Contents/Resources/lingmou-collector"
  codesign --force --deep --options runtime --timestamp --sign "$SIGN_IDENTITY" "$APP"
elif ! { codesign --force --sign "$SIGN_IDENTITY" "$APP/Contents/Resources/lingmou-collector" 2>/dev/null \
      && codesign --force --deep --sign "$SIGN_IDENTITY" "$APP" 2>/dev/null; }; then
  # 先直接尝试证书签名再谈回退：受限 shell（如代理会话沙箱）里 security find-identity
  # 可能查不到身份，但 codesign 自己的身份解析仍可用；误回退 ad-hoc 会造成 TCC 身份漂移。
  echo "提示：本地签名身份 '$SIGN_IDENTITY' 不可用，使用 ad-hoc 签名（不适合直接公开分发）。" >&2
  echo "      ad-hoc 每次重建都是新身份，系统录屏/通知授权会随之失效并重新弹授权框；" >&2
  echo '      请创建同名自签名证书（证书类型选"代码签名"）后重新构建，或用' >&2
  echo '      scripts/import-signing-identity.sh 从主力构建机导入统一证书。' >&2
  codesign --force --sign - "$APP/Contents/Resources/lingmou-collector"
  codesign --force --deep --sign - "$APP"
fi
codesign --verify --deep --strict "$APP"

# 打印本次签名身份指纹，排查"更新/换构建后系统重新索要授权"时可直接对照
LEAF_HASH=$(codesign -d --requirements - "$APP" 2>/dev/null \
  | sed -nE 's/.*certificate leaf = H"([0-9A-Fa-f]+)".*/\1/p' | head -1)
if [[ -n "$LEAF_HASH" ]]; then
  echo "签名证书: ${SIGN_IDENTITY}（leaf ${LEAF_HASH:0:12}…）— 系统授权跟随此哈希"
else
  echo "签名证书: ad-hoc — 每次构建身份都不同，系统授权不会保留"
fi

echo "✅ 构建完成: $(pwd)/${APP}（版本 ${VERSION}，构建 ${BUILD_NUMBER}）"
lipo -info "$APP/Contents/MacOS/AIStatusBar"
