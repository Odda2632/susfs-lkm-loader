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
#   AUTHOR         写入 module.prop 的作者（默认 Odda2632 & TraeCode，并标注上游原作者）
#   GITHUB_TOKEN / GH_TOKEN  可选；设置后走认证请求，避免 API 限流
#
set -euo pipefail

UPSTREAM_REPO="${UPSTREAM_REPO:-inforcqb/susfs4ksu-lkm}"
MODULE_ID="susfs_lkm_autoloader"
# 上游 GitHub 原作者（从仓库名推导，例如 inforcqb/susfs4ksu-lkm -> inforcqb）
UPSTREAM_AUTHOR="${UPSTREAM_REPO%%/*}"
AUTHOR="${AUTHOR:-Odda2632 & TraeCode}"
# 在作者里标注上游原作者（.ko 由上游提供）
AUTHOR="${AUTHOR} (LKM by ${UPSTREAM_AUTHOR})"
# sed 替换串里 & 表示“整个匹配”，需转义
AUTHOR_SED="$(printf '%s' "$AUTHOR" | sed 's/[&\\|]/\\&/g')"
TAG="${1:-latest}"
OUT_DIR="${2:-out}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEMPLATE_DIR="$SCRIPT_DIR/template"

TOKEN="${GITHUB_TOKEN:-${GH_TOKEN:-}}"

# 生成 provenance.json：记录上游来源（仓库 / tag / commit）与该模块内每个二进制
# （susfs_guard_lkm-*.ko 与 susfs_insmod）的 sha256，便于溯源与校验。
# 用法: write_provenance <模块目录> <模块 id>
write_provenance() {
  local dir="$1" mid="$2"
  local rows artifacts
  rows="$(cd "$dir/loader" && for f in *; do
      [ -f "$f" ] || continue
      printf '%s\t%s\n' "$f" "$(sha256sum "$f" | awk '{print $1}')"
    done)"
  artifacts="$(printf '%s\n' "$rows" | jq -R -s '
    split("\n")
    | map(select(length > 0) | split("\t") | { name: .[0], sha256: .[1] })
  ')"
  jq -n \
    --arg gen "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
    --arg mid "$mid" \
    --arg ver "$TAG" \
    --argjson vcode "$VERSION_CODE" \
    --arg repo "$UPSTREAM_REPO" \
    --arg tag "$TAG" \
    --arg commit "$COMMIT_SHA" \
    --argjson artifacts "$artifacts" \
    '{
       schema: 1,
       generated_at: $gen,
       generator: "build.sh (Odda2632 & TraeCode, AI-assisted)",
       module: { id: $mid, version: $ver, versionCode: $vcode },
       upstream: {
         repo: $repo,
         tag: $tag,
         commit: $commit,
         url: ("https://github.com/" + $repo + "/tree/" + $tag),
         license: "GPL-2.0"
       },
       artifacts: $artifacts
     }' > "$dir/provenance.json"
}

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

# 1b) 解析该 tag 对应的上游 commit（写入 provenance.json）
COMMIT_SHA="$(api "https://api.github.com/repos/$UPSTREAM_REPO/commits/$TAG" | jq -r '.sha // empty' || true)"
[ -n "$COMMIT_SHA" ] || COMMIT_SHA="unknown"
echo "==> 上游 commit: $COMMIT_SHA"

# 2) 拉取该 release 的资产清单（.ko 与 susfs_insmod 加载器）
RELEASE_JSON="$(api "https://api.github.com/repos/$UPSTREAM_REPO/releases/tags/$TAG")"
# name<TAB>url<TAB>sha256 (empty when the API omits .digest - older GitHub).
ASSET_ROWS="$(echo "$RELEASE_JSON" | jq -r '
  .assets[]
  | select((.name | test("^susfs_guard_lkm-.*\\.ko$")) or .name == "susfs_insmod")
  | "\(.name)\t\(.browser_download_url)\t\((.digest // "") | sub("^sha256:"; ""))"
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
while IFS=$'\t' read -r name url digest; do
  [ -z "$name" ] && continue
  echo "    - $name"
  if [ -n "$TOKEN" ]; then
    curl -fsSL -H "Authorization: Bearer $TOKEN" -o "$STAGE/loader/$name" "$url"
  else
    curl -fsSL -o "$STAGE/loader/$name" "$url"
  fi
  # Verify the asset against the digest GitHub reported for it. A truncated or
  # swapped download would otherwise be packaged and shipped as a kernel module.
  if [ -n "$digest" ]; then
    got="$(sha256sum "$STAGE/loader/$name" | awk '{print $1}')"
    if [ "$got" != "$digest" ]; then
      echo "!! sha256 mismatch for $name" >&2
      echo "   expected $digest" >&2
      echo "   got      $got" >&2
      exit 1
    fi
    echo "      sha256 ok"
  else
    echo "      (no digest published by the API; recorded in provenance only)" >&2
  fi
done <<< "$ASSET_ROWS"

