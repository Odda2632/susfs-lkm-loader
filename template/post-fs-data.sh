#!/system/bin/sh
# SUSFS LKM Loader（通用版）—— 由 service.sh 在 late_start 阶段按设备内核 KMI 精确匹配并加载
# 由 GitHub Actions 打包，loader/ 内含全部内核变体的 .ko 与 susfs_insmod。
#
# 为何放在 service.sh 而不是 post-fs-data：在内核启动早期加载这个会 hook LSM 的 .ko
# 会导致开机卡第一屏；等系统起来（late_start）再加载则正常。
#
# 安全策略：
#   1) 只加载与 uname -r 完全对应的那一份 .ko；匹配不到就跳过，绝不猜。
#   2) 防砖守卫：加载前写 guard 标记，开机完成后由 boot-completed.sh 清除。
#      若下次开机时 guard 仍在，说明上次加载后没能开机 → 自动禁用，避免无限重启。

MODDIR=${0%/*}
LOADER_DIR="$MODDIR/loader"
LOG=/data/adb/susfs_lkm.log
GUARD=/data/adb/susfs_lkm.guard
DISABLED=/data/adb/susfs_lkm.disabled

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
  rm -f "$GUARD"
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
  rm -f "$GUARD"
  exit 1
fi
status=$?

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
