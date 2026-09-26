#!/system/bin/sh
# Unisoc Tuner GPU core - Z2577 / UMS9230 (Mali-G57 MP1)
# status | apply | set KEY VALUE | dwell SECS | reset
# overridable for offline testing: UT_D UT_P UT_CONF UT_TMP UT_LOG

D=${UT_D:-/sys/class/devfreq/23100000.gpu}
P=${UT_P:-/sys/module/mali_kbase/parameters}
CONF=${UT_CONF:-/data/adb/unisoc-tuner.conf}
TMPD=${UT_TMP:-/data/local/tmp}
LOG=${UT_LOG:-/data/adb/unisoc-tuner.log}
LNAME=tuner
FREQS="384000000 512000000 614400000 768000000 850000000"
MAXHZ=850000000

MODE=stock
FREQHZ=850000000
POLLMS=100
BOOST=0
CAPUNIT=
[ -f "$CONF" ] && . "$CONF"

rd() { cat "$1" 2>/dev/null; }
num() { case "$1" in ''|*[!0-9]*) echo 0 ;; *) echo "$1" ;; esac; }
log() { [ -n "$LOG" ] || return 0; echo "$(date '+%m-%d %H:%M:%S') $LNAME $*" >> "$LOG" 2>/dev/null; return 0; }
short() { case "$1" in "$D"/*) echo "${1#$D/}" ;; "$P"/*) echo "${1#$P/}" ;; *) echo "$1" ;; esac; }

wr() {
  [ -e "$1" ] || { log "fail $(short "$1") missing"; return 1; }
  if echo "$2" > "$1" 2>/dev/null; then log "write $(short "$1")=$2"; return 0; fi
  log "fail $(short "$1")=$2"
  return 1
}

transitions() { sed -n 's/.*Total transition *: *//p' "$D/trans_stat" 2>/dev/null | tail -1; }

wr_wait() {
  n=${3:-10}; i=0
  while [ $i -lt $n ]; do
    if [ -e "$1" ] && echo "$2" > "$1" 2>/dev/null; then
      log "write $(short "$1")=$2 after $i retries"
      return 0
    fi
    sleep 0.2; i=$((i + 1))
  done
  log "fail $(short "$1")=$2 (node never appeared)"
  return 1
}

save() {
  { echo "MODE=$MODE"; echo "FREQHZ=$FREQHZ"; echo "POLLMS=$POLLMS"
    echo "BOOST=$BOOST"; echo "CAPUNIT=$CAPUNIT"; } > "$CONF" 2>/dev/null
  chmod 600 "$CONF" 2>/dev/null
}

cap_unit() {
  if [ -n "$CAPUNIT" ]; then echo "$CAPUNIT"; return; fi
  v=$(num "$(rd $D/thermald_max_freq)")
  if [ "$v" -ge 100000000 ]; then echo 1; else echo 1000; fi
}

set_cap() {
  want=$1
  if [ -z "$CAPUNIT" ]; then
    wr $D/thermald_max_freq $((want / 1000)); sleep 0.3
    if [ "$(num "$(rd $D/max_freq)")" = "$want" ]; then
      CAPUNIT=1000
    else
      wr $D/thermald_max_freq "$want"; sleep 0.3
      if [ "$(num "$(rd $D/max_freq)")" = "$want" ]; then CAPUNIT=1; fi
    fi
    log "cap unit detected $(cap_unit)"
    save
  fi
  u=${CAPUNIT:-1000}
  wr $D/thermald_max_freq $((want / u))
  wr $D/bcl_max_freq $((want / u))
}

apply() {
  [ -e "$D" ] || { echo "err=no devfreq node"; log "fail apply: $D missing"; return 1; }
  log "apply mode=$MODE freq=$FREQHZ poll=$POLLMS boost=$BOOST capunit=${CAPUNIT:-auto}"
  case "$MODE" in
    auto)
      wr $D/governor simple_ondemand
      wr_wait $D/polling_interval "$POLLMS"
      set_cap $MAXHZ ;;
    perf)
      wr $D/governor performance
      set_cap $MAXHZ ;;
    manual)
      wr $D/governor userspace
      wr_wait $D/userspace/set_freq "$FREQHZ"
      set_cap $MAXHZ ;;
    cap)
      wr $D/governor simple_ondemand
      wr_wait $D/polling_interval "$POLLMS"
      set_cap "$FREQHZ" ;;
    *)
      log "stock mode, nothing written"
      return 0 ;;
  esac
  wr $P/gpu_boost_level2 "$BOOST"
  log "apply done mode=$MODE"
}

