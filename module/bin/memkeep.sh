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

MODDIR=${0%/*}
[ "$MODDIR" = "$0" ] && MODDIR=.
MODDIR=${MODDIR%/*}
LIST="$MODDIR/keep_apps.conf"

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

  # zram 实际占用与压缩比，没有 zram 就输出 0
  if [ -r /sys/block/zram0/mem_used ]; then
    used=$(cat /sys/block/zram0/mem_used 2>/dev/null)
    orig=$(cat /sys/block/zram0/mm_stat 2>/dev/null | awk '{print $1}')
    disk=$(cat /sys/block/zram0/disksize 2>/dev/null)
    echo "zram_used=${used:-0}"
    echo "zram_orig=${orig:-0}"
    echo "zram_disk=${disk:-0}"
    echo "zram_alg=$(cat /sys/block/zram0/comp_algorithm 2>/dev/null | sed -n 's/.*\[\(.*\)\].*/\1/p')"
  else
    echo "zram_used=0"
    echo "zram_orig=0"
    echo "zram_disk=0"
    echo "zram_alg="
  fi
  echo "procs=$(ps -A 2>/dev/null | wc -l | tr -d ' ')"
}

cmd_procs() {
  limit="${1:-40}"
  case "$limit" in ''|*[!0-9]*) limit=40 ;; esac

  # ps 一次拿全量（含 RSS），再只对前 N 个读 oom_score_adj。
  # 全量逐个读 /proc 在低端机要好几秒，这样能把耗时压到 100ms 级。
  ps -A -o PID,RSS,NAME 2>/dev/null | tail -n +2 \
    | sort -k2 -nr | head -n "$limit" \
    | while read -r pid rss name; do
        [ -n "$pid" ] || continue
        adj=$(cat "/proc/$pid/oom_score_adj" 2>/dev/null)
        uid=$(awk '/^Uid:/{print $2; exit}' "/proc/$pid/status" 2>/dev/null)
        printf '%s\t%s\t%s\t%s\t%s\n' \
          "$pid" "${uid:--1}" "${adj:--1}" "${rss:-0}" "${name:-?}"
      done
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
  [ "$tier" != "off" ] && printf '%s %s\n' "$pkg" "$tier" >> "$tmp"
  cat "$tmp" > "$LIST"
  rm -f "$tmp"
  chmod 0644 "$LIST" 2>/dev/null
  echo "OK $pkg $tier"
}

# 把名单写成 oom_score_adj。每个包一次 pgrep，比全量扫 /proc 快一个数量级。
cmd_keep_apply() {
  [ -f "$LIST" ] || { echo "OK empty"; return 0; }
  cmd_keep_list | while read -r pkg tier; do
    [ -n "$pkg" ] || continue
    s=$(score_of "$tier")
    [ -n "$s" ] || continue

    if command -v pgrep >/dev/null 2>&1; then
      pids=$(pgrep -f "^${pkg}(:|$)" 2>/dev/null)
    else
      pids=$(ps -A -o PID,NAME 2>/dev/null | tail -n +2 | awk -v p="$pkg" \
             '$2==p || index($2, p ":")==1 {print $1}')
    fi

    for p in $pids; do
      echo "$s" > "/proc/$p/oom_score_adj" 2>/dev/null
    done
  done
  echo "OK applied"
}

# 守护：名单里的应用被系统改回默认值后重新压回去。
# 间隔 5s 而不是竞品的 100ms —— oom_score_adj 只在应用切前后台那几个时刻被改写，
# 5s 足够跟上；sleep 不持有 wakelock，休眠时不会把设备唤醒，耗电可忽略。
cmd_keep_guard() {
  while true; do
    cmd_keep_apply >/dev/null 2>&1
    sleep 5
  done
}

case "$1" in
  mem)   cmd_mem ;;
  procs) cmd_procs "$2" ;;
  kill)  cmd_kill "$2" ;;
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
    echo "usage: memkeep.sh mem|procs [N]|kill <pid>|keep ..."
    exit 1
    ;;
esac
