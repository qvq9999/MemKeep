#!/system/bin/sh
# MemKeep++ WebUI 后端
#
# 所有子命令都只输出「纯文本 / TSV」，解析交给前端，避免在 JS 里拼长 shell 命令。
#
#   memkeep.sh mem              内存概要        key=value 每行
#   memkeep.sh procs [N]        进程列表        pid uid adj rss_kb name（按 RSS 降序，默认 40）
#   memkeep.sh kill <pid>       停止进程        OK / REFUSE_SYSTEM / REFUSE_INVALID / FAIL
#   memkeep.sh keep list        保活名单        pkg tier
#   memkeep.sh keep set <pkg> <tier>  写入名单（tier: critical|restartable|off）
#   memkeep.sh keep apply       把名单写成 oom_score_adj
#   memkeep.sh keep guard       守护循环（阻塞，由 service.sh 后台拉起）

# 模块根目录 = 本脚本所在 bin/ 的上一级。
# 用 case 判断层级，比反复 ${0%/*} 更可靠（相对路径调用时也能算对）。
case "$0" in
  */*/*) MODDIR=$(cd "${0%/*}/.." 2>/dev/null && pwd) ;;
  */*)   MODDIR=$(cd "${0%/*}/.." 2>/dev/null && pwd) ;;
  *)     MODDIR=$(pwd) ;;
esac
[ -d "$MODDIR" ] || MODDIR=${0%/*}
LIST="$MODDIR/keep_apps.conf"
CONFIG="$MODDIR/config.conf"

# 就地改一个键，注释和其它键原样保留（和 save_config.sh 同一套思路）
set_conf_kv() {
  key="$1"
  value="$2"
  [ -f "$CONFIG" ] || : > "$CONFIG"
  if grep -q "^${key}=" "$CONFIG" 2>/dev/null; then
    sed "s|^${key}=.*|${key}=${value}|" "$CONFIG" > "$CONFIG.n" && mv "$CONFIG.n" "$CONFIG"
  else
    printf '%s=%s\n' "$key" "$value" >> "$CONFIG"
  fi
  chmod 0644 "$CONFIG" 2>/dev/null
}

# 两级保护，对齐 OomAdjuster 的做法：
#   critical    -1000  内核 OOM killer 不会动它
#   restartable -999   极端内存压力下仍可能被杀，可接受
score_of() {
  case "$1" in
    critical) echo -1000 ;;
    restartable) echo -999 ;;
    *) echo "" ;;
  esac
}

cmd_mem() {
  awk '
    /^MemTotal:/     {t=$2}
    /^MemAvailable:/ {a=$2}
    /^Cached:/       {c=$2}
    /^SwapTotal:/    {st=$2}
    /^SwapFree:/     {sf=$2}
    /^Buffers:/      {b=$2}
    END {
      printf "total=%d\navail=%d\ncached=%d\nbuffers=%d\nswaptotal=%d\nswapfree=%d\n", t, a, c, b, st, sf
    }
  ' /proc/meminfo 2>/dev/null

  # zram 统计：Android 12+ 的内核**移除了 /sys/block/zram0/mem_used**，
  # 所有数字都在 mm_stat 里。之前以 mem_used 是否存在做判断，
  # 在新内核上恒为假，于是整个 zram 区块被跳过、界面全是 0 —— 必须读 mm_stat。
  #   mm_stat: orig_data_size compr_data_size mem_used ...
  z=/sys/block/zram0
  zorig=0; zused=0; zdisk=0; zalg=""
  if [ -d "$z" ]; then
    zdisk=$(cat "$z/disksize" 2>/dev/null)
    if [ -r "$z/mm_stat" ]; then
      read -r zorig _zcompr zused _rest < "$z/mm_stat" 2>/dev/null
      [ "${zused:-0}" -gt 0 ] 2>/dev/null || zused=${_zcompr:-0}
    else
      zorig=$(cat "$z/orig_data_size" 2>/dev/null)
      zused=$(cat "$z/mem_used" 2>/dev/null)
    fi
    zalg=$(sed -n 's/.*\[\(.*\)\].*/\1/p' "$z/comp_algorithm" 2>/dev/null)
  fi
  echo "zram_orig=${zorig:-0}"
  echo "zram_used=${zused:-0}"
  echo "zram_disk=${zdisk:-0}"
  echo "zram_alg=$zalg"

  # PSI 内存压力：avg10 是最直观的"现在有多紧"
  if [ -r /proc/pressure/memory ]; then
    echo "psi_some=$(awk '/^some/{gsub("avg10=",""); print $2; exit}' /proc/pressure/memory 2>/dev/null)"
    echo "psi_full=$(awk '/^full/{gsub("avg10=",""); print $2; exit}' /proc/pressure/memory 2>/dev/null)"
  else
    echo "psi_some="
    echo "psi_full="
  fi

  echo "swaps=$(awk '/^SwapTotal:/{t=$2} /^SwapFree:/{f=$2} END{print (t-f)}' /proc/meminfo 2>/dev/null)"
  echo "procs=$(ps -A 2>/dev/null | wc -l | tr -d ' ')"
}

