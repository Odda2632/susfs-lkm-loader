#!/system/bin/sh
# 开机完成 —— 说明本次加载没有导致无法开机，清除守卫标记。
rm -f /data/adb/susfs_lkm.guard
