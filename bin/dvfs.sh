#!/system/bin/sh
# Unisoc Tuner memory/media devfreq profiles - Z2577 / UMS9230
# status | apply | set KEY VALUE | reset
# overridable for offline testing: UT_DEVFREQ UT_CONF UT_LOG UT_SKIP

DEVFREQ=${UT_DEVFREQ:-/sys/class/devfreq}
CONF=${UT_CONF:-/data/adb/unisoc-tuner-dvfs.conf}
LOG=${UT_LOG:-/data/adb/unisoc-tuner.log}
LNAME=dvfs
SKIP=${UT_SKIP:-23100000.gpu}

MODE=stock
[ -f "$CONF" ] && . "$CONF"

rd() { cat "$1" 2>/dev/null; }
num() { case "$1" in ''|*[!0-9]*) echo 0 ;; *) echo "$1" ;; esac; }
log() { [ -n "$LOG" ] || return 0; echo "$(date '+%m-%d %H:%M:%S') $LNAME $*" >> "$LOG" 2>/dev/null; return 0; }
key() { printf '%s' "$1" | tr -c 'a-zA-Z0-9' '_'; }
nm_of() { basename "$1"; }
devices() { for d in $DEVFREQ/*; do [ -d "$d" ] || continue; [ "$(nm_of "$d")" = "$SKIP" ] && continue; echo "$d"; done; }
govs_of() { rd "$1/available_governors" | tr ' \n' ','; }
freqs_of() { rd "$1/available_frequencies" | tr ' \n' ','; }
has_gov() { case ",$2," in *",$1,"*) return 0 ;; *) return 1 ;; esac; }

wr() {
  [ -e "$1" ] || { log "fail $(nm_of "$(dirname "$1")")/$(basename "$1") missing"; return 1; }
  if echo "$2" > "$1" 2>/dev/null; then log "write $(nm_of "$(dirname "$1")")/$(basename "$1")=$2"; return 0; fi
  log "fail $(nm_of "$(dirname "$1")")/$(basename "$1")=$2"
  return 1
}

sel()    { eval "v=\$SEL_$(key "$1")"; echo "${v:-}"; }
maxsel() { eval "v=\$MAXV_$(key "$1")"; echo "${v:-}"; }
def()    { eval "v=\$DEF_$(key "$1")"; echo "${v:-}"; }
defmax() { eval "v=\$DEFMAX_$(key "$1")"; echo "${v:-}"; }
setv()   { eval "$1=\$2"; }

find_dev() {
  for d in $(devices); do
    [ "$(key "$(nm_of "$d")")" = "$1" ] && { echo "$d"; return 0; }
  done
  return 1
}

save() {
  { echo "MODE=$MODE"
    for d in $(devices); do
      n=$(nm_of "$d"); k=$(key "$n")
      s=$(sel "$n");    [ -n "$s" ] && echo "SEL_$k=$s"
      m=$(maxsel "$n"); [ -n "$m" ] && echo "MAXV_$k=$m"
      g=$(def "$n");    [ -n "$g" ] && echo "DEF_$k=$g"
      x=$(defmax "$n"); [ -n "$x" ] && echo "DEFMAX_$k=$x"
    done
  } > "$CONF" 2>/dev/null
  chmod 600 "$CONF" 2>/dev/null
}

status() {
  echo "mode=$MODE"
  n=0
  for d in $(devices); do
    name=$(nm_of "$d")
    w=$([ -w "$d/governor" ] && echo 1 || echo 0)
    mw=$([ -w "$d/max_freq" ] && echo 1 || echo 0)
    echo "dv$n=$name|$(rd $d/governor)|$(num "$(rd $d/cur_freq)")|$(govs_of "$d")|$(freqs_of "$d")|$(num "$(rd $d/min_freq)")|$(num "$(rd $d/max_freq)")|$w$mw|$(sel "$name")|$(maxsel "$name")|$(key "$name")"
    n=$((n + 1))
  done
  echo "ndv=$n"
}

apply() {
  if [ "$MODE" = stock ]; then log "stock mode, nothing written"; return 0; fi
  log "apply mode=$MODE"
  for d in $(devices); do
    name=$(nm_of "$d"); k=$(key "$name")
    if [ -z "$(def "$name")" ]; then
      setv "DEF_$k" "$(rd $d/governor)"
      setv "DEFMAX_$k" "$(num "$(rd $d/max_freq)")"
    fi
    want=
    case "$MODE" in
      perf)      if has_gov performance "$(govs_of "$d")"; then want=performance; fi ;;
      powersave) if has_gov powersave "$(govs_of "$d")"; then want=powersave; fi ;;
      auto)      want=$(def "$name") ;;
      custom)    want=$(sel "$name"); [ -n "$want" ] || want=$(def "$name") ;;
    esac
    if [ -n "$want" ]; then
      wr "$d/governor" "$want"
    else
      log "skip $name, no $MODE governor offered"
    fi
    if [ "$MODE" = custom ] && [ -w "$d/max_freq" ]; then
      mv=$(maxsel "$name")
      if [ -n "$mv" ] && [ "$mv" != 0 ]; then wr "$d/max_freq" "$mv"; fi
    fi
  done
  save
  log "apply done mode=$MODE"
}

setkv() {
  k=$1; v=$2
  case "$k" in
    MODE)
      case "$v" in stock|perf|powersave|auto|custom) MODE=$v ;; *) echo "err=bad mode"; return 1 ;; esac ;;
    GOV:*)
      kk=${k#GOV:}; d=$(find_dev "$kk") || { echo "err=no such device"; return 1; }
      if has_gov "$v" "$(govs_of "$d")"; then setv "SEL_$kk" "$v"; else echo "err=governor not available"; return 1; fi ;;
    MAX:*)
      kk=${k#MAX:}; d=$(find_dev "$kk") || { echo "err=no such device"; return 1; }
      m=$(num "$v")
      if [ "$m" = 0 ]; then
        setv "MAXV_$kk" 0
      else
        case ",$(freqs_of "$d" | tr ' ' ',')," in
          *",$m,"*) setv "MAXV_$kk" "$m" ;;
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
  for d in $(devices); do
    name=$(nm_of "$d"); k=$(key "$name")
    g=$(def "$name")
    [ -n "$g" ] && wr "$d/governor" "$g"
    x=$(defmax "$name")
    if [ -n "$x" ] && [ -w "$d/max_freq" ]; then wr "$d/max_freq" "$x"; fi
    setv "SEL_$k" ""
    setv "MAXV_$k" 0
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
  *)         echo "usage: dvfs.sh status|apply|set KEY VALUE|reset" ;;
esac