# 进程列表。
# `ps -A -o PID,RSS,NAME` 的字段支持在不同 Android 版本/内核上并不一致（有的实现没有 NAME，
# 有的把 RSS 放在别的列），所以先探测再决定用哪条路径，失败就回落到读 /proc。
# 全量逐个读 /proc 要好几秒，只在 ps 不可用时才走。
ps_can_rss() {
  ps -A -o PID,RSS,NAME 2>/dev/null | sed -n '2p' | awk '
    NF >= 3 { if ($1 ~ /^[0-9]+$/ && $2 ~ /^[0-9]+$/) { print "1"; exit } }
  ' | grep -q 1
}

cmd_procs() {
  limit="${1:-40}"
  case "$limit" in ''|*[!0-9]*) limit=40 ;; esac

  if ps_can_rss; then
    ps -A -o PID,RSS,NAME 2>/dev/null | tail -n +2 \
      | sort -k2 -nr | head -n "$limit" \
      | while read -r pid rss name; do
          [ -n "$pid" ] || continue
          adj=$(cat "/proc/$pid/oom_score_adj" 2>/dev/null)
          uid=$(awk '/^Uid:/{print $2; exit}' "/proc/$pid/status" 2>/dev/null)
          printf '%s\t%s\t%s\t%s\t%s\n' \
            "$pid" "${uid:--1}" "${adj:--1}" "${rss:-0}" "${name:-?}"
        done
    return
  fi

  # 回落：直接解析 /proc/<pid>/statm（第 2 列是常驻页数）与 cmdline
  for d in /proc/[0-9]*; do
    pid=${d#/proc/}
    [ -r "$d/statm" ] || continue
    rss_pages=$(awk '{print $2; exit}' "$d/statm" 2>/dev/null)
    [ -n "$rss_pages" ] || continue
    name=$(tr '\0' '\n' < "$d/cmdline" 2>/dev/null | head -n 1)
    [ -n "$name" ] || name="[$pid]"
    uid=$(awk '/^Uid:/{print $2; exit}' "$d/status" 2>/dev/null)
    adj=$(cat "$d/oom_score_adj" 2>/dev/null)
    printf '%s\t%s\t%s\t%s\t%s\n' \
      "$pid" "${uid:--1}" "${adj:--1}" "$((rss_pages * 4))" "$name"
  done | sort -k4 -nr | head -n "$limit"
}

