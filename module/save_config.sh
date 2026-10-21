#!/system/bin/sh
#
# 保存 WebUI 的配置项。
# 做法是「就地改值」而不是整份重写 —— 原来的实现用 heredoc 重新生成文件，
# 会把用户手写的注释和后续新增的键（如 KEEP_DAEMON）全部抹掉。
# 现在只替换目标键所在的那一行，其余内容原样保留。

MODDIR=${0%/*}
# 以 `sh save_config.sh` 这种相对方式调用时 ${0%/*} 不会得到目录，兜一下
[ "$MODDIR" = "$0" ] && MODDIR=.
CONFIG="$MODDIR/config.conf"
TMP="$CONFIG.tmp"

fail() {
  echo "ERROR: $*" >&2
  exit 1
}

bool_value() {
  case "$1" in
    true|false) return 0 ;;
    *) return 1 ;;
  esac
}

zram_size_value() {
  case "$1" in
    auto) return 0 ;;
    # 固定容量：1–32 之间的整数 GB（WebUI 的 8/12/16 预设与「自定义」都走这里）
    *G|*g)
      n="${1%G}"
      n="${n%g}"
      case "$n" in ''|*[!0-9]*) return 1 ;; esac
      [ "$n" -ge 1 ] && [ "$n" -le 32 ] && return 0
      return 1
      ;;
    # 兼容老配置里的百分比写法
    *%)
      n="${1%\%}"
      case "$n" in ''|*[!0-9]*) return 1 ;; esac
      [ "$n" -ge 10 ] && [ "$n" -le 200 ] && return 0
      return 1
      ;;
    *) return 1 ;;
  esac
}

zram_algorithm_value() {
  # 必须与 WebUI 的 ALG_SHOW（zstd/lz4/lz4hc/lzo-rle/lzo/deflate）对齐：
  # 原来这里只放行 4 个内置算法，用户在芯片支持的 lz4hc / deflate 上一点保存就报失败。
  case "$1" in
    auto|zstd|lz4|lz4hc|lzo-rle|lzo|deflate|842|lz4kd) return 0 ;;
    *) return 1 ;;
  esac
}

keep_mode_value() {
  case "$1" in
    balanced|strong|max) return 0 ;;
    *) return 1 ;;
  esac
}

ZRAM_ENABLE="$1"
ZRAM_SIZE="$2"
ZRAM_ALGORITHM="$3"
ZRAM_KEEP_BACKING_DEV="$4"
KEEP_MODE="$5"
LATE_REAPPLY="$6"

bool_value "$ZRAM_ENABLE" || fail "invalid ZRAM_ENABLE"
zram_size_value "$ZRAM_SIZE" || fail "invalid ZRAM_SIZE"
zram_algorithm_value "$ZRAM_ALGORITHM" || fail "invalid ZRAM_ALGORITHM"
bool_value "$ZRAM_KEEP_BACKING_DEV" || fail "invalid ZRAM_KEEP_BACKING_DEV"
keep_mode_value "$KEEP_MODE" || fail "invalid KEEP_MODE"
bool_value "$LATE_REAPPLY" || fail "invalid LATE_REAPPLY"

[ -f "$CONFIG" ] || : > "$CONFIG"
cp "$CONFIG" "$TMP" || fail "cannot copy config"

set_kv() {
  key="$1"
  value="$2"
  if grep -q "^${key}=" "$TMP" 2>/dev/null; then
    sed "s|^${key}=.*|${key}=${value}|" "$TMP" > "$TMP.n" && mv "$TMP.n" "$TMP"
  else
    printf '%s=%s\n' "$key" "$value" >> "$TMP"
  fi
}

set_kv ZRAM_ENABLE "$ZRAM_ENABLE"
set_kv ZRAM_SIZE "$ZRAM_SIZE"
set_kv ZRAM_ALGORITHM "$ZRAM_ALGORITHM"
set_kv ZRAM_KEEP_BACKING_DEV "$ZRAM_KEEP_BACKING_DEV"
set_kv KEEP_MODE "$KEEP_MODE"
set_kv LATE_REAPPLY "$LATE_REAPPLY"

cat "$TMP" > "$CONFIG" || fail "cannot write config"
rm -f "$TMP" "$TMP.n"
chmod 0644 "$CONFIG" 2>/dev/null
sync

cat "$CONFIG"
