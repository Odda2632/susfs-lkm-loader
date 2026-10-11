#!/system/bin/sh
# 安装时执行：设置可执行权限，并清除上一次的“防砖禁用/守卫”标记，
# 这样每次覆盖安装后都会重新尝试加载，不必手动去删 /data/adb/susfs_lkm.disabled。

set_perm_recursive "$MODPATH" 0 0 0755 0644
set_perm "$MODPATH/loader/susfs_insmod" 0 0 0755
set_perm "$MODPATH/post-fs-data.sh" 0 0 0755
set_perm "$MODPATH/action.sh" 0 0 0755
set_perm "$MODPATH/boot-completed.sh" 0 0 0755

rm -f /data/adb/susfs_lkm.disabled /data/adb/susfs_lkm.guard

ui_print "- 已授权 susfs_insmod 可执行"
ui_print "- 已清除上次的禁用标记，重启后将重新尝试加载"
