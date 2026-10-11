#!/system/bin/sh
# SUSFS LKM Loader（通用版）—— 开机按设备内核 KMI 精确匹配并加载
# 由 GitHub Actions 打包，loader/ 内含全部内核变体的 .ko 与 susfs_insmod。
#
# 安全策略：只加载与 uname -r 完全对应的那一份 .ko；匹配不到就跳过，绝不猜。

MODDIR=${0%/*}
LOADER_DIR="$MODDIR/loader"
LOG=/data/adb/susfs_lkm.log

log_msg() {
  log -p i -t susfs_lkm "$@"
  echo "$(date '+%F %T') $*" >> "$LOG" 2>/dev/null
}

# 把加载状态写回 module.prop 的 description，KSU 管理器中即可看到
update_status() {
  prop="$MODDIR/module.prop"
  [ -f "$prop" ] || return 0
  desc=$(sed -n 's/^description=//p' "$prop" | head -n1 | sed 's/ *||STATUS:.*$//')
  tmp="$MODDIR/.module.prop.tmp"
  grep -v '^description=' "$prop" > "$tmp" 2>/dev/null || return 0
  printf 'description=%s ||STATUS:%s\n' "$desc" "$1" >> "$tmp"
  mv "$tmp" "$prop"
}

KVER=$(uname -r)
# GKI KMI，例如 "5.15.202-android13-8-xxxx" -> android13 + 5.15
AND_PART=$(echo "$KVER" | grep -oE 'android1[0-9]' | head -n1)
MM_PART=$(echo "$KVER" | grep -oE '^[0-9]+\.[0-9]+' | head -n1)

KO=""
if [ -n "$AND_PART" ] && [ -n "$MM_PART" ]; then
  KO="$LOADER_DIR/susfs_guard_lkm-${AND_PART}-${MM_PART}.ko"
fi

if [ -z "$KO" ] || [ ! -f "$KO" ]; then
  log_msg "no exact .ko for kernel '$KVER' (kmi ${AND_PART:-?}-${MM_PART:-?}); skip loading"
  update_status "未加载: 无匹配内核 (${KVER})"
  exit 1
fi

log_msg "loading $KO (kernel $KVER)"

# KernelSU/APatch 设备用 ksud；非 KernelSU 才用 release 自带的 susfs_insmod
if command -v ksud >/dev/null 2>&1; then
  ksud insmod "$KO"
elif [ -x "$LOADER_DIR/susfs_insmod" ]; then
  "$LOADER_DIR/susfs_insmod" "$KO"
else
  log_msg "no usable loader (ksud / susfs_insmod); skip loading"
  update_status "未加载: 无可用加载器"
  exit 1
fi
status=$?

if [ "$status" -eq 0 ]; then
  log_msg "loaded ok"
  update_status "已加载 $(basename "$KO") @ $(date '+%m-%d %H:%M')"
else
  log_msg "load failed (exit=$status)"
  update_status "加载失败 exit=$status @ $(date '+%m-%d %H:%M')"
fi
exit $status
