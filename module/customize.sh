#!/system/bin/sh

set_perm "$MODPATH/post-fs-data.sh" 0 0 0755
set_perm "$MODPATH/service.sh" 0 0 0755
set_perm "$MODPATH/apply.sh" 0 0 0755
set_perm "$MODPATH/save_config.sh" 0 0 0755
set_perm "$MODPATH/uninstall.sh" 0 0 0755
set_perm "$MODPATH/tools.sh" 0 0 0755
set_perm "$MODPATH/action.sh" 0 0 0755
set_perm "$MODPATH/bin/memkeep.sh" 0 0 0755
set_perm "$MODPATH/keep_apps.conf" 0 0 0644
set_perm "$MODPATH/app_names.conf" 0 0 0644

# ---- 升级迁移：把上一版里用户调过的设置带过来 ----
# 根管理器更新模块时是「新包覆盖模块目录」，用户改过的 config.conf / keep_apps.conf
# 会被冲掉 —— 每次升级都要重新调一遍，这是之前一直没处理的问题。
# 安装阶段旧目录还没被删，正好在这里合并：
#   · PRESERVE_KEYS 里的键：用户值优先，但每个值都要过一遍合法性校验
#   · 不在表里的键（本版改过语义或默认值的）：一律用新版默认值
# 以后哪个版本的哪个键改了含义，把它从 PRESERVE_KEYS 拿掉即可（拿掉 = 该键回到新版默认值）。
OLD_DIR=/data/adb/modules/memkeep_plus
CONF="$MODPATH/config.conf"
PRESERVE_KEYS="ZRAM_ENABLE ZRAM_SIZE ZRAM_ALGORITHM ZRAM_KEEP_BACKING_DEV KEEP_MODE \
LATE_REAPPLY KEEP_DAEMON VM_CUSTOM AM_CACHE_MAX VM_SWAPPINESS VM_WATERMARK VM_MIN_FREE \
VM_PAGE_CLUSTER VM_DIRTY_RATIO VM_COMPACT VM_MIN_TTL"

valid_cfg() {
  case "$1" in
    ZRAM_ENABLE|ZRAM_KEEP_BACKING_DEV|LATE_REAPPLY|KEEP_DAEMON|VM_CUSTOM)
      case "$2" in true|false) return 0 ;; esac ;;
    KEEP_MODE)
      case "$2" in balanced|strong|max) return 0 ;; esac ;;
    # 与 save_config.sh 的 allowed 列表保持一致，否则迁过来一个 UI 能选、
    # 保存时却被拒的算法（升级后第一次点保存就失败）
    ZRAM_ALGORITHM)
      case "$2" in auto|zstd|lz4|lz4hc|lzo-rle|lzo|deflate|842|lz4kd) return 0 ;; esac ;;
    ZRAM_SIZE)
      case "$2" in
        auto) return 0 ;;
        *G|*g) n=${2%?}
               case "$n" in ''|*[!0-9]*) return 1 ;; esac
               [ "$n" -ge 1 ] && [ "$n" -le 32 ] && return 0 ;;
        *%)    n=${2%\%}
               case "$n" in ''|*[!0-9]*) return 1 ;; esac
               [ "$n" -ge 10 ] && [ "$n" -le 200 ] && return 0 ;;
      esac ;;
    # 数值项的范围与 memkeep.sh 的 cmd_vmsave 保持一致 ——
    # 迁移进来的值必须还能被 write 路径接受，否则重启后写 sysfs 会静默失败。
    # AM_CACHE_MAX=0 是「跟随档位」的哨兵值，config.conf 的默认值就是 0
    AM_CACHE_MAX)    [ "$2" = "0" ] || range_num "$2" 64 1024 && return 0 ;;
    VM_SWAPPINESS)   range_num "$2" 0 200 && return 0 ;;
    VM_WATERMARK)    range_num "$2" 10 400 && return 0 ;;
    VM_MIN_FREE)     range_num "$2" 32768 262144 && return 0 ;;
    VM_PAGE_CLUSTER) range_num "$2" 0 3 && return 0 ;;
    VM_DIRTY_RATIO)  range_num "$2" 5 40 && return 0 ;;
    VM_COMPACT)      range_num "$2" 0 100 && return 0 ;;
    VM_MIN_TTL)      range_num "$2" 0 3000 && return 0 ;;
  esac
  return 1
}

