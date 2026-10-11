#!/system/bin/sh
# SUSFS LKM Loader（单内核变体版）—— 开机加载本模块内置的 __KO_NAME__
MODDIR=${0%/*}
KO="$MODDIR/loader/__KO_NAME__"

log_msg() { log -p i -t susfs_lkm "$@"; }

if [ ! -f "$KO" ]; then
  log_msg "error: ko not found: $KO"
  exit 1
fi

log_msg "loading $KO (kernel $(uname -r))"

# 优先用 release 自带的 susfs_insmod（不依赖 KernelSU），其次 ksud，最后裸 insmod
if [ -x "$MODDIR/loader/susfs_insmod" ]; then
  "$MODDIR/loader/susfs_insmod" "$KO"
elif command -v ksud >/dev/null 2>&1; then
  ksud insmod "$KO"
else
  insmod "$KO"
fi
status=$?

if [ "$status" -eq 0 ]; then
  log_msg "load ok"
else
  log_msg "load failed (exit $status)"
fi
exit $status