cmd_kill() {
  pid="$1"
  case "$pid" in ''|*[!0-9]*) echo "REFUSE_INVALID"; return 1 ;; esac
  [ -d "/proc/$pid" ] || { echo "REFUSE_INVALID"; return 1; }

  uid=$(awk '/^Uid:/{print $2; exit}' "/proc/$pid/status" 2>/dev/null)
  # uid < 10000 是系统进程，杀掉可能直接导致重启 —— 一律拒绝
  if [ -n "$uid" ] && [ "$uid" -lt 10000 ] 2>/dev/null; then
    echo "REFUSE_SYSTEM"
    return 2
  fi

  name=$(tr '\0' '\n' < "/proc/$pid/cmdline" 2>/dev/null | head -n 1)
  pkg=${name%%:*}

  # 优先走 am force-stop：会一并清掉该应用的子进程，比 kill -9 干净
  if [ -n "$pkg" ]; then
    if am force-stop "$pkg" >/dev/null 2>&1; then
      echo "OK force-stop $pkg"
      return 0
    fi
  fi

  if kill -9 "$pid" >/dev/null 2>&1; then
    echo "OK kill $pid"
    return 0
  fi

  echo "FAIL"
  return 3
}

# 释放页缓存。
# 注意：这**不是**释放应用内存。drop_caches 只是把「文件页 / 目录项 / inode」这些
# 随时可回收的缓存扔掉，系统本来就用空闲内存做这件事，扔掉之后首次读盘要重来一遍。
# 刚拷完大文件、刚装完应用时有点用；平时频繁点是负收益。
cmd_dropcache() {
  before=$(awk '/^MemAvailable:/{print $2}' /proc/meminfo)
  sync
  echo 3 > /proc/sys/vm/drop_caches 2>/dev/null || { echo "FAIL"; return 1; }
  sleep 1
  after=$(awk '/^MemAvailable:/{print $2}' /proc/meminfo)
  echo "OK ${before:-0} ${after:-0}"
}

# 触发内存规整：把碎片化的空闲页合并成大块，减少后续分配失败。
# 无副作用，代价是一次几十到几百毫秒的 CPU 占用。
cmd_compact() {
  echo 1 > /proc/sys/vm/compact_memory 2>/dev/null || { echo "FAIL"; return 1; }
  echo "OK"
}

# 读取当前生效的 VM 参数（只读）。键名与 /proc/sys/vm 下一致，
# 前端自己带中文标签和解释，脚本只负责取值。
cmd_vms() {
  for k in swappiness watermark_scale_factor min_free_kbytes page-cluster \
           dirty_ratio dirty_background_ratio compaction_proactiveness overcommit_memory; do
    v=$(cat "/proc/sys/vm/$k" 2>/dev/null)
    [ -n "$v" ] && printf '%s=%s\n' "$k" "$v"
  done
  # 缓存进程上限不属于 /proc/sys/vm，单独从 ActivityManager 取
  amc=$(device_config get activity_manager max_cached_processes 2>/dev/null)
  [ -n "$amc" ] && printf 'max_cached_processes=%s\n' "$amc"
}

# 压缩算法能力探测。
# /sys/block/zram0/comp_algorithm 的格式是 "lzo lzo-rle [lz4] lz4hc zstd"，
# 方括号里是当前生效的那个。只把内核真的编进去的算法交给前端，避免用户选了个不能用的。
cmd_algs() {
  f=/sys/block/zram0/comp_algorithm
  if [ -r "$f" ]; then
    raw=$(cat "$f" 2>/dev/null)
    cur=$(echo "$raw" | sed -n 's/.*\[\([^]]*\)\].*/\1/p')
    list=$(echo "$raw" | tr -d '[]' )
    echo "current=${cur}"
    echo "list=${list}"
  else
    echo "current="
    echo "list="
  fi
}

