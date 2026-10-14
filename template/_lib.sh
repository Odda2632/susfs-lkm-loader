#!/system/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
#
# Shared helper library for the SUSFS LKM AutoLoader module scripts.
# Sourced by service.sh and by both single-variant scripts, so that the
# "is SUSFS already live in this kernel?" decision cannot drift between
# packages again.
#
# Why this file exists
# --------------------
# The first revision tested only /proc/susfs and /proc/susfs_mnt_id.
# inforcqb's susfs_guard_lkm (v2.3.0) creates neither of those nodes - it
# creates /proc/susfs_path, /proc/susfs_kstat, /proc/susfs_hide_mounts, ... -
# and it lists ITSELF in /proc/susfs_hide_modules, which removes its own line
# from /proc/modules. Both probes therefore answered "no SUSFS" on every boot,
# the LKM was loaded a second time on top of a live copy, and the kernel
# panicked. Nodes are now matched by name (and /sys/module is trusted because
# hide_modules cannot hide it) instead of by a guess.

LOG=/data/adb/susfs_lkm.log
GUARD=/data/adb/susfs_lkm.guard
DISABLED=/data/adb/susfs_lkm.disabled

log_msg() {
  log -p i -t susfs_lkm "$@" 2>/dev/null
  echo "$(date '+%F %T') $*" >> "$LOG" 2>/dev/null
}

# Rewrite module.prop's description so the KSU manager shows the last result.
update_status() {
  prop="${MODDIR:-.}/module.prop"
  [ -f "$prop" ] || return 0
  desc=$(sed -n 's/^description=//p' "$prop" | head -n1 | sed 's/ *||STATUS:.*$//')
  tmp="$prop.tmp"
  grep -v '^description=' "$prop" > "$tmp" 2>/dev/null || return 0
  printf 'description=%s ||STATUS:%s\n' "$desc" "$1" >> "$tmp"
  mv "$tmp" "$prop"
}

# True when a SUSFS implementation is already live in this kernel.
susfs_present() {
  # 1) the LKM itself. hide_modules can erase it from /proc/modules, but it
  #    cannot remove /sys/module/<name>, so this is the reliable probe.
  [ -d /sys/module/susfs_guard_lkm ] && return 0
  # 2) any control node a SUSFS build creates, whether GKI-internal or via LKM.
  for p in /proc/susfs /proc/susfs_path /proc/susfs_kstat /proc/susfs_mnt_id \
           /proc/susfs_hide_mounts /proc/susfs_hide_modules \
           /proc/susfs_open_redirect /proc/susfs_enable_log /proc/susfs_avc_spoof; do
    [ -e "$p" ] && return 0
  done
  # 3) last resort; may be defeated by hide_modules, hence the checks above.
  grep -q '^susfs_guard_lkm ' /proc/modules 2>/dev/null && return 0
  return 1
}

# uname can already be spoofed by another SUSFS implementation; read the file.
real_kernel_release() {
  cat /proc/sys/kernel/osrelease 2>/dev/null || uname -r
}

# Explicit KMI pin, first non-comment line of $MODDIR/kmi.force (may be empty).
kmi_force_get() {
  [ -s "${MODDIR:-.}/kmi.force" ] || return 0
  sed 's/#.*//' "${MODDIR:-.}/kmi.force" 2>/dev/null | awk 'NF{print $1; exit}'
}

# Guard: remember that a load is about to be attempted; boot-completed clears it.
# If it is still there on the next boot, the load is assumed to have hung the
# device and the module disables itself instead of looping forever.
guard_begin() {
  printf '%s\n' "$(date '+%F %T')" > "$GUARD" 2>/dev/null
  sync
}

guard_abort() { rm -f "$GUARD"; }

# 0 = safe to load, 1 = must stop (already disabled, or just auto-disabled).
guard_check() {
  if [ "${SUSFS_FORCE:-0}" = "1" ]; then
    rm -f "$DISABLED"
    return 0
  fi
  if [ -f "$DISABLED" ]; then
    log_msg "disabled marker present; skip loading"
    update_status "已禁用: 上次加载后未能开机（管理器点“操作”可手动重试）"
    return 1
  fi
  if [ -f "$GUARD" ]; then
    mv -f "$GUARD" "$DISABLED"
    log_msg "previous load never reached boot-completed; auto-disabled to protect boot"
    update_status "已自动禁用: 上次加载后未能开机（管理器点“操作”可手动重试）"
    return 1
  fi
  return 0
}

# load_ko <ko> [module params ...] - returns the loader exit status.
# expose_proc=1 first; if the loader rejects the parameter, retry bare.
load_ko() {
  insmod_bin="$LOADER_DIR/susfs_insmod"
  ko="$1"; shift
  if [ ! -f "$insmod_bin" ]; then
    log_msg "susfs_insmod missing; skip loading"
    return 127
  fi
  chmod 0755 "$insmod_bin" 2>/dev/null
  "$insmod_bin" "$ko" "$@"
  rc=$?
  if [ "$rc" -ne 0 ] && [ "$#" -gt 0 ]; then
    log_msg "susfs_insmod with params failed (exit=$rc); retry without params"
    "$insmod_bin" "$ko"
    rc=$?
  fi
  return $rc
}
