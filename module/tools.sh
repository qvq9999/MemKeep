#!/system/bin/sh

MODDIR=${0%/*}
CONFIG="$MODDIR/config.conf"
LOG="$MODDIR/memkeep.log"

log_msg() {
  if [ -f "$LOG" ] && [ "$(wc -c < "$LOG")" -gt 65536 ]; then
    tail -n 100 "$LOG" > "$LOG.tmp" && mv "$LOG.tmp" "$LOG"
  fi
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOG"
}

load_config() {
  ZRAM_ENABLE=true
  ZRAM_SIZE=auto
  ZRAM_ALGORITHM=auto
  ZRAM_KEEP_BACKING_DEV=true
  KEEP_MODE=strong
  LATE_REAPPLY=true
  KEEP_DAEMON=true

  [ -f "$CONFIG" ] && . "$CONFIG"
}

write_file() {
  local value="$1"
  local path="$2"

  [ -e "$path" ] || return 1
  chmod 0644 "$path" 2>/dev/null
  echo "$value" > "$path" 2>/dev/null
}

resetprop_safe() {
  local key="$1"
  local value="$2"

  if command -v resetprop >/dev/null 2>&1; then
    resetprop "$key" "$value" >/dev/null 2>&1
  else
    setprop "$key" "$value" >/dev/null 2>&1
  fi
}

mem_total_kb() {
  awk '/MemTotal/ {print $2; exit}' /proc/meminfo
}

calc_zram_bytes() {
  local total_kb="$1"
  local total_bytes size pct

  total_bytes=$((total_kb * 1024))

  case "$ZRAM_SIZE" in
    auto)
      size="$total_bytes"
      [ "$size" -lt $((8 * 1024 * 1024 * 1024)) ] && size=$((8 * 1024 * 1024 * 1024))
      [ "$size" -gt $((16 * 1024 * 1024 * 1024)) ] && size=$((16 * 1024 * 1024 * 1024))
      echo "$size"
      ;;
    *%)
      pct="${ZRAM_SIZE%\%}"
      case "$pct" in
        ''|*[!0-9*]|0*) echo "$total_bytes" ;;
        *) size=$((total_bytes * pct / 100)); [ "$size" -lt 1073741824 ] && size=1073741824; echo "$size" ;;
      esac
      ;;
    *G|*g)
      size="${ZRAM_SIZE%G}"
      size="${size%g}"
      case "$size" in
        ''|*[!0-9]*) echo "$total_bytes" ;;
        *) echo $((size * 1024 * 1024 * 1024)) ;;
      esac
      ;;
    *)
      echo "$total_bytes"
      ;;
  esac
}

choose_zram_algorithm() {
  local available alg

  [ -f /sys/block/zram0/comp_algorithm ] || return 1
  available="$(cat /sys/block/zram0/comp_algorithm)"

  if [ "$ZRAM_ALGORITHM" != "auto" ]; then
    echo "$available" | grep -qw "$ZRAM_ALGORITHM" && {
      echo "$ZRAM_ALGORITHM"
      return 0
    }
    log_msg "configured zram algorithm unsupported: $ZRAM_ALGORITHM"
    return 1
  fi

  for alg in zstd lz4 lzo-rle lzo; do
    echo "$available" | grep -qw "$alg" && {
      echo "$alg"
      return 0
    }
  done

  return 1
}

apply_zram() {
  local size_bytes alg backing_dev

  [ "$ZRAM_ENABLE" = "true" ] || {
    log_msg "zram disabled by config"
    return 0
  }

  [ -d /sys/block/zram0 ] || {
    log_msg "zram0 not found"
    return 1
  }

  size_bytes="$(calc_zram_bytes "$(mem_total_kb)")"
  alg="$(choose_zram_algorithm)"
  backing_dev="$(cat /sys/block/zram0/backing_dev 2>/dev/null)"

  swapoff /dev/block/zram0 >/dev/null 2>&1
  write_file 1 /sys/block/zram0/reset

  [ -n "$alg" ] && write_file "$alg" /sys/block/zram0/comp_algorithm

  if [ "$ZRAM_KEEP_BACKING_DEV" = "true" ] && [ -n "$backing_dev" ] && [ "$backing_dev" != "none" ]; then
    write_file "$backing_dev" /sys/block/zram0/backing_dev
  fi

  write_file "$size_bytes" /sys/block/zram0/disksize
  mkswap /dev/block/zram0 >/dev/null 2>&1
  if swapon /dev/block/zram0 >/dev/null 2>&1; then
    log_msg "zram applied: size=${size_bytes}, algorithm=${alg:-kernel-default}"
  else
    log_msg "zram swapon FAILED: size=${size_bytes}, algorithm=${alg:-kernel-default}"
    return 1
  fi
}

apply_vm_tuning() {
  local total_kb min_free

  total_kb="$(mem_total_kb)"
  min_free=$((total_kb / 256))
  [ "$min_free" -lt 65536 ] && min_free=65536
  [ "$min_free" -gt 131072 ] && min_free=131072

  case "$KEEP_MODE" in
    balanced)
      write_file 80 /proc/sys/vm/swappiness
      write_file 10 /proc/sys/vm/compaction_proactiveness
      write_file 0 /proc/sys/vm/page-cluster
      write_file "$min_free" /proc/sys/vm/min_free_kbytes
      write_file 100 /proc/sys/vm/watermark_scale_factor
      write_file 5 /proc/sys/vm/dirty_background_ratio
      write_file 15 /proc/sys/vm/dirty_ratio
      ;;
    max)
      write_file 120 /proc/sys/vm/swappiness
      write_file 20 /proc/sys/vm/compaction_proactiveness
      write_file 0 /proc/sys/vm/page-cluster
      write_file "$min_free" /proc/sys/vm/min_free_kbytes
      write_file 75 /proc/sys/vm/watermark_scale_factor
      write_file 5 /proc/sys/vm/dirty_background_ratio
      write_file 20 /proc/sys/vm/dirty_ratio
      ;;
    *)
      write_file 100 /proc/sys/vm/swappiness
      write_file 15 /proc/sys/vm/compaction_proactiveness
      write_file 0 /proc/sys/vm/page-cluster
      write_file "$min_free" /proc/sys/vm/min_free_kbytes
      write_file 90 /proc/sys/vm/watermark_scale_factor
      write_file 5 /proc/sys/vm/dirty_background_ratio
      write_file 18 /proc/sys/vm/dirty_ratio
      ;;
  esac

  write_file 1 /proc/sys/vm/watermark_boost_factor
  write_file 1 /proc/sys/vm/overcommit_memory
  write_file 3600 /proc/sys/vm/dirtytime_expire_seconds

  log_msg "vm tuning applied: mode=$KEEP_MODE min_free_kbytes=$min_free"
}

apply_background_retention() {
  case "$KEEP_MODE" in
    balanced)
      device_config put activity_manager max_cached_processes 128 >/dev/null 2>&1
      device_config put activity_manager max_phantom_processes 128 >/dev/null 2>&1
      ;;
    max)
      device_config put activity_manager max_cached_processes 384 >/dev/null 2>&1
      device_config put activity_manager max_phantom_processes 384 >/dev/null 2>&1
      ;;
    *)
      device_config put activity_manager max_cached_processes 256 >/dev/null 2>&1
      device_config put activity_manager max_phantom_processes 256 >/dev/null 2>&1
      ;;
  esac

  device_config put activity_manager use_compaction true >/dev/null 2>&1
  device_config put mglru_native lru_gen_config all >/dev/null 2>&1

  resetprop_safe persist.device_config.activity_manager.use_compaction true
  resetprop_safe persist.device_config.mglru_native.lru_gen_config all
  if [ -n "$(getprop ro.miui.ui.version.name)" ]; then
    resetprop_safe persist.sys.miui_bg_apps_limit 256
    resetprop_safe persist.sys.mms.bg_apps_limit 256
  fi
  resetprop_safe persist.sys.preload.enable false
  resetprop_safe persist.sys.precache.enable false

  log_msg "background retention applied: mode=$KEEP_MODE"
}

apply_lmk_props() {
  resetprop_safe ro.lmk.use_psi 1
  resetprop_safe ro.lmk.use_new_strategy 1
  resetprop_safe ro.lmk.psi_partial_stall_ms 120
  resetprop_safe ro.lmk.psi_complete_stall_ms 900
  resetprop_safe ro.lmk.swap_free_low_percentage 5
  resetprop_safe ro.lmk.swap_util_max 95
  resetprop_safe persist.device_config.lmkd_native.use_minfree_levels false
  log_msg "lmk props applied"
}

wait_boot_completed() {
  local waited=0
  until [ "$(getprop sys.boot_completed)" = "1" ]; do
    sleep 2
    waited=$((waited + 2))
    [ "$waited" -ge 300 ] && {
      log_msg "boot wait timeout after ${waited}s, proceeding anyway"
      return 1
    }
  done
}
