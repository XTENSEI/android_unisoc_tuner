#!/system/bin/sh
# Unisoc Tuner doctor - reports which tuning nodes exist on this device
# doctor.sh              full report
# doctor.sh log [n]      tail of the boot/write log
# doctor.sh logold [n]   tail of the previous boot log
# doctor.sh drift        node drift between the last two boots
# doctor.sh watchdog     cap watchdog report
# overridable for offline testing: UT_D UT_P UT_CPU UT_DEVFREQ UT_THERMAL UT_LOG UT_TMP UT_MODDIR

HERE=${0%/*}
[ -d "$HERE" ] || HERE=.
case "$HERE" in
  */bin) MODDIR=${UT_MODDIR:-$(dirname "$(dirname "$HERE")")} ;;
  *)     MODDIR=${UT_MODDIR:-$HERE} ;;
esac

D=${UT_D:-/sys/class/devfreq/23100000.gpu}
P=${UT_P:-/sys/module/mali_kbase/parameters}
CPU=${UT_CPU:-/sys/devices/system/cpu}
DEVFREQ=${UT_DEVFREQ:-/sys/class/devfreq}
THERMAL=${UT_THERMAL:-/sys/class/thermal}
LOG=${UT_LOG:-/data/adb/unisoc-tuner.log}
TMPD=${UT_TMP:-/data/local/tmp}
NOTEF=$TMPD/ut.doctor.$$

rd() { cat "$1" 2>/dev/null; }
val() { v=$(rd "$1"); [ -n "$v" ] && echo "$v" || echo "(empty)"; }
perm() { ls -l "$1" 2>/dev/null | cut -c1-10 | tr -d '\n'; }
note() { echo "  $1" >> "$NOTEF" 2>/dev/null; return 0; }
lines() { [ -f "$1" ] && wc -l < "$1" 2>/dev/null | tr -d ' ' || echo 0; }
md5() { md5sum "$1" 2>/dev/null | cut -c1-32; }

att() {
  if [ -e "$1" ]; then echo "  $(basename "$1") = $(val "$1")  [$(perm "$1")]"
  else echo "  $(basename "$1"): missing"; fi
}

hunt() {
  hits=$(find /sys/devices -maxdepth 8 -name "$1" 2>/dev/null)
  echo "- $1:"
  if [ -n "$hits" ]; then
    for h in $hits; do
      h=$(basename "$h")
      echo "  $h = $(val "$h")  [$(perm "$h")]"
    done
  else
    echo "  none"
  fi
}

nc_state() {
  if command -v nc >/dev/null 2>&1; then echo nc
  elif toybox nc 2>&1 | grep -qi usage; then echo "toybox nc"
  else echo missing
  fi
}

BOOTIDF=$TMPD/unisoc-tuner.bootid
BOOTID=
[ -f "$BOOTIDF" ] && BOOTID=$(cat "$BOOTIDF" 2>/dev/null)
[ -n "$BOOTID" ] || BOOTID=$(head -c 8 /dev/urandom | od -An -tx1 | tr -d ' \n')
echo "$BOOTID" > "$BOOTIDF" 2>/dev/null

STATE=$TMPD/ut.doctor.state

record_nodes() {
  : > "$STATE"
  for f in "$D"/governor "$D"/cur_freq "$D"/min_freq "$D"/max_freq \
           "$D"/thermald_max_freq "$D"/bcl_max_freq \
           "$P"/gpu_boost_level2 \
           "$CPU"/cpufreq/policy0/scaling_governor "$CPU"/cpufreq/policy0/scaling_max_freq \
           "$CPU"/cpufreq/policy1/scaling_governor "$CPU"/cpufreq/policy1/scaling_max_freq \
           "$DEVFREQ"/scene-frequency/governor "$DEVFREQ"/scene-frequency/max_freq; do
    [ -e "$f" ] || continue
    printf '%s %s %s\n' "$f" "$(md5 "$f")" "$(stat -c %Y "$f" 2>/dev/null || echo 0)" >> "$STATE"
  done
}

