#!/system/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
# Boot finished, so the load attempt did not hang the device. Clear the guard marker.
rm -f /data/adb/susfs_lkm.guard
