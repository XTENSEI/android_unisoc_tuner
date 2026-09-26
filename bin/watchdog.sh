#!/system/bin/sh
# Unisoc Tuner cap watchdog - re-applies GPU, CPU and devfreq ceilings that
# Android's thermal / BCL daemons may overwrite after boot.
# usage: watchdog.sh status|doctor|reset

HERE=${0%/*}
[ -d "$HERE" ] || HERE=.
case "$HERE" in
  */bin) MODDIR=${UT_MODDIR:-$(dirname "$(dirname "$HERE")")} ;;
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

BOOTIDF=$TMPD/unisoc-tuner.bootid
BOOTID=
[ -f "$BOOTIDF" ] && BOOTID=$(cat "$BOOTIDF" 2>/dev/null)
[ -n "$BOOTID" ] || BOOTID=$(head -c 8 /dev/urandom | od -An -tx1 | tr -d ' \n')
echo "$BOOTID" > "$BOOTIDF" 2>/dev/null

# Persistent per-boot reference: records each node's ORIGINAL kernel value once,
# the first time it is seen in a boot. The file is scoped to the bootid so it
# survives subsequent watchdog re-runs (status) within the same boot, but is
# cleared at reset. A later daemon drift cannot overwrite the pristine
# reference and the re-apply is a real correction.
CEIL=$TMPD/unisoc-tuner.ceil.$BOOTID

rd() { cat "$1" 2>/dev/null; }
num() { case "$1" in ''|*[!0-9]*) echo 0 ;; *) echo "$1" ;; esac; }
L() { echo "$(date '+%m-%d %H:%M:%S') $LNAME $*" >> "$LOG" 2>/dev/null; return 0; }
log() { L "$*"; }

capunit() {
  if [ -n "${CAPUNIT:-}" ]; then echo "$CAPUNIT"; return; fi
  v=$(cat "$D"/thermald_max_freq 2>/dev/null)
  if [ -n "$v" ] && [ "$v" -ge 100000000 ] 2>/dev/null; then CAPUNIT=1; echo 1
  else CAPUNIT=1000; echo 1000; fi
}

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
  for f in "$TH"/thermal_zone*; do
    [ -e "$f" ] || continue
    n=$(cat "$f"/temp 2>/dev/null)
    if ! grep -q "^$f " "$CEIL" 2>/dev/null; then
      printf '%s %s\n' "$f" "$n" >> "$CEIL"
    fi
  done
}

record() { printf '%s %s\n' "$1" "$2" >> "$CEIL"; }

apply_ceils() {
  n=$(wc -l < "$CEIL" 2>/dev/null | tr -d ' ')
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

apply_cpu() {
  for p in $(ls -d "$UT_CPU"/cpufreq/policy* 2>/dev/null); do
    if [ -e "$p/scaling_max_freq" ]; then
      m=$(cat "$p"/scaling_max_freq 2>/dev/null)
      if [ -n "$m" ] && [ "$m" -gt 0 ] 2>/dev/null; then
        wr "$p/scaling_max_freq" "$m"
      fi
    fi
  done
}

main_loop() {
  seed_ceils
  apply_ceils
  apply_cpu
}

case "$1" in
  doctor)
    echo "unisoc tuner cap watchdog"
    echo "kernel $(uname -r)"
    echo "bootid $BOOTID"
    echo "ceil records: $(wc -l < "$CEIL" | tr -d ' ')"
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
    rm -f "$CEIL" "$BOOTIDF"
    log "reset (next boot re-seeds)"
    echo "watchdog reset"
    ;;
  status)
    main_loop
    echo "watchdog audit, bootid=$BOOTID"
    echo "records: $(wc -l < "$CEIL" | tr -d ' ')"
    cat "$CEIL" | sed 's/^/  /'
    ;;
  *)
    echo "usage: watchdog.sh status|doctor|reset"
    ;;
esac

