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
NAMES="$MODDIR/app_names.conf"      # 用户自定义显示名（包名=名字）

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

# 取 /proc/meminfo 里某个字段的 kB 值（不存在则输出 0）
meminfo_kb() {
  awk -v k="$1" '$1==k":"{print $2+0; exit}' /proc/meminfo 2>/dev/null
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
  #   mm_stat: orig_data_size compr_data_size mem_used mem_limit mem_used_max ...
  #
  # 三个量的口径必须分清（前端就是按这个算占用率和压缩比的）：
  #   orig_data_size   未压缩数据量 —— 写进 swap 的页的原始大小，
  #                    等于 `free` 里的 swap used，和 disksize 同量纲
  #   compr_data_size  压缩后数据量 —— 真实压缩比的分母
  #   mem_used         zram 实际吃掉的物理内存（压缩页 + 元数据/分配器开销）
  # 占用率只能用 orig/disksize；拿 mem_used 去比 disksize 是两个量纲相除，
  # 会比系统里看到的 swap 占用低一大截（典型低 3–4 倍）。
  z=/sys/block/zram0
  zorig=0; zused=0; zcompr=0; zdisk=0; zalg=""
  if [ -d "$z" ]; then
    zdisk=$(cat "$z/disksize" 2>/dev/null)
    if [ -r "$z/mm_stat" ]; then
      read -r zorig zcompr zused _rest < "$z/mm_stat" 2>/dev/null
    else
      zorig=$(cat "$z/orig_data_size" 2>/dev/null)
      zcompr=$(cat "$z/compr_data_size" 2>/dev/null)
      zused=$(cat "$z/mem_used" 2>/dev/null)
    fi
    zorig=${zorig:-0}; zcompr=${zcompr:-0}; zused=${zused:-0}
    # 4.20 之前的厂商分支里 mm_stat 的单位是「页」，之后统一成「字节」。
    # 用 meminfo 的 swap 占用量交叉校验：字节口径下两者几乎相等，
    # 差 4096 倍就是页口径，统一换算成字节再往下传。
    _su=$(( ($(meminfo_kb SwapTotal) - $(meminfo_kb SwapFree)) * 1024 ))
    if [ "${_su:-0}" -gt 0 ] && [ "${zorig:-0}" -gt 0 ] 2>/dev/null; then
      _ratio=$(awk -v s="$_su" -v o="$zorig" 'BEGIN{ if (o > 0) printf "%d", s / o; else print 0 }')
      if [ "${_ratio:-0}" -ge 3000 ] && [ "${_ratio:-0}" -le 5000 ]; then
        zorig=$((zorig * 4096)); zcompr=$((zcompr * 4096)); zused=$((zused * 4096))
      fi
    fi
    zalg=$(sed -n 's/.*\[\(.*\)\].*/\1/p' "$z/comp_algorithm" 2>/dev/null)
  fi
  echo "zram_orig=${zorig:-0}"
  echo "zram_compr=${zcompr:-0}"
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
    # 这里在 v3.3 一度被改成「一次 awk 读 60 个 /proc 文件 + 一个 awk 做 join」，
    # 想把 120 次 fork 压到 3 次；结果在真机上两个 dump 都是空的，uid/adj 全部落到 -1，
    # 前端 isSys 判定成「全是系统进程」，首页一行都不显示 —— 性能优化不能牺牲可用性。
    # 现在退回 v3.2 已验证的逐进程读取，只把「每个 pid 两个 fork」合成一个，
    # 行为与 v3.2 完全一致（60 进程 60 次 fork）。
    #   < /dev/null 是保险：两个文件都不存在时 awk 没有文件参数会去读 stdin，
    #   在 WebUI 的 exec 环境里 stdin 不是 EOF，会直接卡住整条 boot。
    ps -A -o PID,RSS,NAME 2>/dev/null | tail -n +2 \
      | sort -k2 -nr | head -n "$limit" \
      | while read -r pid rss name; do
          [ -n "$pid" ] || continue
          uid=-1; adj=-1
          if [ -r "/proc/$pid/oom_score_adj" ] || [ -r "/proc/$pid/status" ]; then
            ua=$(awk 'FILENAME ~ /oom_score_adj$/ { adj = $1 + 0 }
                      /^Uid:/ { uid = $2 }
                      END { printf "%s %s\n", (uid == "" ? "-1" : uid), (adj == "" ? "-1" : adj) }' \
                 "/proc/$pid/oom_score_adj" "/proc/$pid/status" 2>/dev/null < /dev/null)
            uid=${ua%% *}
            adj=${ua##* }
            [ -n "$uid" ] || uid=-1
            [ -n "$adj" ] || adj=-1
          fi
          printf '%s\t%s\t%s\t%s\t%s\n' \
            "$pid" "$uid" "$adj" "${rss:-0}" "${name:-?}"
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

  # MGLRU 工作集保护（最近 N 毫秒访问过的页不淘汰），0 = 关闭
  ttl=$(cat /sys/kernel/mm/lru_gen/min_ttl_ms 2>/dev/null)
  printf 'min_ttl_ms=%s\n' "${ttl:-0}"
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
    min_ttl_ms)                lo=0;   hi=3000; cfgkey=VM_MIN_TTL ;;
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
  if [ "$key" = "min_ttl_ms" ]; then
    if [ -w /sys/kernel/mm/lru_gen/min_ttl_ms ]; then
      echo "$val" > /sys/kernel/mm/lru_gen/min_ttl_ms 2>/dev/null
    else
      echo "OK $key $val (mglru unsupported, saved only)"
      return 0
    fi
  elif [ -w "/proc/sys/vm/$key" ]; then
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
  # 缓存应用冻结器：留内存但不上 CPU，直接决定"多开切回来要不要冷启动"
  fz=$(device_config get activity_manager_native_boot use_freezer 2>/dev/null)
  [ "$fz" = "true" ] && echo "freezer=1" || echo "freezer=0"
  [ -d /sys/kernel/mm/lru_gen ] && echo "mglru=1" || echo "mglru=0"
  # memcg 是 v1 还是 v2：v1 没有 memory.low，回收目标层做不了
  if [ -e /sys/fs/cgroup/cgroup.controllers ]; then
    if grep -q memory /sys/fs/cgroup/cgroup.controllers 2>/dev/null; then
      echo "memcg=v2"
    else
      echo "memcg=v2-nomem"
    fi
  else
    echo "memcg=v1"
  fi
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
  set_conf_kv VM_MIN_TTL 0
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
  # 这里必须「越界才拒绝」。旧代码写成
  #   [ "$n" -lt 64 ] || [ "$n" -gt 512 ] || { echo REFUSE_RANGE; return 1; }
  # A || B || C 里的 C 只在 A、B 都为假时执行 —— 于是 64..512 之间的值
  # 两个条件都为假，必然落到 refuse，WebUI 里怎么调都被拒；反而 <64 / >512
  # 这种非法值能写进去。
  # 上限必须与 tools.sh 的 apply_background_retention 一致（那边钳到 1024）：
  # 档位按「原厂 ×2」算出来的值本来就能到 1024，手动却只给到 512，
  # 会出现「默认 1024、手动最高只能 512」这种自相矛盾。
  if [ "$n" -lt 64 ] || [ "$n" -gt 1024 ]; then
    echo "REFUSE_RANGE 64 1024"
    return 1
  fi
  set_conf_kv AM_CACHE_MAX "$n"
  device_config put activity_manager max_cached_processes "$n" >/dev/null 2>&1
  device_config put activity_manager max_phantom_processes "$n" >/dev/null 2>&1
  echo "OK $n"
}

cmd_keep_list() {
  [ -f "$LIST" ] || return 0
  grep -v '^[[:space:]]*#' "$LIST" 2>/dev/null | grep -v '^[[:space:]]*$'
}

# 用户自定义的应用显示名。
# Android 没有命令能给出本地化应用名（pm / dumpsys 都不带 label，label 只在 APK 的
# resources.arsc 里），所以 WebUI 内置了一张常用表，覆盖不到的由用户自己命名，
# 存在这里。格式每行「包名=名字」，和 keep_apps.conf 一样是人可读的纯文本。
cmd_names() {
  [ -f "$NAMES" ] || return 0
  grep -v '^[[:space:]]*#' "$NAMES" 2>/dev/null | grep -v '^[[:space:]]*$'
}

cmd_name_set() {
  pkg="$1"; shift
  name="$*"
  case "$pkg" in ''|*[!A-Za-z0-9._:-]*) echo "REFUSE_INVALID"; return 1 ;; esac

  # 名字里出现换行会把 conf 的行结构弄坏；等号会把 key/value 切错
  name=$(printf '%s' "$name" | tr -d '\n\r' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
  case "$name" in
    *=*) echo "REFUSE_INVALID"; return 1 ;;
  esac
  # 按字节算，60 字节 ≈ 20 个汉字；超长一律拒绝而不是截断（截断会把汉字切坏）
  [ ${#name} -le 60 ] || { echo "REFUSE_TOO_LONG"; return 1; }

  [ -f "$NAMES" ] || : > "$NAMES"
  tmp="$NAMES.tmp"
  grep -v "^$pkg=" "$NAMES" > "$tmp" 2>/dev/null
  if [ -n "$name" ]; then
    printf '%s=%s\n' "$pkg" "$name" >> "$tmp"
  fi
  cat "$tmp" > "$NAMES"
  rm -f "$tmp"
  chmod 0644 "$NAMES" 2>/dev/null
  echo "OK $pkg $name"
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

# 保活体检：把「到底有没有生效」变成可验证的数字。
# 之前只能看到「保护中」三个字，但分数有没有压进去、应用是不是真被冻结、
# 回收有没有伤到工作集，全靠猜。
#
# 慢的根因不在读数本身，而在 fork 次数。旧实现每个保活应用都要：
#   · 调 2 次 keep list（每次 3 个 fork）
#   · pids_of_pkg 回落时跑一次 `ps -A` 全表
#   · `am get-standby-bucket` 一次（fork app_process + binder 到 system_server，0.3–1.5s）
# 8 个应用就是 8–18 秒。所以拆成三段：
#   health fast   只读 /proc /sys，几十毫秒 —— 前端先渲染这一屏
#   health bucket 只剩「每包一次 am」，有限并发、单独超时，异步补进表格
#   health        旧的合并版，留给还没更新的前端 / 命令行直接用
PS_SNAP=""
ps_snapshot() {
  ps -A -o PID,NAME 2>/dev/null | tail -n +2
}

get_standby_bucket() {
  if command -v timeout >/dev/null 2>&1; then
    b=$(timeout 2 am get-standby-bucket "$1" 2>/dev/null | tr -d ' \r')
  else
    b=$(am get-standby-bucket "$1" 2>/dev/null | tr -d ' \r')
  fi
  case "$b" in ''|*[!0-9]*) b=-1 ;; esac
  echo "$b"
}

cmd_health_fast() {
  # 工作集回读：页面被淘汰后又立刻读回来的次数。
  # 增长快 = 回收把热页淘汰了 = 应用切回来要重新加载，也就是"假保活"。
  awk '
    /^workingset_refault_anon/ {ra=$2}
    /^workingset_refault_file/ {rf=$2}
    /^pgrefault_anon/          {pa=$2}
    /^pgrefault_file/          {pf=$2}
    /^pgsteal_anon/            {sa=$2}
    /^pgsteal_file/            {sf=$2}
    END {
      printf "refault_anon=%d\n", ra+pa
      printf "refault_file=%d\n", rf+pf
      printf "steal_anon=%d\n", sa
      printf "steal_file=%d\n", sf
    }' /proc/vmstat 2>/dev/null

  fz=$(device_config get activity_manager_native_boot use_freezer 2>/dev/null)
  if [ "$fz" = "true" ]; then echo "freezer=1"; else echo "freezer=0"; fi

  # 冻结数量要从 dumpsys activity 里数。它是全量 dump，AM 忙的时候能卡好几秒，
  # 所以给它单独的硬超时；拿不到就报 frozen_ok=0，前端显示「—」而不是假的 0。
  frozen=0; fok=0
  if [ "$fz" = "true" ]; then
    if command -v timeout >/dev/null 2>&1; then
      n=$(timeout 3 dumpsys activity 2>/dev/null | grep -m1 -iE "Apps frozen:" | grep -oE "[0-9]+" | head -n1)
    else
      n=$(dumpsys activity 2>/dev/null | grep -m1 -iE "Apps frozen:" | grep -oE "[0-9]+" | head -n1)
    fi
    case "$n" in ''|*[!0-9]*) frozen=0; fok=0 ;; *) frozen=$n; fok=1 ;; esac
  fi
  echo "frozen=$frozen"
  echo "frozen_ok=$fok"

  # MGLRU / memcg：前端早就在读这两个键（用来判断「工作集保护能不能生效」
  # 和「有没有 memory.low」），但这里一直没输出，那两条诊断提示永远不出现。
  [ -d /sys/kernel/mm/lru_gen ] && echo "mglru=1" || echo "mglru=0"
  if [ -e /sys/fs/cgroup/cgroup.controllers ]; then
    grep -q memory /sys/fs/cgroup/cgroup.controllers 2>/dev/null && echo "memcg=v2" || echo "memcg=v2-nomem"
  else
    echo "memcg=v1"
  fi

  list=$(cmd_keep_list)
  [ -n "$list" ] || { echo "kept=0"; echo "kept_ok=0"; return 0; }

  # 一次 ps 建快照，循环里只做 awk 匹配 —— 原来是每个包 fork 一次 ps -A
  PS_SNAP=$(ps_snapshot)

  total=0; okc=0
  while read -r pkg tier; do
    [ -n "$pkg" ] || continue
    total=$((total + 1))
    tgt=$(score_of "$tier")

    adj=""
    for pd in $(printf '%s\n' "$PS_SNAP" | \
        awk -v p="$pkg" '$2==p || index($2, p ":")==1 {print $1}'); do
      a=$(cat "/proc/$pd/oom_score_adj" 2>/dev/null)
      case "$a" in ''|*[!0-9-]*) continue ;; esac
      if [ -z "$adj" ] || [ "$a" -lt "$adj" ]; then adj=$a; fi
    done
    # 应用没在跑时 adj 为空，用 -9999 标记，前端据此显示"未运行"
    [ -n "$adj" ] || adj="-9999"
    [ "$adj" = "$tgt" ] && okc=$((okc + 1))

    printf 'app %s %s - %s\n' "$pkg" "$adj" "$tgt"
  done <<EOF
