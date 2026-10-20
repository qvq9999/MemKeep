#!/system/bin/sh

MODDIR=${0%/*}
. "$MODDIR/tools.sh"

load_config
log_msg "service started"

apply_zram
apply_vm_tuning
apply_lmk_props

wait_boot_completed
sleep 20

apply_background_retention

if [ "$LATE_REAPPLY" = "true" ]; then
  sleep 90
  apply_vm_tuning
  apply_background_retention
fi

log_msg "service finished"