# 手动覆盖单个 VM 参数。写进 config.conf 的 VM_* 键，并把 VM_CUSTOM 置为 true，
# 之后 apply_vm_tuning 就优先用这些值而不是档位预设。
cmd_vmset() {
  key="$1"
  val="$2"
  [ -f "$CONFIG" ] || : > "$CONFIG"

  # 每项给一个安全区间，超出直接拒绝 —— 这些值写错会让系统变得很难用
  case "$key" in
    swappiness)                lo=0;   hi=200;  cfgkey=VM_SWAPPINESS ;;
    watermark_scale_factor)    lo=10;  hi=400;  cfgkey=VM_WATERMARK ;;
    min_free_kbytes)           lo=32768; hi=262144; cfgkey=VM_MIN_FREE ;;
    page-cluster)              lo=0;   hi=3;    cfgkey=VM_PAGE_CLUSTER ;;
    dirty_ratio)               lo=5;   hi=40;   cfgkey=VM_DIRTY_RATIO ;;
    compaction_proactiveness)  lo=0;   hi=100;  cfgkey=VM_COMPACT ;;
    *) echo "REFUSE_INVALID_KEY"; return 1 ;;
  esac

  case "$val" in ''|*[!0-9]*) echo "REFUSE_INVALID"; return 1 ;; esac
  if [ "$val" -lt "$lo" ] || [ "$val" -gt "$hi" ]; then
    echo "REFUSE_RANGE $lo $hi"
    return 1
  fi

  set_conf_kv "$cfgkey" "$val"
  set_conf_kv VM_CUSTOM true
  # 立即生效，不必等重启
  if [ -w "/proc/sys/vm/$key" ]; then
    echo "$val" > "/proc/sys/vm/$key" 2>/dev/null
  fi
  echo "OK $key $val"
}

# 恢复为「跟随保活强度档位」
cmd_vmreset() {
  [ -f "$CONFIG" ] || : > "$CONFIG"
  set_conf_kv VM_CUSTOM false
  # 手动设过的缓存上限也要一并交还给档位，否则下次开机
  # apply_background_retention 会继续用旧的 AM_CACHE_MAX 覆盖档位值
  set_conf_kv AM_CACHE_MAX 0
  echo "OK"
}

# 设备与能力探测。给「关于」页用 —— 不同品牌/内核能做什么，以本机实况为准，
# 不要在前端写死「支持 / 不支持」。
cmd_caps() {
  echo "model=$(getprop ro.product.model)"
  echo "android=$(getprop ro.build.version.release)"
  echo "sdk=$(getprop ro.build.version.sdk)"
  echo "kernel=$(uname -r)"
  [ -d /sys/block/zram0 ] && echo "zram=1" || echo "zram=0"
  [ -e /sys/block/zram0/recompress ] && echo "recompress=1" || echo "recompress=0"
  [ -e /sys/block/zram0/backing_dev ] && echo "writeback=1" || echo "writeback=0"
  [ -e /sys/kernel/mm/lru_gen/enabled ] && echo "mglru=1" || echo "mglru=0"
  [ -e /proc/sys/vm/compaction_proactiveness ] && echo "compact=1" || echo "compact=0"
  gpid=$(cat "$MODDIR/guard.pid" 2>/dev/null)
  if [ -n "$gpid" ] && [ -d "/proc/$gpid" ]; then
    echo "guard=1"
  else
    echo "guard=0"
  fi
  echo "amcache=$(device_config get activity_manager max_cached_processes 2>/dev/null)"
  if [ -d /data/adb/ksu ]; then
    echo "root=KernelSU"
  elif [ -d /data/adb/ap ]; then
    echo "root=APatch"
  elif [ -d /data/adb/magisk ]; then
    echo "root=Magisk"
  else
    echo "root=unknown"
  fi
}

# 读日志尾部。给前端解析成时间轴，路径与权限都在这里处理。
cmd_logs() {
  n="${1:-200}"
  case "$n" in ''|*[!0-9]*) n=200 ;; esac
  f="$MODDIR/memkeep.log"
  [ -f "$f" ] || return 0
  tail -n "$n" "$f" 2>/dev/null
}

# 清空日志文件。保留文件本身，避免 service.sh 里的重定向失效。
cmd_logclear() {
  f="$MODDIR/memkeep.log"
  if [ -f "$f" ]; then
    : > "$f"
    echo "OK cleared"
  else
    echo "OK absent"
  fi
}