range_num() {
  case "$1" in ''|*[!0-9]*) return 1 ;; esac
  [ "$1" -ge "$2" ] && [ "$1" -le "$3" ] && return 0
  return 1
}

MIG_KEPT=0; MIG_DROP=0; MIG_LIST=0
if [ -f "$OLD_DIR/config.conf" ] && [ -f "$CONF" ]; then
  # 旧配置留一份档，万一迁移出的效果不对，可以直接对照/回滚
  cp -f "$OLD_DIR/config.conf" "$MODPATH/config.conf.old" 2>/dev/null
  chmod 0644 "$MODPATH/config.conf.old" 2>/dev/null
  for k in $PRESERVE_KEYS; do
    grep -q "^$k=" "$CONF" 2>/dev/null || continue          # 本版已废弃的键不迁移
    ov=$(sed -n "s/^$k=//p" "$OLD_DIR/config.conf" 2>/dev/null | tail -n 1)
    [ -n "$ov" ] || continue
    if valid_cfg "$k" "$ov"; then
      sed "s|^$k=.*|$k=$ov|" "$CONF" > "$CONF.tmp" 2>/dev/null && mv "$CONF.tmp" "$CONF"
      MIG_KEPT=$((MIG_KEPT + 1))
    else
      MIG_DROP=$((MIG_DROP + 1))
    fi
  done
fi
chmod 0644 "$CONF" 2>/dev/null

# 保活名单是纯用户数据，整份带过来
if [ -f "$OLD_DIR/keep_apps.conf" ]; then
  cp -f "$OLD_DIR/keep_apps.conf" "$MODPATH/keep_apps.conf" 2>/dev/null
  chmod 0644 "$MODPATH/keep_apps.conf" 2>/dev/null
  MIG_LIST=$(grep -vcE '^[[:space:]]*(#|$)' "$MODPATH/keep_apps.conf" 2>/dev/null)
  case "$MIG_LIST" in ''|*[!0-9]*) MIG_LIST=0 ;; esac
fi

# 用户自定义的应用显示名同样是纯用户数据，不能因为升级就丢
if [ -f "$OLD_DIR/app_names.conf" ]; then
  cp -f "$OLD_DIR/app_names.conf" "$MODPATH/app_names.conf" 2>/dev/null
  chmod 0644 "$MODPATH/app_names.conf" 2>/dev/null
  MIG_NAMES=$(grep -vcE '^[[:space:]]*(#|$)' "$MODPATH/app_names.conf" 2>/dev/null)
  case "$MIG_NAMES" in ''|*[!0-9]*) MIG_NAMES=0 ;; esac
fi

ui_print "- MemKeep++"
ui_print "- 机型: $(getprop ro.product.model) ($(getprop ro.product.device))"
ui_print "- 系统: Android $(getprop ro.build.version.release) / SDK $(getprop ro.build.version.sdk)"
ui_print "- 内核: $(uname -r)"

# 识别当前 root 管理器，给出对应的使用提示。
# 模块本体在所有管理器上行为一致，差异只在「图标界面怎么打开」。
ROOT_NAME="unknown"
if [ -d /data/adb/ksu ]; then
  ROOT_NAME="KernelSU"
  [ -d /data/adb/modules/susfs4ksu ] && ROOT_NAME="KernelSU (检测到 susfs)"
elif [ -d /data/adb/ap ]; then
  ROOT_NAME="APatch"
elif [ -d /data/adb/magisk ]; then
  ROOT_NAME="Magisk"
fi
ui_print "- Root 管理器: $ROOT_NAME"

# 硬件能力探测：zram 与压缩算法决定这台机能不能用上核心功能
if [ -d /sys/block/zram0 ]; then
  ALG="$(cat /sys/block/zram0/comp_algorithm 2>/dev/null)"
  ui_print "- ZRAM: 可用"
  [ -n "$ALG" ] && ui_print "- 压缩算法: $ALG"
else
  ui_print "- ZRAM: 未检测到 /sys/block/zram0，压缩功能将不可用"
fi

SDK="$(getprop ro.build.version.sdk)"
if [ "$SDK" -lt 33 ] 2>/dev/null; then
  ui_print "- 提示: 本模块按 Android 13+ 的参数集调试，低版本部分参数可能不存在（会自动跳过）"
fi

