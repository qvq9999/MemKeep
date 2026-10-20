#!/system/bin/sh

MODDIR=${0%/*}
. "$MODDIR/tools.sh"

KEEP_BIN="$MODDIR/bin/memkeep.sh"

load_config
log_msg "service started"

apply_zram
apply_vm_tuning
apply_lmk_props

wait_boot_completed
sleep 20

apply_background_retention

# 保活名单先压一次。真正的持续生效靠下面的守护 ——
# ActivityManager 会在应用切前后台时重写 oom_score_adj。
if [ -x "$KEEP_BIN" ] || [ -f "$KEEP_BIN" ]; then
  sh "$KEEP_BIN" keep apply >/dev/null 2>&1
  log_msg "keep list applied"
fi

if [ "$LATE_REAPPLY" = "true" ]; then
  sleep 90
  apply_vm_tuning
  apply_background_retention
fi

if [ "$KEEP_DAEMON" = "true" ] && { [ -x "$KEEP_BIN" ] || [ -f "$KEEP_BIN" ]; }; then
  # 放到独立会话里，避免跟着 service.sh 退出
  if command -v nohup >/dev/null 2>&1; then
    nohup sh "$KEEP_BIN" keep guard >/dev/null 2>&1 &
  else
    ( sh "$KEEP_BIN" keep guard >/dev/null 2>&1 & )
  fi
  log_msg "keep guardian started"
fi

log_msg "service finished"