# 恢复模块默认参数：主配置回默认值，并撤销手动 VM 覆盖。
# 注意只改模块自己的文件，不动 /proc/sys/vm —— 系统原值由 restore 负责。
cmd_reset() {
  [ -f "$CONFIG" ] || : > "$CONFIG"
  set_conf_kv ZRAM_ENABLE true
  set_conf_kv ZRAM_SIZE auto
  set_conf_kv ZRAM_ALGORITHM auto
  set_conf_kv ZRAM_KEEP_BACKING_DEV true
  set_conf_kv KEEP_MODE strong
  set_conf_kv LATE_REAPPLY true
  set_conf_kv VM_CUSTOM false
  set_conf_kv AM_CACHE_MAX 0
  set_conf_kv KEEP_DAEMON true
  echo "OK"
}

# 标记卸载：写入 remove 标记，root 管理器会在下次开机移除模块目录。
cmd_markremove() {
  gpid=$(cat "$MODDIR/guard.pid" 2>/dev/null)
  [ -n "$gpid" ] && kill "$gpid" 2>/dev/null
  rm -f "$MODDIR/guard.pid" 2>/dev/null
  : > "$MODDIR/remove" 2>/dev/null || { echo "FAIL_WRITE"; return 1; }
  echo "OK"
}

# 缓存进程上限（原 device_config 项）。单独成一个子命令，
# 因为它是 ActivityManager 的配置，不属于 /proc/sys/vm。
cmd_setcache() {
  n="$1"
  case "$n" in ''|*[!0-9]*) echo "REFUSE_INVALID"; return 1 ;; esac
  [ "$n" -lt 64 ] || [ "$n" -gt 512 ] || { echo "REFUSE_RANGE 64 512"; return 1; }
  set_conf_kv AM_CACHE_MAX "$n"
  device_config put activity_manager max_cached_processes "$n" >/dev/null 2>&1
  device_config put activity_manager max_phantom_processes "$n" >/dev/null 2>&1
  echo "OK $n"
}

cmd_keep_list() {
  [ -f "$LIST" ] || return 0
  grep -v '^[[:space:]]*#' "$LIST" 2>/dev/null | grep -v '^[[:space:]]*$'
}

cmd_keep_set() {
  pkg="$1"
  tier="$2"
  case "$pkg" in ''|*[!A-Za-z0-9._:-]*) echo "REFUSE_INVALID"; return 1 ;; esac
  case "$tier" in critical|restartable|off) ;; *) echo "REFUSE_INVALID"; return 1 ;; esac

  [ -f "$LIST" ] || : > "$LIST"
  tmp="$LIST.tmp"
  grep -v "^$pkg[[:space:]]" "$LIST" > "$tmp" 2>/dev/null
  if [ "$tier" = "off" ]; then
    cmd deviceidle whitelist "-$pkg" >/dev/null 2>&1
    am set-standby-bucket "$pkg" working_set >/dev/null 2>&1
  else
    printf '%s %s\n' "$pkg" "$tier" >> "$tmp"
  fi
  cat "$tmp" > "$LIST"
  rm -f "$tmp"
  chmod 0644 "$LIST" 2>/dev/null
  echo "OK $pkg $tier"
}

# 输出当前配置（config.conf 的有效键值），供 WebUI 回填。
# 之前前端只写不读，所以"保存后再进来又变回默认"。
cmd_config() {
  [ -f "$CONFIG" ] || return 0
  grep -vE '^[[:space:]]*(#|$)' "$CONFIG" 2>/dev/null
}

