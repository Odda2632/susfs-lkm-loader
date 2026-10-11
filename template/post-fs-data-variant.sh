#!/system/bin/sh
# SUSFS LKM Loader（单内核变体版，带内核校验）—— 开机校验内核后加载内置的 __KO_NAME__
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

case "$KVER" in
  *__AND__*) : ;;
  *) log_msg "kernel '$KVER' is not __AND__; skip loading"; update_status "未加载: 内核不是 __AND__ (${KVER})"; exit 1 ;;
esac
case "$KVER" in
  *__MM__*) : ;;
  *) log_msg "kernel '$KVER' is not __MM__; skip loading"; update_status "未加载: 内核不是 __MM__ (${KVER})"; exit 1 ;;
esac

if [ ! -f "$KO" ]; then
  log_msg "ko not found: $KO"
  update_status "未加载: 缺少 __KO_NAME__"
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
