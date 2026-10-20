#!/system/bin/sh

set_perm "$MODPATH/post-fs-data.sh" 0 0 0755
set_perm "$MODPATH/service.sh" 0 0 0755
set_perm "$MODPATH/apply.sh" 0 0 0755
set_perm "$MODPATH/save_config.sh" 0 0 0755
set_perm "$MODPATH/uninstall.sh" 0 0 0755
set_perm "$MODPATH/tools.sh" 0 0 0755
set_perm "$MODPATH/action.sh" 0 0 0755

ui_print "- MemKeep++"
ui_print "- Device: $(getprop ro.product.device)"
ui_print "- Model: $(getprop ro.product.model)"
ui_print "- Android SDK: $(getprop ro.build.version.sdk)"

SDK="$(getprop ro.build.version.sdk)"
if [ "$SDK" != "36" ]; then
  ui_print "- Warning: this module is tuned for Android 16 / SDK 36."
fi

ui_print "- Config file: $MODPATH/config.conf"
ui_print "- WebUI entry: $MODPATH/webroot/index.html"
ui_print "- Install complete. Reboot to apply."