$list
EOF

  echo "kept=$total"
  echo "kept_ok=$okc"
}

# 只查 standby bucket。每个包都要 fork 一个 app_process，没有任何批量接口，
# 所以用有限并发（4 个一批）+ 单包 2 秒硬超时压住最坏情况。
# 并发数不宜再高：每个 app_process 峰值要吃几十 MB，这毕竟是个内存管理工具。
cmd_health_bucket() {
  list=$(cmd_keep_list | awk '{print $1}')
  [ -n "$list" ] || return 0

  tmp="$MODDIR/.bucket.$$"
  : > "$tmp" 2>/dev/null || return 0

  n=0
  for pkg in $list; do
    ( printf '%s %s\n' "$pkg" "$(get_standby_bucket "$pkg")" >> "$tmp" ) &
    n=$((n + 1))
    [ $((n % 4)) -eq 0 ] && wait
  done
  wait

  # 按名单原顺序输出：并发完成顺序是随机的，直接吐会让前端行序乱跳
  for pkg in $list; do
    b=$(awk -v p="$pkg" '$1==p{print $2; exit}' "$tmp" 2>/dev/null)
    printf 'bucket %s %s\n' "$pkg" "${b:--1}"
  done
  rm -f "$tmp"
}

# 合并版：老前端只有 `health` 一条命令，这里把 bucket 并回 app 行
cmd_health() {
  bmap=$(cmd_health_bucket)
  cmd_health_fast | while read -r line; do
    case "$line" in
      app\ *)
        pkg=$(printf '%s\n' "$line" | awk '{print $2}')
        adj=$(printf '%s\n' "$line" | awk '{print $3}')
        tgt=$(printf '%s\n' "$line" | awk '{print $5}')
        b=$(printf '%s\n' "$bmap" | awk -v p="$pkg" '$1=="bucket" && $2==p {print $3; exit}')
        printf 'app %s %s %s %s\n' "$pkg" "$adj" "${b:--1}" "$tgt"
        ;;
      *) printf '%s\n' "$line" ;;
    esac
  done
}

