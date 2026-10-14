#!/system/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
# SUSFS LKM AutoLoader (single KMI variant, checked) - load the bundled __KO_NAME__
# only if the real kernel release string matches __AND__ and __MM__.
#
# Rules: use the bundled susfs_insmod (not `ksud insmod`); run at late_start; never
# stack; guard against a load that never reaches boot-completed.

MODDIR=${0%/*}
LOADER_DIR="$MODDIR/loader"
KO="$LOADER_DIR/__KO_NAME__"

if [ ! -f "$MODDIR/_lib.sh" ]; then
  log -p e -t susfs_lkm "_lib.sh missing; refusing to run" 2>/dev/null
  exit 1
else
  . "$MODDIR/_lib.sh"
fi
[ -f "$MODDIR/disable" ] && exit 0

guard_check || exit 1
guard_begin

KVER="$(real_kernel_release)"
if [ -z "$KVER" ]; then
  log_msg "cannot read kernel release"
  update_status "未加载: 读不到内核版本"
  guard_abort
  exit 1
fi

if susfs_present; then
  log_msg "existing SUSFS detected; skip to avoid stacking"
  update_status "未加载: 检测到已有 SUSFS，避免叠加"
  guard_abort
  exit 0
fi

case "$KVER" in
  *__AND__*) : ;;
  *) log_msg "kernel '$KVER' is not __AND__; skip loading"; update_status "未加载: 内核不是 __AND__ (${KVER})"; guard_abort; exit 1 ;;
esac
case "$KVER" in
  *__MM__*) : ;;
  *) log_msg "kernel '$KVER' is not __MM__; skip loading"; update_status "未加载: 内核不是 __MM__ (${KVER})"; guard_abort; exit 1 ;;
esac

if [ ! -f "$KO" ]; then
  log_msg "ko not found: $KO"
  update_status "未加载: 缺少 __KO_NAME__"
  guard_abort
  exit 1
fi

log_msg "loading $(basename "$KO") (kernel $KVER)"
load_ko "$KO" expose_proc=1
status=$?

if [ "$status" -eq 0 ]; then
  log_msg "loaded ok"
  update_status "已加载 $(basename "$KO") @ $(date '+%m-%d %H:%M')"
  [ "${SUSFS_FORCE:-0}" = "1" ] && guard_abort
else
  log_msg "load failed (exit=$status)"
  update_status "加载失败 exit=$status @ $(date '+%m-%d %H:%M')"
  guard_abort
fi
exit $status
