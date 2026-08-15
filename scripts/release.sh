#!/bin/bash
# 发版：构建并公证 DMG、推送 tag、创建 GitHub Release。
# 日常 commit 只会替换本地 /Applications/灵眸.app（见 install-local.sh）；
# 只有发版时通过本脚本才会打 DMG，避免 dist/ 累积无用安装包。
# 用法: ./scripts/release.sh <tag>   例如 ./scripts/release.sh v1.0.1
set -euo pipefail
ROOT="$(git -C "$(dirname "$0")" rev-parse --show-toplevel)"
TAG="${1:?用法: $0 <tag>，例如 v1.0.1}"
if [[ ! "$TAG" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "错误：tag 必须是 vX.Y.Z 格式" >&2
  exit 1
fi
for tool in gh shasum; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "错误：缺少 $tool" >&2
    exit 1
  fi
done
if [[ -n "$(git -C "$ROOT" status --porcelain)" ]]; then
  echo "错误：工作区不干净，请先提交或妥善保存改动" >&2
  exit 1
fi
BRANCH=$(git -C "$ROOT" branch --show-current)
if [[ "$BRANCH" != "main" ]]; then
  echo "错误：只能从 main 分支发布，当前为 ${BRANCH:-detached HEAD}" >&2
  exit 1
fi
if [[ "${SIGN_IDENTITY:-}" != "Developer ID Application:"* || -z "${NOTARY_PROFILE:-}" ]]; then
  echo "错误：公开发布必须设置 Developer ID SIGN_IDENTITY 和 NOTARY_PROFILE" >&2
  echo "如只需本地未公证 DMG，请改用 ./scripts/build-dmg.sh" >&2
  exit 1
fi
if ! gh auth status >/dev/null 2>&1; then
  echo "错误：GitHub CLI 尚未登录，请先运行 gh auth login" >&2
  exit 1
fi

# 发布必须基于已经推送的 main。先同步远端引用，也让重试中断过的发版成为可能。
git -C "$ROOT" fetch --quiet origin main --tags
if [[ "$(git -C "$ROOT" rev-parse HEAD)" != "$(git -C "$ROOT" rev-parse origin/main)" ]]; then
  echo "错误：当前 HEAD 与 origin/main 不一致，请先推送或同步 main" >&2
  exit 1
fi
if git -C "$ROOT" rev-parse -q --verify "refs/tags/$TAG" >/dev/null; then
  TAG_COMMIT=$(git -C "$ROOT" rev-list -n 1 "$TAG")
  if [[ "$TAG_COMMIT" != "$(git -C "$ROOT" rev-parse HEAD)" ]]; then
    echo "错误：tag $TAG 已指向其他提交" >&2
    exit 1
  fi
else
  # 新版本必须严格高于最近的正式版本，避免在 v1.0.0 之后误发 v0.9.9
  # 或重复发 v1.0.0。已存在且指向 HEAD 的 tag 不走这里，以支持失败重试。
  LATEST_TAG=""
  while IFS= read -r candidate; do
    if [[ "$candidate" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
      LATEST_TAG="$candidate"
      break
    fi
  done < <(git -C "$ROOT" tag --merged origin/main --sort=-version:refname)
  if [[ -n "$LATEST_TAG" ]]; then
    IFS=. read -r new_major new_minor new_patch <<< "${TAG#v}"
    IFS=. read -r old_major old_minor old_patch <<< "${LATEST_TAG#v}"
    if (( new_major < old_major \
        || (new_major == old_major && new_minor < old_minor) \
        || (new_major == old_major && new_minor == old_minor && new_patch <= old_patch) )); then
      echo "错误：新 tag $TAG 必须高于当前版本 $LATEST_TAG" >&2
      exit 1
    fi
  fi
fi
if gh release view "$TAG" --repo "$(gh repo view --json nameWithOwner -q .nameWithOwner)" >/dev/null 2>&1; then
  echo "错误：GitHub Release $TAG 已存在" >&2
  exit 1
fi

"$ROOT/scripts/check-open-source.sh"
APP_VERSION="${TAG#v}" "$ROOT/scripts/build-dmg.sh"
DMG="$ROOT/dist/Lingmou-${TAG#v}.dmg"
(
  cd "$(dirname "$DMG")"
  shasum -a 256 "$(basename "$DMG")" > "$(basename "$DMG").sha256"
)

if ! git -C "$ROOT" rev-parse -q --verify "refs/tags/$TAG" >/dev/null; then
  git -C "$ROOT" tag -a "$TAG" -m "Release $TAG"
fi
git -C "$ROOT" push origin "refs/tags/$TAG"
REPO=$(gh repo view --json nameWithOwner -q .nameWithOwner)
gh release create "$TAG" "$DMG" "${DMG}.sha256" \
  --repo "$REPO" \
  --verify-tag \
  --generate-notes \
  --title "灵眸 $TAG"
echo "✅ GitHub Release 发布完成: $TAG"
