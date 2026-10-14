#!/system/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
# SUSFS LKM AutoLoader (single KMI variant, NO KMI check) - load __KO_NAME__ as-is.
#
# Intended for kernels whose release string carries no "androidNN" field, where no
# automatic KMI match is possible. The operator is asserting that this .ko is the
# right one; loading the wrong one can still panic. The "already loaded" check below
# is NOT optional and is still enforced.

MODDIR=${0%/*}
LOADER_DIR="$MODDIR/loader"
KO="$LOADER_DIR/__KO_NAME__"

if [ ! -f "$MODDIR/_lib.sh" ]; then
  log -p e -t susfs_lkm "_lib.sh missing; refusing to run" 2>/dev/null
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
# Deliberately no KMI match here - that is what "nocheck" means - but stacking is
# still refused, and that is the check that keeps this variant from bricking.
if susfs_present; then
  log_msg "existing SUSFS detected; skip to avoid stacking"
  update_status "未加载: 检测到已有 SUSFS，避免叠加"
  guard_abort
  exit 0
fi

if [ ! -f "$KO" ]; then
  log_msg "ko not found: $KO"
  update_status "未加载: 缺少 __KO_NAME__"
  guard_abort
  exit 1
fi

log_msg "loading $(basename "$KO") (kernel $KVER) [no-check]"
load_ko "$KO" expose_proc=1
status=$?

if [ "$status" -eq 0 ]; then
  log_msg "loaded ok"
  update_status "已加载 $(basename "$KO") (no-check) @ $(date '+%m-%d %H:%M')"
  [ "${SUSFS_FORCE:-0}" = "1" ] && guard_abort
else
  log_msg "load failed (exit=$status)"
  update_status "加载失败 exit=$status @ $(date '+%m-%d %H:%M')"
  guard_abort
fi
exit $status
