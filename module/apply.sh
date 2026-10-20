#!/system/bin/sh

MODDIR=${0%/*}
. "$MODDIR/tools.sh"

load_config
log_msg "manual apply started"

apply_vm_tuning
apply_lmk_props
apply_background_retention

log_msg "manual apply finished; reboot to rebuild zram"
exit 0
