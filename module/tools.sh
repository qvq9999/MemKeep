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
  # VM 手动覆盖：VM_CUSTOM=true 时忽略上面的档位预设，直接用下面这组值
  VM_CUSTOM=false
  VM_SWAPPINESS=110
  VM_WATERMARK=125
  VM_MIN_FREE=0
  VM_PAGE_CLUSTER=0
  VM_DIRTY_RATIO=20
  VM_COMPACT=25
  # MGLRU 工作集保护：最近多少毫秒访问过的页不淘汰。0 = 关闭
  VM_MIN_TTL=0
  AM_CACHE_MAX=0

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

# zram 的块设备节点在不同 ROM/内核上位置不一样：
#   大多数设备是 /dev/block/zram0，少数只导出 /dev/zram0。
# 直接写死会让 swapoff/mkswap/swapon 全部失败 —— 这是最典型的跨品牌兼容问题。
zram_dev() {
  for d in /dev/block/zram0 /dev/zram0 /dev/block/zram/zram0; do
    [ -e "$d" ] && { echo "$d"; return 0; }
  done
  # 都找不到时按常见路径返回，让上层的错误日志有据可查
  echo /dev/block/zram0
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
  local size_bytes alg backing_dev dev

  [ "$ZRAM_ENABLE" = "true" ] || {
    log_msg "zram disabled by config"
    return 0
  }

  [ -d /sys/block/zram0 ] || {
    log_msg "zram0 not found"
    return 1
  }

  dev="$(zram_dev)"
  size_bytes="$(calc_zram_bytes "$(mem_total_kb)")"
  alg="$(choose_zram_algorithm)"
  backing_dev="$(cat /sys/block/zram0/backing_dev 2>/dev/null)"

  swapoff "$dev" >/dev/null 2>&1
  write_file 1 /sys/block/zram0/reset

  [ -n "$alg" ] && write_file "$alg" /sys/block/zram0/comp_algorithm

  if [ "$ZRAM_KEEP_BACKING_DEV" = "true" ] && [ -n "$backing_dev" ] && [ "$backing_dev" != "none" ]; then
    write_file "$backing_dev" /sys/block/zram0/backing_dev
  fi

  write_file "$size_bytes" /sys/block/zram0/disksize
  mkswap "$dev" >/dev/null 2>&1
  if swapon "$dev" >/dev/null 2>&1; then
    log_msg "zram applied: dev=$dev size=${size_bytes}, algorithm=${alg:-kernel-default}"
  else
    log_msg "zram swapon FAILED: dev=$dev size=${size_bytes}, algorithm=${alg:-kernel-default}"
    return 1
  fi
}

# ---------- 原厂基准 ----------
# 三档都基于「安装时快照下来的原厂值」做偏移，而不是硬编码绝对值。
# 各家 ROM 的 lmkd 阈值与 max_cached_processes 差得很远，
# 写死会出现「均衡档比某品牌的原厂设置还激进」这种事。
SNAP="$MODDIR/system_snapshot.conf"

orig_of() {
  local key="$1" fallback="$2" v=""
  [ -f "$SNAP" ] && v=$(grep "^$key=" "$SNAP" 2>/dev/null | head -n 1 | cut -d= -f2-)
  case "$v" in
    ''|null|*[!0-9]*) v="$fallback" ;;
  esac
  echo "$v"
}

# 按百分比缩放：scale 基准 百分比
scale() {
  echo $(( ($1 * $2) / 100 ))
}

# ---------- MGLRU 工作集保护 ----------
# /sys/kernel/mm/lru_gen/min_ttl_ms 写 N 表示「最近 N 毫秒访问过的页不许淘汰」。
# 这是内核里唯一按时间保护工作集的旋钮，直接决定「切回应用要不要重读」。
# 代价：内存真的不够时，内核会干脆杀掉整个应用，而不是让页面来回抖动。
# 不去强开 MGLRU 主开关 —— 厂商把它关掉（0x0000）通常有原因。
apply_mglru() {
  local ttl="$1" cur
  [ -d /sys/kernel/mm/lru_gen ] || { log_msg "mglru: not supported"; return 0; }

  cur=$(cat /sys/kernel/mm/lru_gen/enabled 2>/dev/null)
  if [ "$cur" = "0x0000" ] || [ -z "$cur" ]; then
    log_msg "mglru: disabled by vendor ($cur), skip min_ttl"
    return 0
  fi

  case "$ttl" in ''|*[!0-9]*) ttl=0 ;; esac
  write_file "$ttl" /sys/kernel/mm/lru_gen/min_ttl_ms
  log_msg "mglru: min_ttl_ms=$ttl"
}

