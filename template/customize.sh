#!/system/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
# Installer: set permissions and clear the previous brick-guard/disabled markers, so a
# reinstall always retries the load without the user having to delete the marker by hand.

set_perm_recursive "$MODPATH" 0 0 0755 0644
set_perm "$MODPATH/loader/susfs_insmod" 0 0 0755
set_perm "$MODPATH/service.sh" 0 0 0755
set_perm "$MODPATH/action.sh" 0 0 0755
set_perm "$MODPATH/boot-completed.sh" 0 0 0755
set_perm "$MODPATH/_lib.sh" 0 0 0644

# drop stamp files left by a previous install (stale build hashes etc.)
rm -f "$MODPATH"/.stamp-* 2>/dev/null

rm -f /data/adb/susfs_lkm.disabled /data/adb/susfs_lkm.guard

ui_print "- susfs_insmod is executable"
ui_print "- cleared the previous disabled/guard markers; the load will be retried on boot"
ui_print "- stacking is refused: if SUSFS is already live, nothing is loaded"
