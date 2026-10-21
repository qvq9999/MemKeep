#!/system/bin/sh

clear_device_config() {
  device_config delete "$1" "$2" >/dev/null 2>&1
  device_config clear_override "$1" "$2" >/dev/null 2>&1
}

clear_device_config activity_manager max_cached_processes
clear_device_config activity_manager max_phantom_processes
# min_cached_processes 由 tools.sh 的 apply_background_retention 写入，原来漏了没清
clear_device_config activity_manager min_cached_processes
clear_device_config activity_manager use_compaction
clear_device_config mglru_native lru_gen_config

if command -v resetprop >/dev/null 2>&1; then
  resetprop --delete ro.lmk.use_psi >/dev/null 2>&1
  resetprop --delete ro.lmk.use_new_strategy >/dev/null 2>&1
  resetprop --delete ro.lmk.psi_partial_stall_ms >/dev/null 2>&1
  resetprop --delete ro.lmk.psi_complete_stall_ms >/dev/null 2>&1
  resetprop --delete ro.lmk.swap_free_low_percentage >/dev/null 2>&1
  resetprop --delete ro.lmk.swap_util_max >/dev/null 2>&1
  resetprop -p --delete persist.device_config.activity_manager.use_compaction >/dev/null 2>&1
  resetprop -p --delete persist.device_config.activity_manager.min_cached_processes >/dev/null 2>&1
  resetprop -p --delete persist.device_config.mglru_native.lru_gen_config >/dev/null 2>&1
  resetprop -p --delete persist.device_config.lmkd_native.use_minfree_levels >/dev/null 2>&1
  resetprop -p --delete persist.sys.miui_bg_apps_limit >/dev/null 2>&1
  resetprop -p --delete persist.sys.mms.bg_apps_limit >/dev/null 2>&1
  resetprop -p --delete persist.sys.preload.enable >/dev/null 2>&1
  resetprop -p --delete persist.sys.precache.enable >/dev/null 2>&1
fi

# 撤销保活时写进系统的 standby bucket 与 Doze 白名单，
# 否则卸载后这些应用仍被系统特殊对待。
LIST="$MODDIR/keep_apps.conf"
if [ -f "$LIST" ]; then
  grep -v '^[[:space:]]*#' "$LIST" 2>/dev/null | grep -v '^[[:space:]]*$' | while read -r pkg _tier; do
    [ -n "$pkg" ] || continue
    cmd deviceidle whitelist "-$pkg" >/dev/null 2>&1
    am set-standby-bucket "$pkg" working_set >/dev/null 2>&1
  done
fi

rm -f "$MODDIR/guard.pid" "$MODDIR/system_snapshot.conf" 2>/dev/null
