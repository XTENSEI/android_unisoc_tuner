#!/system/bin/sh
MODDIR=${0%*}
[ -d "$MODDIR" ] || MODDIR=.
TMPD=${UT_TMP:-/data/local/tmp}
sh "$MODDIR/bin/serve.sh" stop >/dev/null 2>&1
rm -f "$TMPD/ut.serve.enable" "$TMPD/ut.serve.token" "$TMPD/ut.serve.pid" "$TMPD/ut.serve.fifo"
sh "$MODDIR/bin/tuner.sh" reset >/dev/null 2>&1
sh "$MODDIR/bin/system.sh" reset >/dev/null 2>&1
sh "$MODDIR/bin/dvfs.sh" reset >/dev/null 2>&1
rm -f /data/adb/unisoc-tuner.conf /data/adb/unisoc-tuner-sys.conf /data/adb/unisoc-tuner-dvfs.conf
rm -f /data/adb/unisoc-tuner.log /data/adb/unisoc-tuner.log.old
