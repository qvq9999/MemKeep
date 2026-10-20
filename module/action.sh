#!/system/bin/sh

MODDIR=${0%/*}

echo "MemKeep++"
echo
echo "Config:"
cat "$MODDIR/config.conf"
echo
echo "Recent log:"
if [ -f "$MODDIR/memkeep.log" ]; then
  tail -n 40 "$MODDIR/memkeep.log"
else
  echo "No log yet. Reboot once after installation."
fi
