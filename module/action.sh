#!/system/bin/sh
#
# 动作按钮。KernelSU / APatch 里点模块卡片上的「打开」会走到 WebUI；
# Magisk 没有内置 WebUI，点动作按钮执行的就是这个脚本 —— 所以这里主要做两件事：
#   1. 把当前状态打出来，让 Magisk 用户不开图形界面也能确认模块在干活
#   2. 告诉他怎么才能用上图形界面

MODDIR=${0%/*}
[ "$MODDIR" = "$0" ] && MODDIR=.
CONFIG="$MODDIR/config.conf"
KEEP="$MODDIR/keep_apps.conf"
BIN="$MODDIR/bin/memkeep.sh"

echo "MemKeep++ · 状态"
echo "----------------------------------------"

# 内存概要
if [ -f "$BIN" ]; then
  sh "$BIN" mem 2>/dev/null | while IFS='=' read -r k v; do
    case "$k" in
      total)     [ "$v" -gt 0 ] 2>/dev/null && echo "物理内存   : $((v / 1024)) MB" ;;
      avail)     [ "$v" -ge 0 ] 2>/dev/null && echo "可用       : $((v / 1024)) MB" ;;
      swaptotal) [ "$v" -gt 0 ] 2>/dev/null && echo "交换总量   : $((v / 1024)) MB" ;;
      swapfree)  [ "$v" -ge 0 ] 2>/dev/null && echo "交换剩余   : $((v / 1024)) MB" ;;
      zram_alg)  [ -n "$v" ] && echo "zram 算法  : $v" ;;
    esac
  done
fi

# 关键参数实际值
echo "----------------------------------------"
echo "swappiness : $(cat /proc/sys/vm/swappiness 2>/dev/null)"
echo "水位系数   : $(cat /proc/sys/vm/watermark_scale_factor 2>/dev/null)"
echo "min_free   : $(cat /proc/sys/vm/min_free_kbytes 2>/dev/null)"
echo "缓存进程上限: $(device_config get activity_manager max_cached_processes 2>/dev/null)"

# 保活名单
echo "----------------------------------------"
if [ -f "$KEEP" ] && grep -qv '^[[:space:]]*#' "$KEEP" 2>/dev/null; then
  echo "保活名单："
  grep -v '^[[:space:]]*#' "$KEEP" 2>/dev/null | grep -v '^[[:space:]]*$' | sed 's/^/  /'
else
  echo "保活名单：空"
fi

echo "----------------------------------------"
echo "最近日志："
if [ -f "$MODDIR/memkeep.log" ]; then
  tail -n 15 "$MODDIR/memkeep.log"
else
  echo "  暂无日志，安装后重启一次会生成。"
fi

echo
echo "如何打开图形界面："
if [ -d /data/adb/ksu ]; then
  echo "  KernelSU：模块 → MemKeep++ → 打开"
elif [ -d /data/adb/ap ]; then
  echo "  APatch：模块 → MemKeep++ → 打开"
else
  echo "  当前是 Magisk，Magisk 本身没有 WebUI。任选其一："
  echo "   · 安装 KsuWebUI Standalone，从里面打开 MemKeep++"
  echo "   · 安装 MMRL（WebUI X），同样可以加载本模块页面"
  echo "  两不装也不影响功能 —— 配置照常按 config.conf 在开机时生效。"
fi
