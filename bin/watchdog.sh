#!/system/bin/sh
# Unisoc Tuner cap watchdog - re-applies GPU, CPU and devfreq ceilings that
# Android's thermal / BCL daemons may overwrite after boot.
# usage: watchdog.sh status|doctor|reset

HERE=${0%/*}
[ -d "$HERE" ] || HERE=.
case "$HERE" in
  */bin) MODDIR=${UT_MODDIR:-$(dirname "$HERE")} ;;
  *)     MODDIR=${UT_MODDIR:-$HERE} ;;
esac

D=${UT_D:-/sys/class/devfreq/23100000.gpu}
P=${UT_P:-/sys/module/mali_kbase/parameters}
UT_CPU=${UT_CPU:-/sys/devices/system/cpu}
UT_DEVFREQ=${UT_DEVFREQ:-/sys/class/devfreq}
TH=${UT_THERMAL:-/sys/class/thermal}
LOG=${UT_LOG:-/data/adb/unisoc-tuner.log}
TMPD=${UT_TMP:-/data/local/tmp}
LNAME=watch

# the kernel boot id is stable inside a boot and differs between boots, so the
# per-boot files are scoped to it (no dependency on od being installed)
bootid() {
  for f in /proc/sys/kernel/random/boot_id /proc/sys/kernel/random/uuid; do
    if [ -r "$f" ]; then
      tr -d '-' < "$f" 2>/dev/null
      return 0
    fi
  done
  head -c 8 /dev/urandom 2>/dev/null | od -An -tx1 2>/dev/null | tr -d ' \n'
}

BOOTIDF=$TMPD/unisoc-tuner.bootid
BOOTID=
[ -f "$BOOTIDF" ] && BOOTID=$(cat "$BOOTIDF" 2>/dev/null)
[ -n "$BOOTID" ] || BOOTID=$(bootid)
[ -n "$BOOTID" ] || BOOTID=unknown
echo "$BOOTID" > "$BOOTIDF" 2>/dev/null

# Persistent per-boot reference: records each node's ORIGINAL kernel value once,
# the first time it is seen in a boot. The file is scoped to the bootid so it
# survives subsequent watchdog re-runs (status) within the same boot, but is
# cleared at reset. A later daemon drift cannot overwrite the pristine
# reference and the re-apply is a real correction.
CEIL=$TMPD/unisoc-tuner.ceil.$BOOTID
# thermal zones are reference only: they are read only, and writing a recorded
# temperature back into a zone would be nonsense
ZREF=$TMPD/unisoc-tuner.zones.$BOOTID

rd() { cat "$1" 2>/dev/null; }
num() { case "$1" in ''|*[!0-9]*) echo 0 ;; *) echo "$1" ;; esac; }
lines() { [ -f "$1" ] && wc -l < "$1" 2>/dev/null | tr -d ' ' || echo 0; }
L() { echo "$(date '+%m-%d %H:%M:%S') $LNAME $*" >> "$LOG" 2>/dev/null; return 0; }
log() { L "$*"; }

wr() {
  [ -e "$1" ] || { log "fail $(basename "$1") missing"; return 1; }
  if echo "$2" > "$1" 2>/dev/null; then
    log "write $(basename "$1")=$2"
    return 0
  fi
  log "fail $(basename "$1")=$2"
  return 1
}