# 一次性写入高级设置（缓存上限 + 6 个 VM 参数），并立即生效。
# 顺序：cache swappiness watermark minfree pagecluster dirtyratio compact
cmd_vmsave() {
  [ $# -eq 7 ] || { echo "REFUSE_ARGS"; return 1; }

  c=$1; sw=$2; wm=$3; mf=$4; pc=$5; dr=$6; cp=$7
  for v in "$c" "$sw" "$wm" "$mf" "$pc" "$dr" "$cp"; do
    case "$v" in ''|*[!0-9]*) echo "REFUSE_INVALID"; return 1 ;; esac
  done
  [ "$c"  -ge 64 ]    && [ "$c"  -le 512 ]    || { echo "REFUSE_RANGE cache 64 512"; return 1; }
  [ "$sw" -ge 0 ]     && [ "$sw" -le 200 ]    || { echo "REFUSE_RANGE swappiness 0 200"; return 1; }
  [ "$wm" -ge 10 ]    && [ "$wm" -le 400 ]    || { echo "REFUSE_RANGE watermark 10 400"; return 1; }
  [ "$mf" -ge 32768 ] && [ "$mf" -le 262144 ] || { echo "REFUSE_RANGE minfree 32768 262144"; return 1; }
  [ "$pc" -ge 0 ]     && [ "$pc" -le 3 ]      || { echo "REFUSE_RANGE pagecluster 0 3"; return 1; }
  [ "$dr" -ge 5 ]     && [ "$dr" -le 40 ]     || { echo "REFUSE_RANGE dirty 5 40"; return 1; }
  [ "$cp" -ge 0 ]     && [ "$cp" -le 100 ]    || { echo "REFUSE_RANGE compact 0 100"; return 1; }

  set_conf_kv AM_CACHE_MAX "$c"
  set_conf_kv VM_CUSTOM true
  set_conf_kv VM_SWAPPINESS "$sw"
  set_conf_kv VM_WATERMARK "$wm"
  set_conf_kv VM_MIN_FREE "$mf"
  set_conf_kv VM_PAGE_CLUSTER "$pc"
  set_conf_kv VM_DIRTY_RATIO "$dr"
  set_conf_kv VM_COMPACT "$cp"

  # 立刻生效，不必等重启
  device_config put activity_manager max_cached_processes "$c" >/dev/null 2>&1
  device_config put activity_manager max_phantom_processes "$c" >/dev/null 2>&1
  for kv in "swappiness=$sw" "watermark_scale_factor=$wm" "min_free_kbytes=$mf" \
            "page-cluster=$pc" "dirty_ratio=$dr" "compaction_proactiveness=$cp"; do
    k=${kv%%=*}; v=${kv#*=}
    [ -e "/proc/sys/vm/$k" ] && { chmod 0644 "/proc/sys/vm/$k" 2>/dev/null; echo "$v" > "/proc/sys/vm/$k" 2>/dev/null; }
  done
  echo "OK"
}

# 已安装的第三方应用。给"从应用列表添加保活"用 ——
# 之前只能从正在运行的进程里挑，没运行的应用根本选不到。
cmd_apps() {
  pm list packages -3 2>/dev/null | sed 's/^package://' | grep -v '^[[:space:]]*$' | sort
}

# LMK 击杀记录。这是唯一能回答"我的应用到底被谁杀了"的数据源。
# 原样输出 logcat 行，时间戳解析交给前端。
cmd_kills() {
  n="${1:-60}"
  case "$n" in ''|*[!0-9]*) n=60 ;; esac
  {
    logcat -d -b events -t 1500 2>/dev/null | grep -i lmkd
    logcat -d -b main -t 1500 2>/dev/null | grep -iE "lowmemorykiller|lmkd.*[Kk]ill"
  } | awk '!seen[$0]++' | tail -n "$n"
}

# 恢复安装前的系统原值。快照由 customize.sh 在安装时生成。
cmd_restore() {
  snap="$MODDIR/system_snapshot.conf"
  [ -f "$snap" ] || { echo "NO_SNAPSHOT"; return 1; }

  while IFS='=' read -r k v; do
    case "$k" in ''|\#*) continue ;; esac
    [ -n "$v" ] || continue
    case "$k" in
      swappiness|watermark_scale_factor|min_free_kbytes|page-cluster|dirty_ratio|dirty_background_ratio|compaction_proactiveness|overcommit_memory)
        path="/proc/sys/vm/$k"
        [ -e "$path" ] && { chmod 0644 "$path" 2>/dev/null; echo "$v" > "$path" 2>/dev/null; }
        ;;
      am_cache_max)
        device_config delete activity_manager max_cached_processes >/dev/null 2>&1
        device_config delete activity_manager max_phantom_processes >/dev/null 2>&1
        ;;
      *) : ;;
    esac
  done < "$snap"

  # 自己的配置也一并归零
  [ -f "$LIST" ] && : > "$LIST"
  set_conf_kv VM_CUSTOM false
  set_conf_kv AM_CACHE_MAX 0
  echo "OK"
}

