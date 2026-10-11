#!/system/bin/sh
# SUSFS LKM Loader —— 开机自动加载与当前设备内核 KMI 匹配的 susfs_guard_lkm.ko
# 由 GitHub Actions 打包，模块内 loader/ 目录含全部内核变体的 .ko 与 susfs_insmod 加载器。

MODDIR=${0%/*}
LOADER_DIR="$MODDIR/loader"

log_msg() { log -p i -t susfs_lkm "$@"; }

KVER=$(uname -r)
# 从内核版本串解析 GKI KMI，例如 "5.15.202-android13-8-gxxxx" -> android13 + 5.15
AND_PART=$(echo "$KVER" | grep -oE 'android1[0-9]' | head -n1)
MM_PART=$(echo "$KVER" | grep -oE '^[0-9]+\.[0-9]+' | head -n1)

KO=""
if [ -n "$AND_PART" ] && [ -n "$MM_PART" ]; then
  [ -f "$LOADER_DIR/susfs_guard_lkm-${AND_PART}-${MM_PART}.ko" ] && \
    KO="$LOADER_DIR/susfs_guard_lkm-${AND_PART}-${MM_PART}.ko"
fi

# 退一步：只按内核主次版本号匹配（可能有多个候选时取第一个）
if [ -z "$KO" ] && [ -n "$MM_PART" ]; then
  KO=$(ls "$LOADER_DIR"/susfs_guard_lkm-*-"$MM_PART".ko 2>/dev/null | head -n1)
fi

if [ -z "$KO" ] || [ ! -f "$KO" ]; then
  log_msg "error: no matching .ko for kernel $KVER (kmi ${AND_PART}-${MM_PART})"
  exit 1
fi

log_msg "loading $KO (kernel $KVER)"

# 优先用 release 自带的 susfs_insmod（不依赖 KernelSU），其次 ksud，最后裸 insmod
if [ -x "$LOADER_DIR/susfs_insmod" ]; then
  "$LOADER_DIR/susfs_insmod" "$KO"
elif command -v ksud >/dev/null 2>&1; then
  ksud insmod "$KO"
else
  insmod "$KO"
fi
status=$?

if [ "$status" -eq 0 ]; then
  log_msg "load ok"
else
  log_msg "load failed (exit $status)"
fi
exit $status
