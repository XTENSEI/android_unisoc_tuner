#!/system/bin/sh
# Unisoc Tuner CPU + system - Z2577 / UMS9230
# status | apply | set KEY VALUE | reset
# overridable for offline testing: UT_CPU UT_DEVFREQ UT_THERMAL UT_CONF UT_LOG

CPU=${UT_CPU:-/sys/devices/system/cpu}
DEVFREQ=${UT_DEVFREQ:-/sys/class/devfreq}
THERMAL=${UT_THERMAL:-/sys/class/thermal}
TMPD=${UT_TMP:-/data/local/tmp}
CONF=${UT_CONF:-/data/adb/unisoc-tuner-sys.conf}
LOG=${UT_LOG:-/data/adb/unisoc-tuner.log}
LNAME=cpu

MODE=stock
GOV0=; GOV1=; GOV2=; GOV3=
MAX0=0; MAX1=0; MAX2=0; MAX3=0
DEFGOV0=; DEFGOV1=; DEFGOV2=; DEFGOV3=
[ -f "$CONF" ] && . "$CONF"

rd() { cat "$1" 2>/dev/null; }
num() { case "$1" in ''|*[!0-9]*) echo 0 ;; *) echo "$1" ;; esac; }
log() { [ -n "$LOG" ] || return 0; echo "$(date '+%m-%d %H:%M:%S') $LNAME $*" >> "$LOG" 2>/dev/null; return 0; }
short() { case "$1" in "$CPU"/cpufreq/*) echo "cpufreq/${1#$CPU/cpufreq/}" ;; *) echo "$1" ;; esac; }
policies() { ls -d $CPU/cpufreq/policy* 2>/dev/null; }
freqs_of() { rd "$1/scaling_available_frequencies" | tr ' ' '\n' | grep -E '^[0-9]+$' | sort -n | tr '\n' ' '; }
govs_of() { rd "$1/scaling_available_governors" | tr '\n' ' '; }
max_avail() { freqs_of "$1" | tr ' ' '\n' | grep -E '^[0-9]+$' | tail -1; }

# any write from the module invalidates the watchdog reference, so the next
# run re-seeds it from the value the module just applied
unwatch() { rm -f "$TMPD"/unisoc-tuner.ceil.* 2>/dev/null; return 0; }

wr() {
  [ -e "$1" ] || { log "fail $(short "$1") missing"; return 1; }
  if echo "$2" > "$1" 2>/dev/null; then log "write $(short "$1")=$2"; return 0; fi
  log "fail $(short "$1")=$2"
  return 1
}

save() {
  { echo "MODE=$MODE"
    echo "GOV0=$GOV0"; echo "GOV1=$GOV1"; echo "GOV2=$GOV2"; echo "GOV3=$GOV3"
    echo "MAX0=$MAX0"; echo "MAX1=$MAX1"; echo "MAX2=$MAX2"; echo "MAX3=$MAX3"
    echo "DEFGOV0=$DEFGOV0"; echo "DEFGOV1=$DEFGOV1"; echo "DEFGOV2=$DEFGOV2"; echo "DEFGOV3=$DEFGOV3"
  } > "$CONF" 2>/dev/null
  chmod 600 "$CONF" 2>/dev/null
}

crec() {
  p=$1
  caps=$(ls "$p" 2>/dev/null | grep 'max_freq$' | grep -v '^scaling_max_freq$' | while read f; do
    printf '%s:%s,' "$f" "$(num "$(rd "$p/$f")")"
  done)
  printf '%s|%s|%s|%s|%s|%s|%s|%s|%s' \
    "$p" "$(rd $p/related_cpus)" "$(rd $p/scaling_governor)" \
    "$(num "$(rd $p/scaling_cur_freq)")" "$(num "$(rd $p/scaling_min_freq)")" \
    "$(num "$(rd $p/scaling_max_freq)")" \
    "$(freqs_of "$p" | tr ' ' ',' | sed 's/ $//')" "$(govs_of "$p" | tr ' ' ',' | sed 's/ $//')" "$caps"
}

status() {
  echo "mode=$MODE"
  n=0
  for p in $(policies); do
    eval "g=\$GOV$n"; eval "m=\$MAX$n"
    echo "c$n=$(crec "$p")||$g|$m"
    n=$((n + 1))
  done
  echo "nclus=$n"

  n=0
  for d in $DEVFREQ/*; do
    [ -d "$d" ] || continue
    echo "df$n=$(basename "$d")|$(num "$(rd $d/cur_freq)")|$(rd $d/governor)"
    n=$((n + 1))
  done
  echo "ndf=$n"

  n=0
  for t in $THERMAL/thermal_zone*; do
    [ -d "$t" ] || continue
    echo "tz$n=$(rd $t/type)|$(num "$(rd $t/temp)")"
    n=$((n + 1))
  done
  echo "ntz=$n"
}

apply() {
  unwatch
  if [ "$MODE" = stock ]; then log "stock mode, nothing written"; return 0; fi
  log "apply mode=$MODE"
  i=0
  for p in $(policies); do
    eval "d=\$DEFGOV$i"
    if [ -z "$d" ]; then eval "DEFGOV$i=$(rd $p/scaling_governor)"; fi
    case "$MODE" in
      perf)
        wr $p/scaling_governor performance ;;
      balanced)
        for g in schedutil ondemand interactive; do
          case " $(govs_of "$p") " in *" $g "*) wr $p/scaling_governor "$g"; break ;; esac
        done ;;
      custom)
        eval "g=\$GOV$i"; eval "m=\$MAX$i"
        [ -n "$g" ] && wr $p/scaling_governor "$g"
        if [ "$(num "$m")" -gt 0 ]; then
          wr $p/scaling_max_freq "$m"
        else
          wr $p/scaling_max_freq "$(max_avail "$p")"
        fi ;;
    esac
    i=$((i + 1))
  done
  save
  log "apply done mode=$MODE"
}

setkv() {
  k=$1; v=$2
  case "$k" in
    MODE)
      case "$v" in stock|perf|balanced|custom) MODE=$v ;; *) echo "err=bad mode"; return 1 ;; esac ;;
    GOV[0-9])
      i=${k#GOV}; p=$(policies | sed -n "$((i + 1))p")
      [ -n "$p" ] || { echo "err=no such cluster"; return 1; }
      case " $(govs_of "$p") " in *" $v "*) eval "GOV$i=$v" ;; *) echo "err=governor not available"; return 1 ;; esac ;;
    MAX[0-9])
      i=${k#MAX}; p=$(policies | sed -n "$((i + 1))p")
      [ -n "$p" ] || { echo "err=no such cluster"; return 1; }
      m=$(num "$v")
      if [ "$m" = 0 ]; then
        eval "MAX$i=0"
      else
        case ",$(freqs_of "$p" | tr ' ' ',')," in
          *",$m,"*) eval "MAX$i=$m" ;;
          *) echo "err=freq not available"; return 1 ;;
        esac
      fi ;;
    *)
      echo "err=unknown key"; return 1 ;;
  esac
  save
  apply
  status
}

reset() {
  log "reset to vendor defaults"
  i=0
  for p in $(policies); do
    eval "d=\$DEFGOV$i"
    [ -n "$d" ] && wr $p/scaling_governor "$d"
    wr $p/scaling_max_freq "$(max_avail "$p")"
    eval "GOV$i="; eval "MAX$i=0"
    i=$((i + 1))
  done
  MODE=stock
  save
  status
}

case "$1" in
  status|"") status ;;
  apply)     apply ;;
  set)       setkv "$2" "$3" || log "reject set $2=$3" ;;
  reset)     reset ;;
  *)         echo "usage: system.sh status|apply|set KEY VALUE|reset" ;;
esac