# 输出当前配置（config.conf 的有效键值），供 WebUI 回填。
# 之前前端只写不读，所以"保存后再进来又变回默认"。
cmd_config() {
  [ -f "$CONFIG" ] || return 0
  grep -vE '^[[:space:]]*(#|$)' "$CONFIG" 2>/dev/null
}

# 一次性写入高级设置（缓存上限 + 7 个 VM 参数），并立即生效。
# 顺序：cache swappiness watermark minfree pagecluster dirtyratio compact min_ttl
cmd_vmsave() {
  [ $# -eq 8 ] || { echo "REFUSE_ARGS"; return 1; }

  c=$1; sw=$2; wm=$3; mf=$4; pc=$5; dr=$6; cp=$7; ttl=$8
  for v in "$c" "$sw" "$wm" "$mf" "$pc" "$dr" "$cp" "$ttl"; do
    case "$v" in ''|*[!0-9]*) echo "REFUSE_INVALID"; return 1 ;; esac
  done
  # 上限 1024 与 tools.sh 的档位钳制对齐：档位「原厂 ×2」本来就能算出 1024
  [ "$c"  -ge 64 ]    && [ "$c"  -le 1024 ]   || { echo "REFUSE_RANGE cache 64 1024"; return 1; }
  [ "$sw" -ge 0 ]     && [ "$sw" -le 200 ]    || { echo "REFUSE_RANGE swappiness 0 200"; return 1; }
  [ "$wm" -ge 10 ]    && [ "$wm" -le 400 ]    || { echo "REFUSE_RANGE watermark 10 400"; return 1; }
  [ "$mf" -ge 32768 ] && [ "$mf" -le 262144 ] || { echo "REFUSE_RANGE minfree 32768 262144"; return 1; }
  [ "$pc" -ge 0 ]     && [ "$pc" -le 3 ]      || { echo "REFUSE_RANGE pagecluster 0 3"; return 1; }
  [ "$dr" -ge 5 ]     && [ "$dr" -le 40 ]     || { echo "REFUSE_RANGE dirty 5 40"; return 1; }
  [ "$cp" -ge 0 ]     && [ "$cp" -le 100 ]    || { echo "REFUSE_RANGE compact 0 100"; return 1; }
  [ "$ttl" -ge 0 ]    && [ "$ttl" -le 3000 ]  || { echo "REFUSE_RANGE minttl 0 3000"; return 1; }

  set_conf_kv AM_CACHE_MAX "$c"
  set_conf_kv VM_CUSTOM true
  set_conf_kv VM_SWAPPINESS "$sw"
  set_conf_kv VM_WATERMARK "$wm"
  set_conf_kv VM_MIN_FREE "$mf"
  set_conf_kv VM_PAGE_CLUSTER "$pc"
  set_conf_kv VM_DIRTY_RATIO "$dr"
  set_conf_kv VM_COMPACT "$cp"
  set_conf_kv VM_MIN_TTL "$ttl"

  # 立刻生效，不必等重启
  device_config put activity_manager max_cached_processes "$c" >/dev/null 2>&1
  device_config put activity_manager max_phantom_processes "$c" >/dev/null 2>&1
  for kv in "swappiness=$sw" "watermark_scale_factor=$wm" "min_free_kbytes=$mf" \
            "page-cluster=$pc" "dirty_ratio=$dr" "compaction_proactiveness=$cp"; do
    k=${kv%%=*}; v=${kv#*=}
    [ -e "/proc/sys/vm/$k" ] && { chmod 0644 "/proc/sys/vm/$k" 2>/dev/null; echo "$v" > "/proc/sys/vm/$k" 2>/dev/null; }
  done
  # MGLRU 的路径不在 /proc/sys/vm 下，单独写
  [ -w /sys/kernel/mm/lru_gen/min_ttl_ms ] && echo "$ttl" > /sys/kernel/mm/lru_gen/min_ttl_ms 2>/dev/null
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
    apply_memcg_low "$pkg" "$tier"
  done
  echo "OK applied"
}

# cgroup v2 的 memory.low：让这个应用的内存成为「最后被回收」的一块。
# oom_score_adj 只决定杀谁，memory.low 决定回收谁 —— 在更上游一层。
# 很多机型 memcg 仍是 v1（没有 memory.low），那就静默跳过，不假装成功。
# 上限按物理内存的 1/10 与 384MB 取小，避免把系统在别处挤到 OOM。
apply_memcg_low() {
  pkg="$1"
  tier="$2"
  [ -e /sys/fs/cgroup/cgroup.controllers ] || return 0
  grep -q memory /sys/fs/cgroup/cgroup.controllers 2>/dev/null || return 0

  uid=$(pids_of_pkg "$pkg" | while read -r pd; do
          awk '/^Uid:/{print $2; exit}' "/proc/$pd/status" 2>/dev/null
        done | head -n 1)
  [ -n "$uid" ] || return 0

  cg="/sys/fs/cgroup/uid_$uid"
  [ -d "$cg" ] && [ -w "$cg/memory.low" ] || return 0

  total_kb=$(awk '/MemTotal/{print $2; exit}' /proc/meminfo)
  case "$total_kb" in ''|*[!0-9]*) total_kb=4194304 ;; esac
  cap=$((total_kb * 1024 / 10))
  [ "$cap" -gt 402653184 ] && cap=402653184        # 384 MB
  [ "$tier" = "restartable" ] && cap=$((cap / 2))

  cur=$(cat "$cg/memory.current" 2>/dev/null)
  case "$cur" in ''|*[!0-9]*) cur=0 ;; esac
  val=$cur
  [ "$val" -gt "$cap" ] && val=$cap
  [ "$val" -gt 0 ] || return 0

  chmod 0644 "$cg/memory.low" 2>/dev/null
  echo "$val" > "$cg/memory.low" 2>/dev/null
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

