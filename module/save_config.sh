#!/system/bin/sh

MODDIR=${0%/*}
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
    auto|8G|12G|16G|50%|75%|100%|125%) return 0 ;;
    *) return 1 ;;
  esac
}

zram_algorithm_value() {
  case "$1" in
    auto|zstd|lz4|lzo-rle|lzo) return 0 ;;
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

cat > "$TMP" <<EOF
# MemKeep++ configuration
# Saved from KernelSU WebUI.

ZRAM_ENABLE=$ZRAM_ENABLE
ZRAM_SIZE=$ZRAM_SIZE
ZRAM_ALGORITHM=$ZRAM_ALGORITHM
ZRAM_KEEP_BACKING_DEV=$ZRAM_KEEP_BACKING_DEV
KEEP_MODE=$KEEP_MODE
LATE_REAPPLY=$LATE_REAPPLY
EOF

cat "$TMP" > "$CONFIG" || fail "cannot write config"
rm -f "$TMP"
chmod 0644 "$CONFIG" 2>/dev/null
sync

cat "$CONFIG"
