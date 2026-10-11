#!/system/bin/sh
# SUSFS LKM Loader（单内核变体版）—— 开机校验内核后加载内置的 __KO_NAME__
#
# 安全策略：先确认设备内核串包含 __AND__ 且包含 __MM__，否则跳过，避免把不匹配的
# .ko 装进别的内核导致 panic。

MODDIR=${0%/*}
KO="$MODDIR/loader/__KO_NAME__"
LOG=/data/adb/susfs_lkm.log

log_msg() {
  log -p i -t susfs_lkm "$@"
  echo "$(date '+%F %T') $*" >> "$LOG" 2>/dev/null
}

KVER=$(uname -r)

case "$KVER" in
  *__AND__*) : ;;
  *) log_msg "kernel '$KVER' is not __AND__; skip loading (variant package)"; exit 1 ;;
esac
case "$KVER" in
  *__MM__*) : ;;
  *) log_msg "kernel '$KVER' is not __MM__; skip loading (variant package)"; exit 1 ;;
esac

if [ ! -f "$KO" ]; then
  log_msg "ko not found: $KO"
  exit 1
fi

log_msg "loading $KO (kernel $KVER)"

# KernelSU/APatch 设备用 ksud；非 KernelSU 才用 release 自带的 susfs_insmod
if command -v ksud >/dev/null 2>&1; then
  ksud insmod "$KO"
elif [ -x "$MODDIR/loader/susfs_insmod" ]; then
  "$MODDIR/loader/susfs_insmod" "$KO"
else
  log_msg "no usable loader (ksud / susfs_insmod); skip loading"
  exit 1
fi
status=$?

log_msg "done, exit=$status"
exit $status
