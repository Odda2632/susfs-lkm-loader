#!/system/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
# SUSFS LKM AutoLoader (universal) - pick the .ko matching the device KMI and load it once.
#
# Loading rules
#   1) Use the bundled susfs_insmod, not `ksud insmod`.
#   2) late_start (service.sh), not post-fs-data: the LKM reads KernelSU state while it
#      initialises, and post-fs-data is too early for that.
#   3) Never stack. If any SUSFS is already live, do nothing - a second copy panics.
#   4) Guard: if a load attempt never reaches boot-completed, the module disables itself
#      instead of looping and bricking the device.

MODDIR=${0%/*}
LOADER_DIR="$MODDIR/loader"

if [ ! -f "$MODDIR/_lib.sh" ]; then
  log -p e -t susfs_lkm "_lib.sh missing; refusing to run" 2>/dev/null
else
  . "$MODDIR/_lib.sh"
fi
[ -f "$MODDIR/disable" ] && exit 0

# ---- guard / disabled state ----
guard_check || exit 1
guard_begin

KVER="$(real_kernel_release)"
if [ -z "$KVER" ]; then
  log_msg "cannot read kernel release"
  update_status "未加载: 读不到内核版本"
  guard_abort
  exit 1
fi

# ---- never stack on a live SUSFS ----
if susfs_present; then
  log_msg "existing SUSFS detected; skip to avoid stacking"
  update_status "未加载: 检测到已有 SUSFS，避免叠加"
  guard_abort
  exit 0
fi

# ---- pick the .ko ----
ko=""
forced="$(kmi_force_get)"
if [ -n "$forced" ]; then
  if [ -f "$LOADER_DIR/susfs_guard_lkm-$forced.ko" ]; then
    ko="$LOADER_DIR/susfs_guard_lkm-$forced.ko"
    log_msg "kmi.force=$forced (explicit pin)"
  else
    log_msg "kmi.force=$forced but that .ko is not packaged; refusing"
    update_status "未加载: kmi.force=$forced 无对应 .ko"
    guard_abort
    exit 1
  fi
else
  AND_PART="$(echo "$KVER" | grep -oE 'android[0-9]+' | head -n1)"
  MM_PART="$(echo "$KVER" | grep -oE '^[0-9]+\.[0-9]+' | head -n1)"
  if [ -n "$AND_PART" ] && [ -n "$MM_PART" ] && [ -f "$LOADER_DIR/susfs_guard_lkm-${AND_PART}-${MM_PART}.ko" ]; then
    ko="$LOADER_DIR/susfs_guard_lkm-${AND_PART}-${MM_PART}.ko"
  else
    # No exact match. If this package ships exactly one .ko, that one is the intended
    # target (single-variant packages); otherwise refuse rather than guess.
    _n="$(ls "$LOADER_DIR"/susfs_guard_lkm-*.ko 2>/dev/null | wc -l | tr -d ' ')"
    if [ "$_n" = "1" ]; then
      ko="$(ls "$LOADER_DIR"/susfs_guard_lkm-*.ko 2>/dev/null)"
      log_msg "no exact .ko for '$KVER' (kmi ${AND_PART:-?}-${MM_PART:-?}); single packaged variant -> $(basename "$ko")"
    else
      log_msg "no exact .ko for '$KVER' (kmi ${AND_PART:-?}-${MM_PART:-?}), $_n variants packaged; refusing to guess"
      update_status "未加载: 无匹配内核 (${KVER})"
      guard_abort
      exit 1
    fi
  fi
fi

log_msg "loading $(basename "$ko") (kernel $KVER)"
load_ko "$ko" expose_proc=1
status=$?

if [ "$status" -eq 0 ]; then
  log_msg "loaded ok"
  update_status "已加载 $(basename "$ko") @ $(date '+%m-%d %H:%M')"
  [ "${SUSFS_FORCE:-0}" = "1" ] && guard_abort
else
  log_msg "load failed (exit=$status)"
  update_status "加载失败 exit=$status @ $(date '+%m-%d %H:%M')"
  guard_abort
fi
exit $status