KO_COUNT="$(find "$STAGE/loader" -name 'susfs_guard_lkm-*.ko' | wc -l | tr -d ' ')"
echo "==> 共下载 $KO_COUNT 个 .ko 变体"

# 4) 计算 versionCode：major*1e8 + minor*1e6 + patch*1e4 + revA*1e2 + revB
#    上游 tag 形如 v2.3.0-r18 / v2.3.0-r18.1，r 后的整数与小数点后的序号都要算进去，
#    否则 "r18" 与 "r18.1" 会得到同一个 versionCode，KernelSU 认不出这是更新。
major=$(printf '%s' "$TAG" | sed -nE 's/^[^0-9]*([0-9]+).*/\1/p'); major=${major:-0}
minor=$(printf '%s' "$TAG" | sed -nE 's/^[^0-9]*[0-9]+\.([0-9]+).*/\1/p'); minor=${minor:-0}
patch=$(printf '%s' "$TAG" | sed -nE 's/^[^0-9]*[0-9]+\.[0-9]+\.([0-9]+).*/\1/p'); patch=${patch:-0}
revA=$(printf '%s' "$TAG" | sed -nE 's/.*[rR]([0-9]+).*/\1/p'); revA=${revA:-0}
revB=$(printf '%s' "$TAG" | sed -nE 's/.*[rR][0-9]+\.([0-9]+).*/\1/p'); revB=${revB:-0}
VERSION_CODE=$(( major * 100000000 + minor * 1000000 + patch * 10000 + revA * 100 + revB ))
echo "==> versionCode: $VERSION_CODE (major=$major minor=$minor patch=$patch revA=$revA revB=$revB)"

DESC="Auto-built from $UPSTREAM_REPO@$TAG (LKM by $UPSTREAM_AUTHOR); picks the matching susfs_guard_lkm.ko and loads it via susfs_insmod at late_start."

sed -e "s|__ID__|$MODULE_ID|g" \
    -e "s|__NAME__|SUSFS LKM AutoLoader (Auto-Build)|g" \
    -e "s|__VERSION__|$TAG|g" \
    -e "s|__VERSION_CODE__|$VERSION_CODE|g" \
    -e "s|__AUTHOR__|$AUTHOR_SED|g" \
    -e "s|__DESC__|$DESC|g" \
    "$TEMPLATE_DIR/module.prop" > "$STAGE/module.prop"
cp "$TEMPLATE_DIR/service.sh" "$STAGE/service.sh"
cp "$TEMPLATE_DIR/_lib.sh" "$STAGE/_lib.sh"
cp "$TEMPLATE_DIR/boot-completed.sh" "$STAGE/boot-completed.sh"
cp "$TEMPLATE_DIR/action.sh" "$STAGE/action.sh"
cp "$TEMPLATE_DIR/customize.sh" "$STAGE/customize.sh"
cp "$SCRIPT_DIR/LICENSE" "$STAGE/LICENSE"
touch "$STAGE/skip_mount"

