#!/system/bin/sh
# 在 KernelSU 管理器中点击“操作 / Action”按钮时执行：
# 手动加载一次（跳过守卫、清除“已禁用”标记），并把结果打印出来，供你安全测试。
MODDIR=${0%/*}
export SUSFS_FORCE=1

echo "== SUSFS LKM 手动加载 =="
sh "$MODDIR/post-fs-data.sh"
rc=$?
echo "----------------------------------"
if [ "$rc" -eq 0 ]; then
  echo "结果: 加载成功"
else
  echo "结果: 未加载 / 失败 (exit=$rc)"
fi
echo "详细日志: /data/adb/susfs_lkm.log"
