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
  exit 1
fi
status=$?

log_msg "done, exit=$status"
exit $status