# 找出某个包名对应的所有进程 pid（含 :子进程）。
# pgrep -f 不是所有 toybox 版本都支持，所以三级回落：
#   pgrep -f  →  ps -o PID,NAME  →  直接扫 /proc/*/cmdline
pids_of_pkg() {
  pkg="$1"
  if command -v pgrep >/dev/null 2>&1; then
    out=$(pgrep -f "^${pkg}(:|$)" 2>/dev/null)
    if [ $? -eq 0 ] || [ -n "$out" ]; then echo "$out"; return 0; fi
  fi
  out=$(ps -A -o PID,NAME 2>/dev/null | tail -n +2 | awk -v p="$pkg" \
        '$2==p || index($2, p ":")==1 {print $1}')
  if [ -n "$out" ]; then echo "$out"; return 0; fi
  for d in /proc/[0-9]*; do
    n=$(tr '\0' '\n' < "$d/cmdline" 2>/dev/null | head -n 1)
    case "$n" in
      "$pkg"|"$pkg":*) echo "${d#/proc/}" ;;
    esac
  done
}

# 把名单写成 oom_score_adj。
cmd_keep_apply() {
  [ -f "$LIST" ] || { echo "OK empty"; return 0; }
  cmd_keep_list | while read -r pkg tier; do
    [ -n "$pkg" ] || continue
    s=$(score_of "$tier")
    [ -n "$s" ] || continue
    for p in $(pids_of_pkg "$pkg"); do
      echo "$s" > "/proc/$p/oom_score_adj" 2>/dev/null
    done
    # 只压 oom_score_adj 是"硬扛"；再从系统语义上放行，
    # 让应用进 active bucket 并豁免 Doze —— 进程万一被回收，通知也不会被掐。
    am set-standby-bucket "$pkg" active >/dev/null 2>&1
    cmd deviceidle whitelist "+$pkg" >/dev/null 2>&1
  done
  echo "OK applied"
}

# 守护：名单里的应用被系统改回默认值后重新压回去。
# 间隔 5s 而不是竞品的 100ms —— oom_score_adj 只在应用切前后台那几个时刻被改写，
# 5s 足够跟上；sleep 不持有 wakelock，休眠时不会把设备唤醒，耗电可忽略。
cmd_keep_guard() {
  echo $$ > "$MODDIR/guard.pid" 2>/dev/null
  while true; do
    cmd_keep_apply >/dev/null 2>&1
    sleep 5
  done
}

case "$1" in
  mem)   cmd_mem ;;
  procs) cmd_procs "$2" ;;
  kill)  cmd_kill "$2" ;;
  dropcache) cmd_dropcache ;;
  compact)   cmd_compact ;;
  vms)       cmd_vms ;;
  vmset)     cmd_vmset "$2" "$3" ;;
  vmreset)   cmd_vmreset ;;
  algs)      cmd_algs ;;
  caps)      cmd_caps ;;
  logs)      cmd_logs "$2" ;;
  kills)     cmd_kills "$2" ;;
  apps)      cmd_apps ;;
  config)    cmd_config ;;
  vmsave)    shift; cmd_vmsave "$@" ;;
  restore)   cmd_restore ;;
  reset)     cmd_reset ;;
  logclear)  cmd_logclear ;;
  markremove) cmd_markremove ;;
  setcache)  cmd_setcache "$2" ;;
  keep)
    case "$2" in
      list)  cmd_keep_list ;;
      set)   cmd_keep_set "$3" "$4" ;;
      apply) cmd_keep_apply ;;
      guard) cmd_keep_guard ;;
      *) echo "usage: memkeep.sh keep list|set|apply|guard" ; exit 1 ;;
    esac
    ;;
  *)
    echo "usage: memkeep.sh mem|procs [N]|kill <pid>|dropcache|compact|keep ..."
    exit 1
    ;;
esac