compare_state() {
  if [ ! -f "$PREV_STATE" ]; then echo "no previous boot state"; return 0; fi
  n1=$(lines "$STATE")
  n2=$(lines "$PREV_STATE")
  echo "nodes recorded at boot: $n1"
  echo "nodes recorded at last boot: $n2"
  echo
  echo "missing or moved (in the last boot, not the current one):"
  sort "$PREV_STATE" > "$TMPD"/psort 2>/dev/null
  sort "$STATE" > "$TMPD"/ssort 2>/dev/null
  [ -f "$TMPD/psort" ] && [ -f "$TMPD/ssort" ] && comm -23 "$TMPD/psort" "$TMPD/ssort" | while read -r p o m; do
    b=$(basename "$p")
    echo "  - $b -> gone or moved"
  done
  rm -f "$TMPD/psort" "$TMPD/ssort"
  echo "  (none)"
  echo
  echo "content drift (same path, different contents):"
  for p in $(awk '{print $1}' "$STATE"); do
    if [ -e "$p" ]; then
      c=$(md5 "$p")
      o=$(awk -v k="$p" '$1 == k {print $2}' "$PREV_STATE")
      [ -n "$o" ] && [ "$c" != "$o" ] && echo "  changed $p"
    fi
  done
  echo "  (none)"
}

bootdiff() {
  if [ ! -f "$LOG" ]; then echo "no current boot log"; return 0; fi
  if [ ! -f "$LOG.old" ]; then echo "no previous boot log"; return 0; fi
  cur=$NOTEF.cur; old=$NOTEF.old
  sed 's/^[0-9][0-9]-[0-9][0-9] [0-9][0-9]:[0-9][0-9]:[0-9][0-9] //' "$LOG" | sort -u > "$cur"
  sed 's/^[0-9][0-9]-[0-9][0-9] [0-9][0-9]:[0-9][0-9]:[0-9][0-9] //' "$LOG.old" | sort -u > "$old"
  echo "this boot:  $(lines "$LOG") lines, $(lines "$cur") distinct"
  echo "last boot:  $(lines "$LOG.old") lines, $(lines "$old") distinct"
  echo
  echo "only in this boot:"
  add=$(comm -23 "$cur" "$old")
  if [ -n "$add" ]; then printf '%s\n' "$add" | sed 's/^/  + /'; else echo "  (nothing new)"; fi
  echo "only in the last boot:"
  del=$(comm -13 "$cur" "$old")
  if [ -n "$del" ]; then printf '%s\n' "$del" | sed 's/^/  - /'; else echo "  (nothing dropped)"; fi
  rm -f "$cur" "$old"
}

