#!/system/bin/sh
# rotation + boot apply audit: every write and every failure lands in the log
MODDIR=${0%*}
[ -d "$MODDIR" ] || MODDIR=.
LOG=${UT_LOG:-/data/adb/unisoc-tuner.log}
D=${UT_D:-/sys/class/devfreq/23100000.gpu}
ENABLE=${UT_TMP:-/data/local/tmp}/ut.serve.enable
L() { echo "$(date '+%m-%d %H:%M:%S') service $*" >> "$LOG" 2>/dev/null; return 0; }

[ -f "$LOG" ] && mv -f "$LOG" "$LOG.old" 2>/dev/null
L "boot, module $(sed -n 's/^version=//p' "$MODDIR/module.prop" 2>/dev/null)"

i=0
while [ ! -e "$D" ] && [ $i -lt 30 ]; do sleep 1; i=$((i + 1)); done

if [ -e "$D" ]; then
  sh "$MODDIR/bin/tuner.sh" apply >/dev/null 2>&1
  L "tuner apply rc=$?"
else
  L "no gpu devfreq node after ${i}s, gpu apply skipped"
fi

sh "$MODDIR/bin/system.sh" apply >/dev/null 2>&1
L "system apply rc=$?"

sh "$MODDIR/bin/dvfs.sh" apply >/dev/null 2>&1
L "dvfs apply rc=$?"

# cap watchdog: audit + re-apply every ceiling the module wrote, so Android's
# thermal / BCL daemons cannot silently overwrite it after boot:
if [ -x "$MODDIR/bin/watchdog.sh" ]; then
  sh "$MODDIR/bin/watchdog.sh" status >/dev/null 2>&1
  L "watchdog audit rc=$?"
fi

if [ -f "$ENABLE" ]; then
  sh "$MODDIR/bin/serve.sh" start >/dev/null 2>&1
  L "standalone server requested by $ENABLE"
fi

# record the nodes the module wrote at this boot for the drift detector:
sh "$MODDIR/bin/doctor.sh" drift >/dev/null 2>&1
L "doctor drift recorded rc=$?"