seed_ceils() {
  # Record the ORIGINAL kernel value for each ceiling node. The kernel writes
  # these values at boot; Android's thermal / BCL daemons may overwrite them
  # later. We record each node only once per boot (first time seen). Because
  # the reference file is persistent across watchdog re-runs in this boot, a
  # node whose live value has already drifted is NOT re-read as the new
  # reference; the pristine value recorded earlier is left in place and
  # apply_ceils later restores it.
  for f in "$D"/thermald_max_freq "$D"/bcl_max_freq "$P"/gpu_boost_level2; do
    if [ -e "$f" ]; then
      n=$(cat "$f" 2>/dev/null)
      # Only record if we haven't recorded this node for this boot:
      if ! grep -q "^$f " "$CEIL" 2>/dev/null; then
        printf '%s %s\n' "$f" "$n" >> "$CEIL"
      fi
    fi
  done
  # the cpu ceilings the module just applied: seeded here so a later thermal or
  # bcl write is corrected back to what the module decided, not to the drift
  for p in $(ls -d "$UT_CPU"/cpufreq/policy* 2>/dev/null); do
    f=$p/scaling_max_freq
    [ -e "$f" ] || continue
    n=$(cat "$f" 2>/dev/null)
    if ! grep -q "^$f " "$CEIL" 2>/dev/null; then
      printf '%s %s\n' "$f" "$n" >> "$CEIL"
    fi
  done
  for f in "$TH"/thermal_zone*; do
    [ -e "$f" ] || continue
    n=$(cat "$f"/temp 2>/dev/null)
    if ! grep -q "^$f " "$ZREF" 2>/dev/null; then
      printf '%s %s\n' "$f" "$n" >> "$ZREF"
    fi
  done
}

apply_ceils() {
  n=$(lines "$CEIL")
  i=0
  while [ $i -lt $n ]; do
    f=$(sed -n "$((i + 1))p" "$CEIL" | cut -d' ' -f1)
    v=$(sed -n "$((i + 1))p" "$CEIL" | cut -d' ' -f2)
    if [ -e "$f" ]; then
      wr "$f" "$v"
    else
      log "drift missing $(basename "$f")"
    fi
    i=$((i + 1))
  done
}

main_loop() {
  seed_ceils
  apply_ceils
}

case "$1" in
  doctor)
    echo "unisoc tuner cap watchdog"
    echo "kernel $(uname -r)"
    echo "bootid $BOOTID"
    echo "ceil records: $(lines "$CEIL")"
    echo "thermal records: $(lines "$ZREF")"
    echo
    echo "-- gpu --"
    if [ -d "$D" ]; then
      for f in thermald_max_freq bcl_max_freq; do
        if [ -e "$D/$f" ]; then echo "  $f = $(cat "$D/$f"); [module-written]"
        else echo "  $f: missing"; fi
      done
      if [ -e "$D/governor" ]; then echo "  governor = $(cat "$D/governor")"; else echo "  governor: missing"; fi
    else
      echo "  gpu devfreq node missing"
    fi
    echo
    echo "-- cpu --"
    if [ -d "$UT_CPU"/cpufreq/policy0 ]; then
      i=0
      for p in $(ls -d "$UT_CPU"/cpufreq/policy* 2>/dev/null); do
        echo "  $(basename "$p") gov=$(cat "$p"/scaling_governor) cur=$(cat "$p"/scaling_cur_freq) max=$(cat "$p"/scaling_max_freq)"
        i=$((i + 1))
      done
    else
      echo "  no cpufreq policies"
    fi
    echo
    echo "-- devfreq --"
    n=0
    for d in "$UT_DEVFREQ"/*; do
      [ -d "$d" ] || continue
      n=$((n + 1))
      if [ -e "$d"/thermald_max_freq ]; then
        echo "  $(basename "$d") cur=$(cat "$d"/cur_freq) gov=$(cat "$d"/governor) thermald=$(cat "$d"/thermald_max_freq)  [module-written]"
      else
        echo "  $(basename "$d") cur=$(cat "$d"/cur_freq) gov=$(cat "$d"/governor)"
      fi
    done
    echo "  devices=$n"
    ;;
  reset)
    rm -f "$CEIL" "$ZREF" "$BOOTIDF"
    log "reset (next boot re-seeds)"
    echo "watchdog reset"
    ;;
  status)
    main_loop
    echo "watchdog audit, bootid=$BOOTID"
    echo "records: $(lines "$CEIL")"
    echo "thermal: $(lines "$ZREF")"
    cat "$CEIL" | sed 's/^/  /'
    ;;
  *)
    echo "usage: watchdog.sh status|doctor|reset"
    ;;
esac