chmod 755 "$STAGE/service.sh" "$STAGE/boot-completed.sh" "$STAGE/action.sh" "$STAGE/customize.sh"
chmod 644 "$STAGE/_lib.sh"
[ -f "$STAGE/loader/susfs_insmod" ] && chmod 755 "$STAGE/loader/susfs_insmod"
chmod 644 "$STAGE/module.prop" "$STAGE/LICENSE" "$STAGE"/loader/*.ko

# 溯源信息：记录上游仓库 / tag / commit 与每个二进制的 sha256
write_provenance "$STAGE" "$MODULE_ID"
chmod 644 "$STAGE/provenance.json"

# 5) 通用包：内含全部内核变体，开机按 KMI 自动匹配
mkdir -p "$OUT_DIR"
OUT_DIR_ABS="$(cd "$OUT_DIR" && pwd)"
ZIP_NAME="susfs-lkm-loader-${TAG}.zip"
ZIP="$OUT_DIR_ABS/$ZIP_NAME"
rm -f "$ZIP"
( cd "$STAGE" && zip -qr -9 "$ZIP" . )
echo "==> 通用产物: $ZIP"
# 通用 provenance 也单独产出一份（随 Release 一起发布）
cp "$STAGE/provenance.json" "$OUT_DIR_ABS/provenance-${TAG}.json"

# 6) 单内核变体包：每个 .ko 单独一份（例如 android12-5.10）
VARIANT_LIST=""
for ko in "$STAGE"/loader/susfs_guard_lkm-*.ko; do
  [ -f "$ko" ] || continue
  base="$(basename "$ko" .ko)"                 # susfs_guard_lkm-android12-5.10
  kmi="${base#susfs_guard_lkm-}"               # android12-5.10
  vid="${MODULE_ID}_$(printf '%s' "$kmi" | tr -c 'A-Za-z0-9_' '_')"

  vstage="$(mktemp -d)"
  mkdir -p "$vstage/loader"
  cp "$ko" "$vstage/loader/"
  [ -f "$STAGE/loader/susfs_insmod" ] && cp "$STAGE/loader/susfs_insmod" "$vstage/loader/"

  vdesc="Auto-built from $UPSTREAM_REPO@$TAG for $kmi ($base.ko); KMI-checked load via susfs_insmod at late_start."
  sed -e "s|__ID__|$vid|g" \
      -e "s|__NAME__|SUSFS LKM AutoLoader ($kmi)|g" \
      -e "s|__VERSION__|$TAG|g" \
      -e "s|__VERSION_CODE__|$VERSION_CODE|g" \
      -e "s|__AUTHOR__|$AUTHOR_SED|g" \
      -e "s|__DESC__|$vdesc|g" \
      "$TEMPLATE_DIR/module.prop" > "$vstage/module.prop"
  sed -e "s|__KO_NAME__|$(basename "$ko")|g" \
      -e "s|__AND__|${kmi%-*}|g" \
      -e "s|__MM__|${kmi#*-}|g" \
      "$TEMPLATE_DIR/service-variant.sh" > "$vstage/service.sh"
  cp "$TEMPLATE_DIR/_lib.sh" "$vstage/_lib.sh"
  cp "$TEMPLATE_DIR/boot-completed.sh" "$vstage/boot-completed.sh"
  cp "$TEMPLATE_DIR/action.sh" "$vstage/action.sh"
  cp "$TEMPLATE_DIR/customize.sh" "$vstage/customize.sh"
  cp "$SCRIPT_DIR/LICENSE" "$vstage/LICENSE"
  touch "$vstage/skip_mount"

  chmod 755 "$vstage/service.sh" "$vstage/boot-completed.sh" "$vstage/action.sh" "$vstage/customize.sh"
  chmod 644 "$vstage/_lib.sh"
  [ -f "$vstage/loader/susfs_insmod" ] && chmod 755 "$vstage/loader/susfs_insmod"
  chmod 644 "$vstage/module.prop" "$vstage/LICENSE" "$vstage/loader/"*.ko
  write_provenance "$vstage" "$vid"
  chmod 644 "$vstage/provenance.json"

  vzip="$OUT_DIR_ABS/susfs-lkm-loader-${TAG}-${kmi}.zip"
  rm -f "$vzip"
  ( cd "$vstage" && zip -qr -9 "$vzip" . )
  rm -rf "$vstage"
  VARIANT_LIST="$VARIANT_LIST $kmi"
  echo "==> 变体产物: $vzip"
done

# 7) 出厂前自检：每个 zip 必须是“可直接刷入”的模块（根目录含 module.prop），
#     且必须带上共享库与可用的 service.sh；脚本语法错误在这里就会被拦下。
REQUIRED="module.prop service.sh boot-completed.sh action.sh customize.sh LICENSE _lib.sh loader/susfs_insmod"
vfail=0
for z in "$OUT_DIR_ABS"/*.zip; do
  [ -f "$z" ] || continue
  names="$(unzip -Z1 "$z")"
  for f in $REQUIRED; do
    if ! printf '%s\n' "$names" | grep -qx "$f"; then
      echo "!! $(basename "$z") 缺少 $f" >&2
      vfail=1
    fi
  done
  if ! printf '%s\n' "$names" | grep -qE '^loader/susfs_guard_lkm-.*\.ko$'; then
    echo "!! $(basename "$z") 里没有任何 .ko" >&2
    vfail=1
  fi
  # 脚本语法必须在打包机上就能过
  tmpd="$(mktemp -d)"
  unzip -qo "$z" -d "$tmpd"
  for sh_f in service.sh boot-completed.sh action.sh customize.sh _lib.sh; do
    if ! sh -n "$tmpd/$sh_f" 2>/dev/null; then
      echo "!! $(basename "$z") 的 $sh_f 语法检查未通过" >&2
      vfail=1
    fi
  done
  # 关键回归：旧的错误判据不该再出现
  if grep -q 'proc/susfs \] || \[ -e /proc/susfs_mnt_id' "$tmpd/service.sh"; then
    echo "!! $(basename "$z") 仍然使用已废弃的 /proc/susfs 叠加判据" >&2
    vfail=1
  fi
  if ! grep -q 'susfs_present' "$tmpd/service.sh"; then
    echo "!! $(basename "$z") 的 service.sh 没有接入 susfs_present" >&2
    vfail=1
  fi
  rm -rf "$tmpd"
  [ "$vfail" = "0" ] && echo "==> 自检通过: $(basename "$z")"
done
[ "$vfail" = "0" ] || { echo "打包自检失败，拒绝产出 release" >&2; exit 1; }

# 8) 校验和汇总
( cd "$OUT_DIR_ABS" && sha256sum ./*.zip > SHA256SUMS )

cat > "$OUT_DIR_ABS/build-info.env" <<EOF
tag=$TAG
upstream_repo=$UPSTREAM_REPO
upstream_commit=$COMMIT_SHA
version_code=$VERSION_CODE
zip=$ZIP
provenance=$OUT_DIR_ABS/provenance-${TAG}.json
variants=${VARIANT_LIST# }
EOF

echo "==> 校验汇总: $OUT_DIR_ABS/SHA256SUMS"
