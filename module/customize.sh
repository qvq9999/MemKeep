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
SNAP="$MODPATH/system_snapshot.conf"
{
  for k in swappiness watermark_scale_factor min_free_kbytes page-cluster \
           dirty_ratio dirty_background_ratio compaction_proactiveness overcommit_memory; do
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
} > "$SNAP" 2>/dev/null
chmod 0644 "$SNAP" 2>/dev/null
ui_print "- 已记录系统原值快照，可一键恢复"

ui_print "- 安装完成，重启后生效"