apply_vm_tuning() {
  local total_kb min_free sw wm cp mf_div ttl zdisk

  total_kb="$(mem_total_kb)"
  [ -n "$total_kb" ] && [ "$total_kb" -gt 0 ] 2>/dev/null || total_kb=4194304

  if [ "$VM_CUSTOM" = "true" ]; then
    # 手动覆盖：用户在 WebUI 里逐项调过，优先于档位预设。
    # min_free_kbytes 没改过（0）时仍按档位算。
    mf_div=256
    min_free=$((total_kb / mf_div))
    [ "$min_free" -lt 32768 ] && min_free=32768
    [ "$min_free" -gt 163840 ] && min_free=163840

    local mf="${VM_MIN_FREE:-0}"
    [ "$mf" -gt 0 ] 2>/dev/null || mf="$min_free"
    write_file "${VM_SWAPPINESS:-110}" /proc/sys/vm/swappiness
    write_file "${VM_COMPACT:-25}" /proc/sys/vm/compaction_proactiveness
    write_file "${VM_PAGE_CLUSTER:-0}" /proc/sys/vm/page-cluster
    write_file "$mf" /proc/sys/vm/min_free_kbytes
    write_file "${VM_WATERMARK:-125}" /proc/sys/vm/watermark_scale_factor
    write_file 5 /proc/sys/vm/dirty_background_ratio
    write_file "${VM_DIRTY_RATIO:-20}" /proc/sys/vm/dirty_ratio
    apply_mglru "${VM_MIN_TTL:-0}"
    log_msg "vm tuning applied: mode=custom swappiness=$VM_SWAPPINESS watermark=$VM_WATERMARK min_free=$mf ttl=${VM_MIN_TTL:-0}"
    apply_vm_common
    return 0
  fi

  # 档位表。注意 watermark 的方向：值越大 = 越早开始后台回收 =
  # 越不容易走到「内存不够只能杀进程」那一步，所以保活强度越高，这个值应该越大。
  # 之前 100/90/75 是反的（选极限反而比原厂更紧），这里纠正过来。
  case "$KEEP_MODE" in
    balanced) sw=90;  wm=100; mf_div=512; cp=10; ttl=0    ;;
    max)      sw=130; wm=150; mf_div=192; cp=40; ttl=2000 ;;
    *)        sw=110; wm=125; mf_div=256; cp=25; ttl=1000 ;;
  esac

  # min_free_kbytes = 物理内存 / 除数
  min_free=$((total_kb / mf_div))
  [ "$min_free" -lt 32768 ]  && min_free=32768
  [ "$min_free" -gt 163840 ] && min_free=163840

  # swappiness 130 只在 zram 足够大时用。zram < 1.5 倍物理内存时，
  # 130 会把解压开销和 CPU 占用顶上来，收益却很小 —— 退回 110。
  if [ "$sw" -ge 130 ]; then
    zdisk=$(cat /sys/block/zram0/disksize 2>/dev/null)
    case "$zdisk" in ''|*[!0-9]*) zdisk=0 ;; esac
    if [ "$zdisk" -lt $((total_kb * 1024 * 3 / 2)) ]; then
      sw=110
      log_msg "vm tuning: zram smaller than 1.5x RAM, swappiness capped at 110"
    fi
  fi

  write_file "$sw"  /proc/sys/vm/swappiness
  write_file "$wm"  /proc/sys/vm/watermark_scale_factor
  write_file "$cp"  /proc/sys/vm/compaction_proactiveness
  write_file 0      /proc/sys/vm/page-cluster
  write_file "$min_free" /proc/sys/vm/min_free_kbytes
  write_file 5      /proc/sys/vm/dirty_background_ratio
  # dirty_ratio 与「后台留存」无关，只影响写盘阻塞。三档给不同值纯属噪音，统一 20。
  write_file 20     /proc/sys/vm/dirty_ratio

  apply_mglru "$ttl"
  log_msg "vm tuning applied: mode=$KEEP_MODE swappiness=$sw watermark=$wm compaction=$cp min_free=$min_free ttl=$ttl"
  apply_vm_common
}

# 三档与自定义共用的收尾参数
apply_vm_common() {
  write_file 1 /proc/sys/vm/watermark_boost_factor
  write_file 1 /proc/sys/vm/overcommit_memory
  write_file 3600 /proc/sys/vm/dirtytime_expire_seconds
}

