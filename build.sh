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
AUTHOR="${AUTHOR:-Odda2632 & TraeCode}"
# sed 替换串里 & 表示“整个匹配”，需转义
AUTHOR_SED="$(printf '%s' "$AUTHOR" | sed 's/[&\\|]/\\&/g')"
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

sed -e "s|__ID__|susfs_lkm_loader|g" \
    -e "s|__NAME__|SUSFS LKM Loader (Auto-Build)|g" \
    -e "s|__VERSION__|$TAG|g" \
    -e "s|__VERSION_CODE__|$VERSION_CODE|g" \
    -e "s|__AUTHOR__|$AUTHOR_SED|g" \
    -e "s|__DESC__|$DESC|g" \
    "$TEMPLATE_DIR/module.prop" > "$STAGE/module.prop"
cp "$TEMPLATE_DIR/service.sh" "$STAGE/service.sh"
cp "$TEMPLATE_DIR/boot-completed.sh" "$STAGE/boot-completed.sh"
cp "$TEMPLATE_DIR/action.sh" "$STAGE/action.sh"
cp "$TEMPLATE_DIR/customize.sh" "$STAGE/customize.sh"
touch "$STAGE/skip_mount"

chmod 755 "$STAGE/service.sh" "$STAGE/boot-completed.sh" "$STAGE/action.sh" "$STAGE/customize.sh"
[ -f "$STAGE/loader/susfs_insmod" ] && chmod 755 "$STAGE/loader/susfs_insmod"
chmod 644 "$STAGE/module.prop" "$STAGE"/loader/*.ko

# 5) 通用包：内含全部内核变体，开机按 KMI 自动匹配
mkdir -p "$OUT_DIR"
OUT_DIR_ABS="$(cd "$OUT_DIR" && pwd)"
ZIP_NAME="susfs-lkm-loader-${TAG}.zip"
ZIP="$OUT_DIR_ABS/$ZIP_NAME"
rm -f "$ZIP"
( cd "$STAGE" && zip -qr -9 "$ZIP" . )
echo "==> 通用产物: $ZIP"

# 6) 单内核变体包：每个 .ko 单独一份（例如 android12-5.10）
VARIANT_LIST=""
for ko in "$STAGE"/loader/susfs_guard_lkm-*.ko; do
  [ -f "$ko" ] || continue
  base="$(basename "$ko" .ko)"                 # susfs_guard_lkm-android12-5.10
  kmi="${base#susfs_guard_lkm-}"               # android12-5.10
  vid="susfs_lkm_loader_$(printf '%s' "$kmi" | tr -c 'A-Za-z0-9_' '_')"

  vstage="$(mktemp -d)"
  mkdir -p "$vstage/loader"
  cp "$ko" "$vstage/loader/"
  [ -f "$STAGE/loader/susfs_insmod" ] && cp "$STAGE/loader/susfs_insmod" "$vstage/loader/"

  vdesc="Auto-built from $UPSTREAM_REPO@$TAG for $kmi ($base.ko)."
  sed -e "s|__ID__|$vid|g" \
      -e "s|__NAME__|SUSFS LKM Loader ($kmi)|g" \
      -e "s|__VERSION__|$TAG|g" \
      -e "s|__VERSION_CODE__|$VERSION_CODE|g" \
      -e "s|__AUTHOR__|$AUTHOR_SED|g" \
      -e "s|__DESC__|$vdesc|g" \
      "$TEMPLATE_DIR/module.prop" > "$vstage/module.prop"
  sed -e "s|__KO_NAME__|$(basename "$ko")|g" \
      -e "s|__AND__|${kmi%-*}|g" \
      -e "s|__MM__|${kmi#*-}|g" \
      "$TEMPLATE_DIR/service-variant.sh" > "$vstage/service.sh"
  cp "$TEMPLATE_DIR/boot-completed.sh" "$vstage/boot-completed.sh"
  cp "$TEMPLATE_DIR/action.sh" "$vstage/action.sh"
  cp "$TEMPLATE_DIR/customize.sh" "$vstage/customize.sh"
  touch "$vstage/skip_mount"

  chmod 755 "$vstage/service.sh" "$vstage/boot-completed.sh" "$vstage/action.sh" "$vstage/customize.sh"
  [ -f "$vstage/loader/susfs_insmod" ] && chmod 755 "$vstage/loader/susfs_insmod"
  chmod 644 "$vstage/module.prop" "$vstage/loader/"*.ko

  vzip="$OUT_DIR_ABS/susfs-lkm-loader-${TAG}-${kmi}.zip"
  rm -f "$vzip"
  ( cd "$vstage" && zip -qr -9 "$vzip" . )
  rm -rf "$vstage"
  VARIANT_LIST="$VARIANT_LIST $kmi"
  echo "==> 变体产物: $vzip"
done

# 7) 额外打包“无内核校验”变体（默认 android12-5.10，文件名带 -nocheck 区分）
NOCHECK_VARIANTS="${NOCHECK_VARIANTS:-android12-5.10}"
NOCHECK_LIST=""
for kmi in $NOCHECK_VARIANTS; do
  ko="$STAGE/loader/susfs_guard_lkm-${kmi}.ko"
  if [ ! -f "$ko" ]; then
    echo "==> 跳过无校验变体（无此 ko）: $kmi"
    continue
  fi
  vid="susfs_lkm_loader_$(printf '%s' "$kmi" | tr -c 'A-Za-z0-9_' '_')_nocheck"

  nstage="$(mktemp -d)"
  mkdir -p "$nstage/loader"
  cp "$ko" "$nstage/loader/"
  [ -f "$STAGE/loader/susfs_insmod" ] && cp "$STAGE/loader/susfs_insmod" "$nstage/loader/"

  ndesc="Auto-built from $UPSTREAM_REPO@$TAG for $kmi, NO kernel KMI check."
  sed -e "s|__ID__|$vid|g" \
      -e "s|__NAME__|SUSFS LKM Loader ($kmi, no-check)|g" \
      -e "s|__VERSION__|$TAG|g" \
      -e "s|__VERSION_CODE__|$VERSION_CODE|g" \
      -e "s|__AUTHOR__|$AUTHOR_SED|g" \
      -e "s|__DESC__|$ndesc|g" \
      "$TEMPLATE_DIR/module.prop" > "$nstage/module.prop"
  sed -e "s|__KO_NAME__|$(basename "$ko")|g" \
      "$TEMPLATE_DIR/service-variant-nocheck.sh" > "$nstage/service.sh"
  cp "$TEMPLATE_DIR/boot-completed.sh" "$nstage/boot-completed.sh"
  cp "$TEMPLATE_DIR/action.sh" "$nstage/action.sh"
  cp "$TEMPLATE_DIR/customize.sh" "$nstage/customize.sh"
  touch "$nstage/skip_mount"

  chmod 755 "$nstage/service.sh" "$nstage/boot-completed.sh" "$nstage/action.sh" "$nstage/customize.sh"
  [ -f "$nstage/loader/susfs_insmod" ] && chmod 755 "$nstage/loader/susfs_insmod"
  chmod 644 "$nstage/module.prop" "$nstage/loader/"*.ko

  nzip="$OUT_DIR_ABS/susfs-lkm-loader-${TAG}-${kmi}-nocheck.zip"
  rm -f "$nzip"
  ( cd "$nstage" && zip -qr -9 "$nzip" . )
  rm -rf "$nstage"
  NOCHECK_LIST="$NOCHECK_LIST $kmi"
  echo "==> 无校验变体产物: $nzip"
done

# 8) 校验和汇总
( cd "$OUT_DIR_ABS" && sha256sum ./*.zip > SHA256SUMS )

cat > "$OUT_DIR_ABS/build-info.env" <<EOF
tag=$TAG
upstream_repo=$UPSTREAM_REPO
version_code=$VERSION_CODE
zip=$ZIP
variants=${VARIANT_LIST# }
nocheck=${NOCHECK_LIST# }
EOF

echo "==> 校验汇总: $OUT_DIR_ABS/SHA256SUMS"
