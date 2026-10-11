#!/usr/bin/env bash
#
# 从上游仓库拉取指定（或最新）release，打包成可直接刷入 KernelSU / APatch 的模块 ZIP。
#
# 用法:
#   ./build.sh [tag] [out_dir]
#
#   tag      上游 release tag，省略或传 "latest" 时自动解析最新 release
#   out_dir  产物输出目录（默认 out）
#
# 可用环境变量:
#   UPSTREAM_REPO  上游仓库（默认 inforcqb/susfs4ksu-lkm）
#   AUTHOR         写入 module.prop 的作者（默认 github-actions）
#   GITHUB_TOKEN / GH_TOKEN  可选；设置后走认证请求，避免 API 限流
#
set -euo pipefail

UPSTREAM_REPO="${UPSTREAM_REPO:-inforcqb/susfs4ksu-lkm}"
AUTHOR="${AUTHOR:-github-actions}"
TAG="${1:-latest}"
OUT_DIR="${2:-out}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEMPLATE_DIR="$SCRIPT_DIR/template"

TOKEN="${GITHUB_TOKEN:-${GH_TOKEN:-}}"

api() {
  local url="$1"
  if [ -n "$TOKEN" ]; then
    curl -fsSL \
      -H "Authorization: Bearer $TOKEN" \
      -H "Accept: application/vnd.github+json" \
      "$url"
  else
    curl -fsSL -H "Accept: application/vnd.github+json" "$url"
  fi
}

echo "==> 上游仓库: $UPSTREAM_REPO"

# 1) 解析 tag
if [ -z "$TAG" ] || [ "$TAG" = "latest" ]; then
  TAG="$(api "https://api.github.com/repos/$UPSTREAM_REPO/releases/latest" | jq -r '.tag_name')"
  [ -n "$TAG" ] && [ "$TAG" != "null" ] || { echo "无法解析上游最新 release" >&2; exit 1; }
fi
echo "==> 目标版本: $TAG"

# 2) 拉取该 release 的资产清单（.ko 与 susfs_insmod 加载器）
RELEASE_JSON="$(api "https://api.github.com/repos/$UPSTREAM_REPO/releases/tags/$TAG")"
ASSET_ROWS="$(echo "$RELEASE_JSON" | jq -r '
  .assets[]
  | select((.name | test("^susfs_guard_lkm-.*\\.ko$")) or .name == "susfs_insmod")
  | "\(.name)\t\(.browser_download_url)"
')"

if [ -z "$ASSET_ROWS" ]; then
  echo "上游 release $TAG 中没有找到匹配的资产（susfs_guard_lkm-*.ko / susfs_insmod）" >&2
  exit 1
fi

# 3) 组装模块目录
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
mkdir -p "$STAGE/loader"

echo "==> 下载资产:"
while IFS=$'\t' read -r name url; do
  [ -z "$name" ] && continue
  echo "    - $name"
  if [ -n "$TOKEN" ]; then
    curl -fsSL -H "Authorization: Bearer $TOKEN" -o "$STAGE/loader/$name" "$url"
  else
    curl -fsSL -o "$STAGE/loader/$name" "$url"
  fi
done <<< "$ASSET_ROWS"

KO_COUNT="$(find "$STAGE/loader" -name 'susfs_guard_lkm-*.ko' | wc -l | tr -d ' ')"
echo "==> 共下载 $KO_COUNT 个 .ko 变体"

# 4) 计算 versionCode：major*1e6 + minor*1e4 + patch*1e2 + rev
major=$(printf '%s' "$TAG" | sed -nE 's/^[^0-9]*([0-9]+).*/\1/p'); major=${major:-0}
minor=$(printf '%s' "$TAG" | sed -nE 's/^[^0-9]*[0-9]+\.([0-9]+).*/\1/p'); minor=${minor:-0}
patch=$(printf '%s' "$TAG" | sed -nE 's/^[^0-9]*[0-9]+\.[0-9]+\.([0-9]+).*/\1/p'); patch=${patch:-0}
rev=$(printf '%s' "$TAG" | sed -nE 's/.*[rR]([0-9]+).*/\1/p'); rev=${rev:-0}
VERSION_CODE=$(( major * 1000000 + minor * 10000 + patch * 100 + rev ))

DESC="Auto-built from $UPSTREAM_REPO@$TAG; loads the kernel-matching susfs_guard_lkm.ko at boot."

sed -e "s|__VERSION__|$TAG|g" \
    -e "s|__VERSION_CODE__|$VERSION_CODE|g" \
    -e "s|__AUTHOR__|$AUTHOR|g" \
    -e "s|__DESC__|$DESC|g" \
    "$TEMPLATE_DIR/module.prop" > "$STAGE/module.prop"
cp "$TEMPLATE_DIR/post-fs-data.sh" "$STAGE/post-fs-data.sh"

chmod 755 "$STAGE/post-fs-data.sh"
[ -f "$STAGE/loader/susfs_insmod" ] && chmod 755 "$STAGE/loader/susfs_insmod"
chmod 644 "$STAGE/module.prop" "$STAGE"/loader/*.ko

# 5) 打包
mkdir -p "$OUT_DIR"
OUT_DIR_ABS="$(cd "$OUT_DIR" && pwd)"
ZIP_NAME="susfs-lkm-loader-${TAG}.zip"
ZIP="$OUT_DIR_ABS/$ZIP_NAME"
rm -f "$ZIP"
( cd "$STAGE" && zip -qr -9 "$ZIP" . )

( cd "$OUT_DIR_ABS" && sha256sum "$ZIP_NAME" > "$ZIP_NAME.sha256" )

cat > "$OUT_DIR_ABS/build-info.env" <<EOF
tag=$TAG
upstream_repo=$UPSTREAM_REPO
version_code=$VERSION_CODE
zip=$ZIP
EOF

echo "==> 产物: $ZIP"
echo "==> 校验: $ZIP.sha256"
