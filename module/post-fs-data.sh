#!/system/bin/sh

MODDIR=${0%/*}
. "$MODDIR/tools.sh"

load_config
apply_lmk_props
apply_vm_tuning
