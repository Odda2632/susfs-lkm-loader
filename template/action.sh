#!/system/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
# KernelSU "Action" button: try one manual load, bypassing the GUARD and clearing the
# disabled marker, and print the result so it can be tested safely.
MODDIR=${0%/*}
export SUSFS_FORCE=1

echo "== SUSFS LKM manual load =="
echo "kernel: $(cat /proc/sys/kernel/osrelease 2>/dev/null || uname -r)"
if [ -d /sys/module/susfs_guard_lkm ]; then
  echo "note: susfs_guard_lkm is ALREADY loaded; the script will skip (stacking is refused)"
fi
echo "----------------------------"
sh "$MODDIR/service.sh"
rc=$?
echo "----------------------------"
if [ "$rc" -eq 0 ]; then
  echo "result: loaded or already present"
else
  echo "result: not loaded / failed (exit=$rc)"
fi
echo "--- recent log ---"
tail -n 8 /data/adb/susfs_lkm.log 2>/dev/null