apply_background_retention() {
  local fac maxc minc

  # 缓存进程上限同样跟随原厂值，而不是写死 128/256/384。
  # AOSP 在高内存机器上默认就很大（部分 ROM 是 512），
  # 写死 384 等于把某些机器的上限调低了。
  fac=$(orig_of am_cache_max 512)
  case "$KEEP_MODE" in
    balanced) maxc=$fac ;;
    max)      maxc=$((fac * 2)) ;;
    *)        maxc=$(scale "$fac" 150) ;;
  esac
  # 手动覆盖优先
  if [ "${AM_CACHE_MAX:-0}" -gt 0 ] 2>/dev/null; then
    maxc=$AM_CACHE_MAX
  fi
  [ "$maxc" -gt 1024 ] && maxc=1024
  [ "$maxc" -lt 64 ]   && maxc=64
  minc=$((maxc / 2))
  [ "$minc" -lt 32 ] && minc=32

  device_config put activity_manager max_cached_processes "$maxc" >/dev/null 2>&1
  device_config put activity_manager max_phantom_processes "$maxc" >/dev/null 2>&1
  # 只有上限没有下限时，系统可以把缓存清到接近 0；给一个保底值。
  device_config put activity_manager min_cached_processes "$minc" >/dev/null 2>&1

  device_config put activity_manager use_compaction true >/dev/null 2>&1
  device_config put mglru_native lru_gen_config all >/dev/null 2>&1

  resetprop_safe persist.device_config.activity_manager.use_compaction true
  resetprop_safe persist.device_config.mglru_native.lru_gen_config all
  if [ -n "$(getprop ro.miui.ui.version.name)" ]; then
    resetprop_safe persist.sys.miui_bg_apps_limit "$maxc"
    resetprop_safe persist.sys.mms.bg_apps_limit "$maxc"
  fi
  resetprop_safe persist.sys.preload.enable false
  resetprop_safe persist.sys.precache.enable false

  log_msg "retention applied: mode=$KEEP_MODE factory=$fac max_cached=$maxc min_cached=$minc"
}

# LMKD 阈值分层。
# 这一段是整个保活里最容易被忽略的：lmkd 才是真正执行击杀的进程，
# 而它的阈值之前三档完全一样 —— 等于「极限」档在 LMKD 层面和「均衡」没差别。
# 现在按原厂值做比例偏移，保活越强，越晚动手。
apply_lmk_props() {
  local p c sfl sumax fac np ns

  p=$(orig_of ro.lmk.psi_partial_stall_ms 70)
  c=$(orig_of ro.lmk.psi_complete_stall_ms 700)
  sfl=$(orig_of ro.lmk.swap_free_low_percentage 10)
  sumax=$(orig_of ro.lmk.swap_util_max 100)

  if [ "$VM_CUSTOM" = "true" ]; then
    fac=130
    [ "$sfl" -gt 7 ]  && sfl=7
    [ "$sumax" -gt 95 ] && sumax=95
  else
    case "$KEEP_MODE" in
      balanced) fac=100; [ "$sumax" -gt 90 ] && sumax=90 ;;
      max)      fac=180; [ "$sfl" -gt 5 ] && sfl=5;  [ "$sumax" -gt 98 ] && sumax=98 ;;
      *)        fac=130; [ "$sfl" -gt 7 ] && sfl=7;  [ "$sumax" -gt 95 ] && sumax=95 ;;
    esac
  fi

  np=$(scale "$p" "$fac")
  ns=$(scale "$c" "$fac")

  resetprop_safe ro.lmk.use_psi 1
  resetprop_safe ro.lmk.use_new_strategy 1
  resetprop_safe ro.lmk.psi_partial_stall_ms "$np"
  resetprop_safe ro.lmk.psi_complete_stall_ms "$ns"
  resetprop_safe ro.lmk.swap_free_low_percentage "$sfl"
  resetprop_safe ro.lmk.swap_util_max "$sumax"
  resetprop_safe persist.device_config.lmkd_native.use_minfree_levels false

  # 这几个是 ro.* 属性，lmkd 启动时读一次。写在 post-fs-data 里能赶上，
  # 但运行期改档位必须重启才生效 —— 界面上要如实标注。
  log_msg "lmk tuning: mode=$KEEP_MODE partial=${np}ms complete=${ns}ms swap_free_low=$sfl swap_util_max=$sumax"
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