status() {
  echo "mode=$MODE"
  echo "freqhz=$FREQHZ"
  echo "pollms=$POLLMS"
  echo "boost=$BOOST"
  echo "capunit=$(cap_unit)"
  echo "governor=$(rd $D/governor)"
  echo "curhz=$(num "$(rd $D/cur_freq)")"
  echo "minhz=$(num "$(rd $D/min_freq)")"
  echo "maxhz=$(num "$(rd $D/max_freq)")"
  echo "thermald=$(num "$(rd $D/thermald_max_freq)")"
  echo "bcl=$(num "$(rd $D/bcl_max_freq)")"
  echo "trans=$(num "$(transitions)")"
  echo "util=$(rd /sys/kernel/debug/mali0/dvfs_utilization | tr '\n' ' ')"
  echo "freqlist=$FREQS"
}

dwell() {
  secs=$(num "${1:-10}")
  [ "$secs" -lt 1 ] && secs=10
  n=$((secs * 10)); i=0; f=$TMPD/ut.dwell.$$
  a=$(num "$(transitions)")
  : > "$f"
  while [ $i -lt $n ]; do rd $D/cur_freq >> "$f"; sleep 0.1; i=$((i + 1)); done
  echo "window=$secs"
  echo "trans_delta=$(( $(num "$(transitions)") - a ))"
  sort -n "$f" | uniq -c | while read c hz; do echo "dwell=$(($(num "$hz") / 1000000)):$c"; done
  rm -f "$f"
}

setkv() {
  k=$1; v=$2
  case "$k" in
    MODE)
      case "$v" in stock|auto|perf|manual|cap) MODE=$v ;; *) echo "err=bad mode"; return 1 ;; esac ;;
    FREQHZ)
      case " $FREQS " in *" $v "*) FREQHZ=$v ;; *) echo "err=bad freq"; return 1 ;; esac ;;
    POLLMS)
      w=$(num "$v")
      if [ "$w" -ge 20 ] && [ "$w" -le 400 ]; then POLLMS=$w; else echo "err=range 20-400"; return 1; fi ;;
    BOOST)
      b=$(num "$v")
      if [ "$b" -ge 0 ] && [ "$b" -le 3 ]; then BOOST=$b; else echo "err=range 0-3"; return 1; fi ;;
    CAPUNIT)
      case "$v" in 1|1000) CAPUNIT=$v ;; *) echo "err=1 or 1000"; return 1 ;; esac ;;
    *)
      echo "err=unknown key"; return 1 ;;
  esac
  save
  apply
  status
}

reset() {
  log "reset to vendor defaults"
  wr $D/governor simple_ondemand
  sleep 0.5
  set_cap $MAXHZ
  wr $P/gpu_boost_level2 0
  MODE=stock; FREQHZ=850000000; POLLMS=100; BOOST=0
  save
  status
}

case "$1" in
  status|"") status ;;
  apply)     apply ;;
  set)       setkv "$2" "$3" || log "reject set $2=$3" ;;
  dwell)     dwell "$2" ;;
  reset)     reset ;;
  *)         echo "usage: tuner.sh status|apply|set KEY VALUE|dwell SECS|reset" ;;
esac
