#!/system/bin/sh
# SUSFS LKM Loader（通用版）—— 在 late_start（service.sh）阶段按设备内核 KMI 精确匹配并加载。
#
# 加载方式（关键）：
#   1) 用 release 自带的 susfs_insmod 直接加载并传 expose_proc=1，不要用 `ksud insmod`。
#   2) 放在 service.sh(late_start) 而不是 post-fs-data：该 LKM 加载时要读取 KernelSU 自身状态
#      （例如 kernel-umount 的应答），开机早期 KernelSU 还没准备好，过早加载会卡第一屏；
#      等系统起到 late_start 再加载即可正常（与手动点“操作”按钮加载成功的时点一致）。
#
# 安全策略：
#   1) 按真实内核串(/proc/sys/kernel/osrelease)精确匹配那一份 .ko，匹配不到就跳过，绝不猜。
#   2) 若已有 SUSFS(/proc/susfs 存在)，不叠加，直接跳过（叠加会 panic）。
#   3) 防砖守卫：加载前写 guard，开机完成后由 boot-completed.sh 清除；若下次开机 guard 仍在，
#      说明上次加载后没能开机 → 自动禁用，避免无限重启。

MODDIR=${0%/*}
LOADER_DIR="$MODDIR/loader"
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
  rm -f "$GUARD"
  exit 1
fi

log_msg "loading $KO (kernel $KVER)"

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
  update_status "已加载 $(basename "$KO") @ $(date '+%m-%d %H:%M')"
  [ "$SUSFS_FORCE" = "1" ] && rm -f "$GUARD"
else
  log_msg "load failed (exit=$status)"
  update_status "加载失败 exit=$status @ $(date '+%m-%d %H:%M')"
  rm -f "$GUARD"
fi
exit $status