ui_print "- 配置: $MODPATH/config.conf"
ui_print "- 保活名单: $MODPATH/keep_apps.conf"
case "$ROOT_NAME" in
  Magisk*)
    ui_print "- 图形界面需要额外安装 KsuWebUI Standalone 或 MMRL"
    ui_print "- 不装也能用：点模块的动作按钮可查看状态，配置照常开机生效"
    ;;
  *)
    ui_print "- 图形界面: 模块列表 → MemKeep++ → 打开"
    ;;
esac
# 安装时把系统原值存一份，卸载或点「恢复原厂」时用来还原。
# 这一步必须在模块自己的 service 跑之前执行，这里正是最干净的时机。
# 升级时必须沿用旧快照：否则会把「模块自己已经改过的值」当成原厂值记下来，
# 之后点「恢复系统原值」等于把模块的调参固化进系统 —— 比不还原更糟。
SNAP="$MODPATH/system_snapshot.conf"
if [ -f "$OLD_DIR/system_snapshot.conf" ]; then
  cp -f "$OLD_DIR/system_snapshot.conf" "$SNAP" 2>/dev/null
  chmod 0644 "$SNAP" 2>/dev/null
  ui_print "- 沿用上次的系统原值快照（升级不会把模块改过的值当成原厂值）"
else
{
  # watermark_boost_factor / dirtytime_expire_seconds 由 tools.sh 的 apply_vm_common 写入，
  # 快照里不记的话「恢复系统原值」会漏掉这两项。
  for k in swappiness watermark_scale_factor min_free_kbytes page-cluster \
           dirty_ratio dirty_background_ratio compaction_proactiveness overcommit_memory \
           watermark_boost_factor dirtytime_expire_seconds; do
    v=$(cat "/proc/sys/vm/$k" 2>/dev/null)
    [ -n "$v" ] && echo "$k=$v"
  done
  v=$(cat /sys/block/zram0/disksize 2>/dev/null)
  [ -n "$v" ] && echo "zram_disksize=$v"
  v=$(sed -n 's/.*\[\(.*\)\].*/\1/p' /sys/block/zram0/comp_algorithm 2>/dev/null)
  [ -n "$v" ] && echo "zram_algorithm=$v"
  v=$(device_config get activity_manager max_cached_processes 2>/dev/null)
  [ -n "$v" ] && [ "$v" != "null" ] && echo "am_cache_max=$v"
  v=$(device_config get activity_manager min_cached_processes 2>/dev/null)
  [ -n "$v" ] && [ "$v" != "null" ] && echo "am_min_cached=$v"
  # lmkd 阈值：三档都基于这几个原厂值做偏移，必须原样记下来
  for k in ro.lmk.psi_partial_stall_ms ro.lmk.psi_complete_stall_ms \
           ro.lmk.swap_free_low_percentage ro.lmk.swap_util_max; do
    v=$(getprop "$k" 2>/dev/null)
    [ -n "$v" ] && echo "$k=$v"
  done
  v=$(device_config get activity_manager_native_boot use_freezer 2>/dev/null)
  [ -n "$v" ] && echo "use_freezer=$v"
  # 本模块会写的那批 persist 属性：原厂有值就记下来（还原时写回），
  # 没记到就意味着原厂本来没有这一项（还原时删掉我们加的）。
  for k in persist.sys.preload.enable persist.sys.precache.enable \
           persist.device_config.activity_manager.use_compaction \
           persist.device_config.mglru_native.lru_gen_config \
           persist.device_config.lmkd_native.use_minfree_levels \
           persist.sys.miui_bg_apps_limit persist.sys.mms.bg_apps_limit; do
    v=$(getprop "$k" 2>/dev/null)
    [ -n "$v" ] && echo "$k=$v"
  done
} > "$SNAP" 2>/dev/null
chmod 0644 "$SNAP" 2>/dev/null
ui_print "- 已记录系统原值快照，可一键恢复"
fi

if [ -f "$OLD_DIR/config.conf" ]; then
  ui_print "- 升级：已保留 $MIG_KEPT 项上次的设置，保活名单 $MIG_LIST 个应用"
  [ "${MIG_NAMES:-0}" -gt 0 ] 2>/dev/null && ui_print "- 已保留 $MIG_NAMES 个自定义应用名"
  [ "$MIG_DROP" -gt 0 ] && ui_print "- 其中 $MIG_DROP 项取值不合法，已重置为新版默认值"
  [ -f "$MODPATH/config.conf.old" ] && ui_print "- 旧配置留档: config.conf.old"
else
  ui_print "- 首次安装，使用默认配置"
fi

ui_print "- 安装完成，重启后生效"
