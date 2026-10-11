#!/system/bin/sh
# SUSFS LKM Loader（单内核变体版，无内核校验）—— late_start(service.sh) 直接加载内置的
# __KO_NAME__。加载方式与参考实现一致：用自带的 susfs_insmod（不要用 ksud insmod）。
# 放到 late_start 而不是 post-fs-data，避免开机早期加载导致卡第一屏。
#
# 注意：本包不做内核 KMI 校验，会把 __KO_NAME__ 无条件加载；装错内核会 panic，请自担风险。
# 仍有防砖守卫：加载后无法开机时下次自动禁用。

MODDIR=${0%/*}
LOADER_DIR="$MODDIR/loader"
KO="$LOADER_DIR/__KO_NAME__"
LOG=/data/adb/susfs_lkm.log
GUARD=/data/adb/susfs_lkm.guard
DISABLED=/data/adb/susfs_lkm.disabled

[ -f "$MODDIR/disable" ] && exit 0

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

# ---- 防砖守卫 ----
if [ "$SUSFS_FORCE" = "1" ]; then
  rm -f "$DISABLED"
else
  if [ -f "$DISABLED" ]; then
    log_msg "disabled marker present; skip loading"
    update_status "已禁用: 上次加载后未能开机（管理器点“操作”可手动重试）"
    exit 1
  fi
  if [ -f "$GUARD" ]; then
    mv -f "$GUARD" "$DISABLED"
    log_msg "previous load never reached boot-completed; auto-disabled to protect boot"
    update_status "已自动禁用: 上次加载后未能开机（管理器点“操作”可手动重试）"
    exit 1
  fi
fi
touch "$GUARD"; sync

# 真实内核串：uname 可能已被其它 SUSFS 实现伪造
KVER=$(cat /proc/sys/kernel/osrelease 2>/dev/null)
[ -n "$KVER" ] || KVER=$(uname -r)

# 已有 SUSFS 就绝不叠加
if [ -e /proc/susfs ] || [ -e /proc/susfs_mnt_id ]; then
  log_msg "existing SUSFS detected (/proc/susfs); skip to avoid stacking"
  update_status "未加载: 检测到已有 SUSFS，避免叠加"
  rm -f "$GUARD"
  exit 1
fi

if [ ! -f "$KO" ]; then
  log_msg "ko not found: $KO"
  update_status "未加载: 缺少 __KO_NAME__"
  rm -f "$GUARD"
  exit 1
fi

log_msg "loading $KO (kernel $KVER) [no-check]"

if [ ! -f "$LOADER_DIR/susfs_insmod" ]; then
  log_msg "susfs_insmod missing; skip loading"
  update_status "未加载: 缺少 susfs_insmod"
  rm -f "$GUARD"
  exit 1
fi
# 安装时若未带可执行位，这里补上（KernelSU 解压不一定保留）
chmod 0755 "$LOADER_DIR/susfs_insmod" 2>/dev/null

# 用自带的 susfs_insmod 加载（不要用 ksud insmod）。先带 expose_proc=1，参数不被接受则退回无参。
"$LOADER_DIR/susfs_insmod" "$KO" expose_proc=1
status=$?
if [ "$status" -ne 0 ]; then
  log_msg "susfs_insmod with expose_proc=1 failed (exit=$status); retry without params"
  "$LOADER_DIR/susfs_insmod" "$KO"
  status=$?
fi

if [ "$status" -eq 0 ]; then
  log_msg "loaded ok"
  update_status "已加载 $(basename "$KO") (no-check) @ $(date '+%m-%d %H:%M')"
  [ "$SUSFS_FORCE" = "1" ] && rm -f "$GUARD"
else
  log_msg "load failed (exit=$status)"
  update_status "加载失败 exit=$status @ $(date '+%m-%d %H:%M')"
  rm -f "$GUARD"
fi
exit $status