report() {
  echo "unisoc tuner doctor"
  echo "kernel $(uname -r)"
  echo
  echo "-- module --"
  found=
  for d in /data/adb/modules/unisoc-tuner /data/adb/modules/unisoc-gpu-tuner \
           /data/adb/modules_update/unisoc-tuner /data/adb/modules_update/unisoc-gpu-tuner; do
    [ -f "$d/module.prop" ] || continue
    found=1
    echo "  $d id=$(sed -n 's/^id=//p' "$d/module.prop" 2>/dev/null) version=$(sed -n 's/^version=//p' "$d/module.prop" 2>/dev/null)"
    files=
    for f in "$d"/bin/*.sh "$d"/webroot/*; do
      [ -f "$f" ] && files="$files ${f#$d/}"
    done
    echo "    files:$files"
  done
  [ -n "$found" ] || note "no module dir under /data/adb/modules* - is the module installed?"
  [ -f /data/adb/modules/unisoc-gpu-tuner/module.prop ] && note "old module /data/adb/modules/unisoc-gpu-tuner is still installed, remove it"
  echo "  running copy: $MODDIR"

  echo
  echo "-- gpu devfreq --"
  if [ -d "$D" ]; then
    for f in governor cur_freq min_freq max_freq target_freq polling_interval trans_stat \
             available_frequencies available_governors bcl_max_freq thermald_max_freq userspace/set_freq; do
      att "$D/$f"
    done
    echo "  dir: $(ls "$D" 2>/dev/null | tr '\n' ' ')"
  else
    echo "  $D missing"
    note "gpu devfreq node missing - mali_kbase not loaded, or a different node name"
  fi

  echo
  echo "-- mali_kbase parameters --"
  if [ -d "$P" ]; then
    w=; r=
    for f in "$P"/*; do
      [ -f "$f" ] || continue
      if [ -w "$f" ]; then w="$w $(basename "$f")=$(val "$f")"; else r="$r $(basename "$f")"; fi
    done
    echo "  writable:$w"
    echo "  read-only:$r"
  else
    echo "  $P missing"
  fi

  echo
  echo "-- debugfs --"
  if [ -r /sys/kernel/debug/mali0/dvfs_utilization ]; then
    echo "  dvfs_utilization: $(val /sys/kernel/debug/mali0/dvfs_utilization | tr '\n' ' ')"
  else
    echo "  /sys/kernel/debug/mali0 not readable"
    note "mount -t debugfs none /sys/kernel/debug for gpu utilization"
  fi

  echo
  echo "-- cpu --"
  n=0
  for p in $CPU/cpufreq/policy*; do
    [ -d "$p" ] || continue
    n=$((n + 1))
    echo "  $(basename "$p") cpu=$(rd $p/related_cpus | tr ' ' ',') gov=$(rd $p/scaling_governor) cur=$(rd $p/scaling_cur_freq) min=$(rd $p/scaling_min_freq) max=$(rd $p/scaling_max_freq)"
    echo "    freqs     $(rd $p/scaling_available_frequencies)"
    echo "    governors $(rd $p/scaling_available_governors | tr '\n' ' ')"
  done
  [ "$n" -gt 0 ] || { echo "  no cpufreq policies"; note "no cpufreq/policy* nodes, cpu tuning unavailable"; }

  echo
  echo "-- frequency limit nodes --"
  hunt bcl_max_freq
  hunt thermald_max_freq

  echo
  echo "-- devfreq devices --"
  for d in $DEVFREQ/*; do
    [ -d "$d" ] || continue
    echo "  $(basename "$d") cur=$(rd $d/cur_freq) gov=$(rd $d/governor) govw=$([ -w "$d/governor" ] && echo y || echo n) maxw=$([ -w "$d/max_freq" ] && echo y || echo n)"
  done

  echo
  echo "-- thermal zones --"
  for t in $THERMAL/thermal_zone*; do
    [ -d "$t" ] || continue
    echo "  $(basename "$t") type=$(rd $t/type) temp_mdeg=$(rd $t/temp)"
  done

  echo
  echo "-- loaded tuning modules --"
  m=
  for x in mali_kbase trusty trusty_virtio unisoc_mm_emem sprd_freq_limit sprd_cpu_cooling sprd_ddr_dvfs mmdvfs; do
    [ -d "/sys/module/$x" ] && m="$m $x"
  done
  if [ -n "$m" ]; then echo " $m"; else echo "  none found under /sys/module"; fi

  echo
  echo "-- standalone server --"
  echo "  netcat: $(nc_state)"
  if [ -f "$TMPD/ut.serve.pid" ]; then
    echo "  pid file: $(cat "$TMPD/ut.serve.pid" 2>/dev/null), token in $TMPD/ut.serve.token"
    echo "  start at boot: $([ -f "$TMPD/ut.serve.enable" ] && echo yes || echo 'no, touch ut.serve.enable to enable')"
  else
    echo "  server not running"
  fi
  s=
  for f in "$MODDIR"/bin/*.sh; do [ -f "$f" ] && s="$s $(basename "$f")"; done
  echo "  scripts:$s"

  echo
  echo "-- config --"
  for c in /data/adb/unisoc-tuner.conf /data/adb/unisoc-tuner-sys.conf /data/adb/unisoc-tuner-dvfs.conf; do
    if [ -f "$c" ]; then
      echo "  $c"
      sed 's/^/    /' "$c" 2>/dev/null
    else
      echo "  $c not written yet"
    fi
  done

  echo
  echo "-- log --"
  if [ -f "$LOG" ]; then
    echo "  $LOG: $(lines "$LOG") lines"
  else
    echo "  $LOG: not created yet"
  fi
  [ -f "$LOG.old" ] && echo "  $LOG.old: $(lines "$LOG.old") lines (previous boot)"

  echo
  echo "-- notes --"
  if [ -s "$NOTEF" ]; then cat "$NOTEF"; else echo "  nothing unusual"; fi

  echo
  echo "-- watchdog --"
  sh "$MODDIR/bin/watchdog.sh" doctor

  echo
  echo "-- boot drift --"
  if [ -f "$STATE" ]; then
    PREV_STATE=$TMPD/ut.doctor.prev
    if [ -f "$PREV_STATE" ]; then
      compare_state
    else
      echo "no previous boot recorded"
    fi
  else
    echo "no state recorded yet"
  fi
}

case "$1" in
  log)
    if [ -f "$LOG" ]; then tail -n "${2:-30}" "$LOG"; else echo "no boot log yet"; fi ;;
  logold)
    if [ -f "$LOG.old" ]; then tail -n "${2:-30}" "$LOG.old"; else echo "no previous boot log"; fi ;;
  drift)
    PREV_STATE=$TMPD/ut.doctor.prev
    if [ -f "$PREV_STATE" ]; then
      PREV_STATE_CP=$TMPD/ut.doctor.prev.$(date +%s)
      cp "$PREV_STATE" "$PREV_STATE_CP"
      PREV_STATE=$PREV_STATE_CP
    fi
    record_nodes
    compare_state
    ;;
  watchdog)
    sh "$MODDIR/bin/watchdog.sh" doctor
    ;;
  diff)
    bootdiff
    ;;
  *)
    report
    ;;
esac