# 首屏一次性取数。
# WebUI 每调一次 shell 就要 fork 一个 root shell（100–300ms 的固定开销），
# 之前首屏要发 8 次：probe + mem + caps + algs + config + procs + keep list + logs/kills。
# 合并成一次调用后固定开销只付一遍，前端按 ###TAG 分段切。
# 击杀记录（logcat）故意不放进来 —— 它是首屏最慢的一项，改由「日志」页按需拉。
# 当前模块版本。给「关于」页用。
# 页面里写死的版本号不会跟着发版走（v3.4 之前一直显示 v3.3），所以直接从
# 已安装的 module.prop 读 —— 这是设备上唯一的真值来源。
cmd_ver() {
  [ -f "$MODDIR/module.prop" ] || return 0
  v=$(sed -n 's/^version=//p' "$MODDIR/module.prop" 2>/dev/null | head -n 1)
  c=$(sed -n 's/^versionCode=//p' "$MODDIR/module.prop" 2>/dev/null | head -n 1)
  [ -n "$v" ] && printf 'version=%s\n' "$v"
  [ -n "$c" ] && printf 'code=%s\n' "$c"
}

# 三个档位各自会把「缓存进程上限」写成多少。
# 为什么需要这条命令：切档只改了 config.conf 里的 KEEP_MODE，device_config 里的值
# 要等 apply.sh 跑完才变。前端若直接读 device_config，切档后看到的是上一档留下的旧值，
# 表现就是「三个档位都不会改变缓存进程数值」。这里按同一套公式预算出来给前端预览。
# ⚠ 公式必须与 tools.sh 的 apply_background_retention 保持一致，改一处要改两处。
cmd_preset_cache() {
  v=""
  [ -f "$MODDIR/system_snapshot.conf" ] && \
    v=$(grep '^am_cache_max=' "$MODDIR/system_snapshot.conf" 2>/dev/null | head -n 1 | cut -d= -f2-)
  case "$v" in ''|null|*[!0-9]*) v=512 ;; esac
  fac="$v"

  for m in balanced strong max; do
    case "$m" in
      balanced) c=$fac ;;
      max)      c=$((fac * 2)) ;;
      *)        c=$((fac * 150 / 100)) ;;
    esac
    [ "$c" -gt 1024 ] && c=1024
    [ "$c" -lt 64 ]   && c=64
    printf '%s=%s\n' "$m" "$c"
  done
  printf 'orig=%s\n' "$fac"
}

cmd_boot() {
  n="${1:-60}"
  case "$n" in ''|*[!0-9]*) n=60 ;; esac
  echo "###VER";   cmd_ver
  echo "###CACHEP"; cmd_preset_cache
  echo "###MEM";    cmd_mem
  echo "###CAPS";   cmd_caps
  echo "###ALGS";   cmd_algs
  echo "###CONFIG"; cmd_config
  echo "###PROCS";  cmd_procs "$n"
  echo "###KEEP";   cmd_keep_list
  echo "###NAMES";  cmd_names
  echo "###LOGS";   cmd_logs 200
  echo "###END"
}

case "$1" in
  boot)  cmd_boot "$2" ;;
  ver)   cmd_ver ;;
  preset) cmd_preset_cache ;;
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
  health)
    case "$2" in
      fast)   cmd_health_fast ;;
      bucket) cmd_health_bucket ;;
      *)      cmd_health ;;
    esac
    ;;
  config)    cmd_config ;;
  vmsave)    shift; cmd_vmsave "$@" ;;
  restore)   cmd_restore ;;
  reset)     cmd_reset ;;
  logclear)  cmd_logclear ;;
  markremove) cmd_markremove ;;
  setcache)  cmd_setcache "$2" ;;
  names)     cmd_names ;;
  name)
    case "$2" in
      set) shift 2; cmd_name_set "$@" ;;
      *) echo "usage: memkeep.sh name set <pkg> <name>" ; exit 1 ;;
    esac
    ;;
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
