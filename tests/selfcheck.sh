#!/bin/sh
# Unisoc Tuner self-check - rebuilds fake sysfs trees and exercises every script path.
# usage: sh tests/selfcheck.sh [-v]
# Needs POSIX sh plus coreutils; everything happens under $TMPDIR.

MOD=$(cd "$(dirname "$0")/.." && pwd)
T=${TMPDIR:-/tmp}/ut-selfcheck.$$
V=0
[ "${1:-}" = "-v" ] && V=1

PASS=0
FAILS=0
mkdir -p "$T" || exit 1

ok()   { printf 'ok   %s\n' "$1"; PASS=$((PASS + 1)); }
bad()  { printf 'FAIL %s\n' "$1"; FAILS=$((FAILS + 1)); [ -n "${2:-}" ] && printf '%s\n' "$2" | head -6 | sed 's/^/     /'; return 0; }
has()  { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1" "missing: $3" ;; esac; }
lacks(){ case "$2" in *"$3"*) bad "$1" "unwanted: $3" ;; *) ok "$1" ;; esac; }
show() { [ "$V" = 1 ] && printf '  $ %s\n%s\n' "$1" "$2"; return 0; }

S=$T/sys
GPU=$S/devfreq/23100000.gpu
PAR=$S/params
CPU=$S/cpu
DV=$S/devfreq
TH=$S/thermal
LOG=$T/tuner.log
mkdir -p "$GPU" "$PAR" "$CPU/cpufreq/policy0" "$CPU/cpufreq/policy1" \
         "$DV/scene-frequency" "$DV/dpu-dvfs" "$DV/read-only-dvfs" "$TH/thermal_zone0" "$T/tmp"

printf 'simple_ondemand\n' > "$GPU/governor"
printf '850000000\n' > "$GPU/cur_freq"
printf '384000000\n' > "$GPU/min_freq"
printf '850000000\n' > "$GPU/max_freq"
printf '50\n' > "$GPU/polling_interval"
printf '200000\n' > "$GPU/thermald_max_freq"
printf '200000\n' > "$GPU/bcl_max_freq"
printf '384000000 512000000 614400000 768000000 850000000\n' > "$GPU/available_frequencies"
printf 'performance simple_ondemand userspace powersave\n' > "$GPU/available_governors"
printf 'Total transition : 100\n' > "$GPU/trans_stat"
printf '0\n' > "$PAR/gpu_boost_level2"
printf '50\n' > "$PAR/gpu_pollingtime"

printf '0 1 2 3 4 5\n' > "$CPU/cpufreq/policy0/related_cpus"
printf 'schedutil\n' > "$CPU/cpufreq/policy0/scaling_governor"
printf '1800000\n' > "$CPU/cpufreq/policy0/scaling_cur_freq"
printf '384000\n' > "$CPU/cpufreq/policy0/scaling_min_freq"
printf '2000000\n' > "$CPU/cpufreq/policy0/scaling_max_freq"
printf '384000 614400 1200000 1800000 2000000\n' > "$CPU/cpufreq/policy0/scaling_available_frequencies"
printf 'schedutil performance powersave\n' > "$CPU/cpufreq/policy0/scaling_available_governors"
printf '1700000\n' > "$CPU/cpufreq/policy0/bcl_max_freq"
printf '2000000\n' > "$CPU/cpufreq/policy0/thermald_max_freq"
printf '6 7\n' > "$CPU/cpufreq/policy1/related_cpus"
printf 'performance\n' > "$CPU/cpufreq/policy1/scaling_governor"
printf '2000000\n' > "$CPU/cpufreq/policy1/scaling_cur_freq"
printf '614400\n' > "$CPU/cpufreq/policy1/scaling_min_freq"
printf '2000000\n' > "$CPU/cpufreq/policy1/scaling_max_freq"
printf '614400 1200000 1800000 2000000\n' > "$CPU/cpufreq/policy1/scaling_available_frequencies"
printf 'schedutil performance\n' > "$CPU/cpufreq/policy1/scaling_available_governors"

printf 'sprd-governor\n' > "$DV/scene-frequency/governor"
printf '1536000000\n' > "$DV/scene-frequency/cur_freq"
printf '768000000\n' > "$DV/scene-frequency/min_freq"
printf '768000000\n' > "$DV/scene-frequency/max_freq"
printf '768000000 1536000000\n' > "$DV/scene-frequency/available_frequencies"
printf 'sprd-governor performance powersave\n' > "$DV/scene-frequency/available_governors"
printf 'sprd-governor\n' > "$DV/dpu-dvfs/governor"
printf '400000000\n' > "$DV/dpu-dvfs/cur_freq"
printf 'sprd-governor powersave\n' > "$DV/dpu-dvfs/available_governors"
printf 'sprd-governor\n' > "$DV/read-only-dvfs/governor"
printf 'sprd-governor\n' > "$DV/read-only-dvfs/available_governors"
chmod 444 "$DV/read-only-dvfs/governor"
printf 'soc-thmzone\n' > "$TH/thermal_zone0/type"
printf '47500\n' > "$TH/thermal_zone0/temp"

rung()   { env UT_D="$GPU" UT_P="$PAR" UT_CONF="$T/gpu.conf" UT_TMP="$T/tmp" UT_LOG="$LOG" sh "$MOD/bin/tuner.sh" "$@" 2>&1; }
runs()   { env UT_CPU="$CPU" UT_DEVFREQ="$DV" UT_THERMAL="$TH" UT_CONF="$T/sys.conf" UT_TMP="$T/tmp" UT_LOG="$LOG" sh "$MOD/bin/system.sh" "$@" 2>&1; }
rund()   { env UT_DEVFREQ="$DV" UT_CONF="$T/dv.conf" UT_TMP="$T/tmp" UT_LOG="$LOG" sh "$MOD/bin/dvfs.sh" "$@" 2>&1; }
rundoc() { env UT_D="$GPU" UT_P="$PAR" UT_CPU="$CPU" UT_DEVFREQ="$DV" UT_THERMAL="$TH" UT_TMP="$T/tmp" UT_LOG="$LOG" sh "$MOD/bin/doctor.sh" "$@" 2>&1; }
runlog() { env UT_D="$GPU" UT_P="$PAR" UT_TMP="$T/tmp" UT_LOG="$LOG" sh "$MOD/service.sh" 2>&1; }

echo "== hygiene =="
for f in "$MOD"/bin/*.sh "$MOD"/*.sh; do
  if sh -n "$f" 2>"$T/syn.err"; then ok "syntax $(basename "$f")"; else bad "syntax $(basename "$f")" "$(cat "$T/syn.err")"; fi
done
if command -v node >/dev/null 2>&1; then
  if node --check "$MOD/webroot/app.js" 2>"$T/js.err"; then ok "syntax app.js"; else bad "syntax app.js" "$(cat "$T/js.err")"; fi
else
  echo "skip app.js (no node)"
fi

na=$(LC_ALL=C grep -r '[^[:print:][:space:]]' "$MOD/webroot" "$MOD/bin" "$MOD"/*.sh "$MOD/README.md" "$MOD/module.prop" 2>/dev/null | grep -v '°' || true)
if [ -z "$na" ]; then ok "ascii only (degree sign allowed)"; else bad "ascii only" "$na"; fi

grep -o 'id="[a-zA-Z0-9_-]*"' "$MOD/webroot/index.html" | sed 's/id="//; s/"$//' | sort -u > "$T/ids"
sed -n '/const IDS = \[/,/];/p' "$MOD/webroot/app.js" | grep -oE "\"[a-z0-9_]+"\" | tr -d "\"" | sort -u > "$T/used"
miss=$(comm -23 "$T/ids" "$T/used")
unused=$(comm -13 "$T/ids" "$T/used")
if [ -z "$miss" ]; then ok "every el() id exists in index.html"; else bad "el() ids missing in html" "$miss"; fi
if [ -z "$unused" ]; then ok "no unused ids in index.html"; else bad "unused ids in html" "$unused"; fi

for r in $(grep -o 'bin/[a-z]*\.sh' "$MOD/webroot/app.js" | sort -u); do
  if [ -f "$MOD/$r" ]; then ok "app.js references $r"; else bad "app.js references $r" "no such file"; fi
done
probe=$(grep -c 'moddir[[:space:]]*=\|modver[[:space:]]*=\|modcpu[[:space:]]*=\|moddv[[:space:]]*=\|moddoc[[:space:]]*=' "$MOD/webroot/app.js" 2>/dev/null)
if [ "$probe" = 5 ]; then ok "probe contract present in app.js"; else bad "probe contract" "found $probe of 5 markers"; fi

echo "== webui =="
APP=$(cat "$MOD/webroot/app.js")
mver=$(sed -n 's/^version=//p' "$MOD/module.prop")
aver=$(sed -n 's/.*modver = "\([^"]*\)".*/\1/p' "$MOD/webroot/app.js" | head -1)
if [ -n "$mver" ] && [ "$mver" = "$aver" ]; then ok "app.js version matches module.prop"; else bad "app.js version matches module.prop" "module.prop=$mver app.js=$aver"; fi
dupid=$(grep -o 'id="[a-zA-Z0-9_-]*"' "$MOD/webroot/index.html" | sort | uniq -d)
if [ -z "$dupid" ]; then ok "no duplicate ids in index.html"; else bad "duplicate ids in index.html" "$dupid"; fi
for c in apply cpreset dvreset refresh bootdiff doctor cmode dmode loglines; do
  has "app.js wires $c" "$APP" "el(\"$c\").addEventListener"
done
for s in tuner system dvfs doctor; do
  has "app.js runs $s.sh" "$APP" "\"$s\""
done
has "app.js uses the manager bridge" "$APP" "bridge.exec("
has "app.js registers the named shell callback" "$APP" "window[name] = ("
has "app.js speaks to serve.sh" "$APP" "/api?t="
has "app.js asks where the module is" "$APP" "/where?t="
lacks "app.js dropped the positional callback" "$APP" "bridge.exec(cmd, (e, o)"

if command -v node >/dev/null 2>&1; then
  if node "$MOD/tests/webui-smoke.js" > "$T/webui.out" 2>&1; then ok "webui smoke passes in node"; else bad "webui smoke passes in node" "$(cat "$T/webui.out")"; fi
else
  echo "skip webui smoke (no node)"
fi

echo "== packaging =="
if command -v zip >/dev/null 2>&1 && command -v unzip >/dev/null 2>&1; then
  P=$T/pkg
  if sh "$MOD/build.sh" "$P" > "$T/pkg.out" 2>&1; then
    z=$(ls "$P"/*.zip 2>/dev/null | head -1)
    if [ -n "$z" ]; then ok "build.sh produced a zip"; else bad "build.sh produced a zip" "$(cat "$T/pkg.out")"; fi
    zl=$(unzip -Z1 "$z" 2>/dev/null)
    has "zip carries module.prop" "$zl" "module.prop"
    has "zip carries the action hook" "$zl" "action.sh"
    has "zip carries the scripts" "$zl" "bin/tuner.sh"
    has "zip carries the watchdog" "$zl" "bin/watchdog.sh"
    has "zip carries the page" "$zl" "webroot/index.html"
    has "zip carries uninstall.sh" "$zl" "uninstall.sh"
    lacks "zip leaves the tests out" "$zl" "tests/"
    lacks "zip leaves the ci out" "$zl" ".github"
    lacks "zip leaves the build script out" "$zl" "build.sh"
  else
    bad "build.sh runs" "$(cat "$T/pkg.out")"
  fi
else
  echo "skip packaging (no zip)"
fi

if command -v git >/dev/null 2>&1; then
  R=$T/notes.git
  mkdir -p "$R"
  G="git -c user.email=gate@example.invalid -c user.name=gate -c commit.gpgsign=false -c tag.gpgsign=false -c init.defaultBranch=main"
  (
    cd "$R" || exit 1
    cp "$MOD/module.prop" . || exit 1
    $G init -q . || exit 1
    $G add -A || exit 1
    $G commit -qm "unisotun: seed the module" || exit 1
    $G tag -a -m v0 v0.9.0 || exit 1
    echo "# change" >> module.prop || exit 1
    $G commit -qam "unisotun: add the thing that changed" || exit 1
    $G tag -a -m v1 v1.0.0 || exit 1
  ) > "$T/notes.setup" 2>&1
  n=$(cd "$R" && sh "$MOD/tools/notes.sh" v1.0.0 2>&1)
  has "release notes name the version" "$n" "Unisoc Tuner $mver"
  has "release notes list the new commits" "$n" "unisotun: add the thing that changed"
  lacks "release notes stop at the previous tag" "$n" "unisotun: seed the module"
  has "release notes say what to flash" "$n" "unisoc-tuner-$mver.zip"
else
  echo "skip release notes (no git)"
fi

echo "== gpu (tuner.sh) =="
o=$(rung status); show "tuner.sh status" "$o"
has "status reports mode" "$o" "mode="
has "status reports governor" "$o" "governor="
has "status reports freq list" "$o" "freqlist="
o=$(rung set MODE auto); show "tuner.sh set MODE auto" "$o"
has "auto applied governor" "$(cat "$GPU/governor")" "simple_ondemand"
has "cap written in khz" "$(cat "$GPU/thermald_max_freq")" "850000"
l=$(cat "$LOG")
has "log records the governor write" "$l" "tuner write governor=simple_ondemand"
has "log records the apply result" "$l" "tuner apply done mode=auto"
o=$(rung set BOOST 9); show "tuner.sh set BOOST 9" "$o"
has "bad boost rejected" "$o" "err=range 0-3"
has "rejected set is logged" "$(cat "$LOG")" "tuner reject set BOOST=9"
o=$(rung set MODE manual); show "tuner.sh set MODE manual" "$o"
has "manual mode without userspace nodes still answers" "$o" "mode=manual"
has "missing userspace node is logged" "$(cat "$LOG")" "fail userspace/set_freq"
o=$(rung dwell 1); show "tuner.sh dwell 1" "$o"
has "dwell window" "$o" "window=1"
has "dwell histogram" "$o" "dwell="
o=$(rung reset); show "tuner.sh reset" "$o"
has "reset restores governor" "$(cat "$GPU/governor")" "simple_ondemand"
has "reset is logged" "$(cat "$LOG")" "tuner reset to vendor defaults"

echo "== cpu (system.sh) =="
o=$(runs status); show "system.sh status" "$o"
has "two clusters" "$o" "nclus=2"
c0=$(printf '%s\n' "$o" | sed -n 's/^c0=//p')
nf=$(printf '%s' "$c0" | awk -F'|' '{print NF}')
if [ "$nf" = 12 ]; then ok "c0 has 12 fields"; else bad "c0 field count" "got $nf"; fi
has "crec separators intact" "$c0" "||"
has "devfreq list present" "$o" "ndf="
o=$(runs set MODE custom); o=$(runs set GOV0 performance); o=$(runs set MAX0 1200000); show "system.sh custom" "$o"
has "cluster governor written" "$(cat "$CPU/cpufreq/policy0/scaling_governor")" "performance"
has "cluster max written" "$(cat "$CPU/cpufreq/policy0/scaling_max_freq")" "1200000"
l=$(cat "$LOG")
has "log shortens cpu paths" "$l" "cpu write cpufreq/policy0/scaling_governor=performance"
o=$(runs set MAX0 999999); show "system.sh bad max" "$o"
has "bad freq rejected" "$o" "err=freq not available"
has "cpu reject is logged" "$(cat "$LOG")" "cpu reject set MAX0=999999"
o=$(runs set MAX0 2000000); has "top frequency accepted" "$o" "2000000"
o=$(runs set MAX0 384000); has "bottom frequency accepted" "$o" "384000"
o=$(runs reset); show "system.sh reset" "$o"
has "reset restores cluster governor" "$(cat "$CPU/cpufreq/policy0/scaling_governor")" "schedutil"

echo "== memory/media (dvfs.sh) =="
o=$(rund status); show "dvfs.sh status" "$o"
has "three non-gpu devices" "$o" "ndv=3"
lacks "gpu is skipped" "$o" "dv0=23100000.gpu"
d0=$(printf '%s\n' "$o" | sed -n 's/^dv0=//p')
nf=$(printf '%s' "$d0" | awk -F'|' '{print NF}')
if [ "$nf" = 11 ]; then ok "dv record has 11 fields"; else bad "dv field count" "got $nf"; fi
o=$(rund apply); show "dvfs.sh apply (stock)" "$o"
has "stock writes nothing" "$(cat "$LOG")" "dvfs stock mode, nothing written"
o=$(rund set MODE perf); show "dvfs.sh set MODE perf" "$o"
has "ddr went to performance" "$(cat "$DV/scene-frequency/governor")" "performance"
has "device without performance is skipped" "$(cat "$LOG")" "dvfs skip dpu-dvfs"
o=$(rund set MODE custom); show "dvfs.sh set MODE custom" "$o"
o=$(rund set GOV:scene_frequency sprd-governor); show "dvfs.sh set governor" "$o"
has "selected governor applied" "$(cat "$DV/scene-frequency/governor")" "sprd-governor"
o=$(rund set MAX:scene_frequency 1536000000); show "dvfs.sh set max" "$o"
has "max frequency written" "$(cat "$DV/scene-frequency/max_freq")" "1536000000"
o=$(rund set GOV:dpu_dvfs nope); show "dvfs.sh bad governor" "$o"
has "bad governor rejected" "$o" "err=governor not available"
o=$(rund set MAX:scene_frequency 999999999); show "dvfs.sh bad freq" "$o"
has "bad freq rejected" "$o" "err=freq not available"
o=$(rund set MAX:nosuch_freq 1); has "unknown device rejected" "$o" "err=no such device"
o=$(rund reset); show "dvfs.sh reset" "$o"
has "reset restores ddr governor" "$(cat "$DV/scene-frequency/governor")" "sprd-governor"
has "reset restores the recorded max" "$(cat "$DV/scene-frequency/max_freq")" "768000000"
has "read-only device write is logged" "$(cat "$LOG")" "fail read-only-dvfs/governor"
has "dvfs reset is logged" "$(cat "$LOG")" "dvfs reset to vendor defaults"

echo "== doctor =="
o=$(rundoc); show "doctor.sh" "$o"
for sec in "-- module --" "-- gpu devfreq --" "-- mali_kbase parameters --" "-- debugfs --" "-- cpu --" \
           "-- frequency limit nodes --" "-- devfreq devices --" "-- thermal zones --" \
           "-- loaded tuning modules --" "-- standalone server --" "-- config --" "-- log --" "-- notes --" \
           "-- watchdog --" "-- boot drift --"; do
  has "doctor section $sec" "$o" "$sec"
done
has "doctor reports cpu clusters" "$o" "policy0 cpu=0,1,2,3,4,5"
has "doctor reports ddr governed" "$o" "scene-frequency cur="
o=$(rundoc log 15); has "doctor log tail" "$o" "dvfs reset to vendor defaults"
o=$(rundoc logold 5); has "doctor logold without a rotated log" "$o" "no previous boot log"

echo "== watchdog + drift =="
wtmp=$T/tmp
mkdir -p $wtmp
wdgpu=$T/sys/devfreq/23100000.gpu
wdp=$T/sys/params
wdcpu=$T/sys/cpu
wddv=$T/sys/devfreq
wdth=$T/sys/thermal
mkdir -p $wdgpu $wdp $wdcpu/cpufreq/policy0 $wdcpu/cpufreq/policy1 $wddv/scene-frequency $wddv/dpu-dvfs $wdth
printf "simple_ondemand\n" > $wdgpu/governor
printf "200000\n" > $wdgpu/thermald_max_freq
printf "200000\n" > $wdgpu/bcl_max_freq
printf "0\n" > $wdp/gpu_boost_level2
printf "0 1 2 3 4 5\n" > $wdcpu/cpufreq/policy0/related_cpus
printf "schedutil\n" > $wdcpu/cpufreq/policy0/scaling_governor
printf "1800000\n" > $wdcpu/cpufreq/policy0/scaling_cur_freq
printf "384000\n" > $wdcpu/cpufreq/policy0/scaling_min_freq
printf "2000000\n" > $wdcpu/cpufreq/policy0/scaling_max_freq
printf "6 7\n" > $wdcpu/cpufreq/policy1/related_cpus
printf "performance\n" > $wdcpu/cpufreq/policy1/scaling_governor
printf "2000000\n" > $wdcpu/cpufreq/policy1/scaling_cur_freq
printf "614400\n" > $wdcpu/cpufreq/policy1/scaling_min_freq
printf "2000000\n" > $wdcpu/cpufreq/policy1/scaling_max_freq
printf "768000000 1536000000\n" > $wddv/scene-frequency/available_frequencies
printf "sprd-governor performance powersave\n" > $wddv/scene-frequency/available_governors
printf "sprd-governor\n" > $wddv/dpu-dvfs/available_governors
printf "384000 614400 1200000 1800000 2000000\n" > $wdcpu/cpufreq/policy0/scaling_available_frequencies
printf "schedutil performance powersave\n" > $wdcpu/cpufreq/policy0/scaling_available_governors
printf "614400 1200000 1800000 2000000\n" > $wdcpu/cpufreq/policy1/scaling_available_frequencies
printf "schedutil performance\n" > $wdcpu/cpufreq/policy1/scaling_available_governors
printf "384000000 512000000 614400000 768000000 850000000\n" > $wdgpu/available_frequencies
printf "performance simple_ondemand userspace powersave\n" > $wdgpu/available_governors
printf "50\n" > $wdgpu/polling_interval
printf "Total transition : 100\n" > $wdgpu/trans_stat

wsep="env UT_D=$wdgpu UT_P=$wdp UT_CPU=$wdcpu UT_DEVFREQ=$wddv UT_THERMAL=$wdth UT_TMP=$wtmp UT_LOG=$LOG"
$wsep sh $MOD/bin/watchdog.sh status > /dev/null 2>&1
wceils=$(cat $T/tmp/unisoc-tuner.ceil.* 2>/dev/null || echo "")
has "watchdog seeds ceil records" "$wceils" "thermald_max_freq 200000"
printf "160000\n" > $wdgpu/thermald_max_freq
$wsep sh $MOD/bin/watchdog.sh status > /dev/null 2>&1
wcap=$(cat $wdgpu/thermald_max_freq 2>/dev/null)
has "watchdog re-applies drifted ceiling (verified)" "$wcap" "200000"
printf "1200000\n" > $wdcpu/cpufreq/policy0/scaling_max_freq
$wsep sh $MOD/bin/watchdog.sh status > /dev/null 2>&1
wcmax=$(cat $wdcpu/cpufreq/policy0/scaling_max_freq 2>/dev/null)
has "watchdog restores the cpu ceiling (verified)" "$wcmax" "2000000"

mkdir -p $wdth/thermal_zone0
printf "47500\n" > $wdth/thermal_zone0/temp
rm -f $T/tmp/unisoc-tuner.ceil.* $T/tmp/unisoc-tuner.zones.*
$wsep sh $MOD/bin/watchdog.sh status > /dev/null 2>&1
wzones=$(cat $T/tmp/unisoc-tuner.zones.* 2>/dev/null || echo "")
has "watchdog records thermal zones" "$wzones" "47500"
lacks "thermal zones stay out of the ceilings" "$(cat $T/tmp/unisoc-tuner.ceil.* 2>/dev/null)" "thermal_zone"
printf "60000\n" > $wdth/thermal_zone0/temp
$wsep sh $MOD/bin/watchdog.sh status > /dev/null 2>&1
wztemp=$(cat $wdth/thermal_zone0/temp 2>/dev/null)
has "watchdog leaves a drifted zone alone (verified)" "$wztemp" "60000"
lacks "the watchdog never writes a temperature" "$(cat "$LOG")" "write temp="

$wsep sh $MOD/bin/watchdog.sh status > /dev/null 2>&1
wceil=$(ls $T/tmp/unisoc-tuner.ceil.* 2>/dev/null | head -1)
env UT_D=$wdgpu UT_P=$wdp UT_TMP=$wtmp UT_LOG=$LOG UT_CONF=$T/tmp/watch.tuner.conf \
  sh $MOD/bin/tuner.sh set MODE cap > /dev/null 2>&1
if [ -n "$wceil" ] && [ ! -f "$wceil" ]; then ok "a module write invalidates the watchdog reference"; else bad "a module write invalidates the watchdog reference" "ceil=$wceil"; fi

rvgpu=$T/sys/devfreq/23100000.gpu
rm -f $T/tmp/ut.doctor.prev $T/tmp/ut.doctor.state
$wsep sh $MOD/bin/doctor.sh drift > /dev/null 2>&1
if cmp -s $T/tmp/ut.doctor.state $T/tmp/ut.doctor.prev; then
  ok "drift promotes this boot record as the next baseline"
else
  bad "drift promotes this boot record as the next baseline" "state and prev differ"
fi
lacks "drift state skips the volatile cur_freq" "$(cat $T/tmp/ut.doctor.state 2>/dev/null)" "cur_freq"
mv $rvgpu $T/tmp/moved.gpu
wdiag=$($wsep sh $MOD/bin/doctor.sh drift 2>&1)
has "doctor drift reports the moved node (verified)" "$wdiag" "gone or moved"
mv $T/tmp/moved.gpu $rvgpu 2>/dev/null
$wsep sh $MOD/bin/doctor.sh drift > /dev/null 2>&1
printf "400000\n" > $wdgpu/thermald_max_freq
wdiag2=$($wsep sh $MOD/bin/doctor.sh drift 2>&1)
has "doctor drift reports a changed value (verified)" "$wdiag2" "changed"
printf "200000\n" > $wdgpu/thermald_max_freq

echo "== entry points from a foreign cwd =="
ecwd=$T/ecwd
mkdir -p $ecwd
elog=$T/entry.log
esep="env UT_D=$wdgpu UT_P=$wdp UT_CPU=$wdcpu UT_DEVFREQ=$wddv UT_THERMAL=$wdth UT_TMP=$wtmp UT_LOG=$elog UT_CONF=$T/tmp/entry.conf"
( cd $ecwd && $esep sh "$MOD/service.sh" ) > $T/entry.out 2>&1
has "service.sh finds its scripts from any cwd (verified)" "$(cat $elog 2>/dev/null)" "tuner apply rc=0"
act=$( cd $ecwd && env UT_D=$wdgpu UT_P=$wdp UT_CONF=$T/tmp/act.conf UT_TMP=$wtmp UT_LOG=$elog sh "$MOD/action.sh" 2>&1 )
has "action.sh cycles the gpu mode from any cwd (verified)" "$act" "GPU mode:"
wdoc=$( cd $ecwd && env UT_TMP=$wtmp UT_LOG=$elog sh "$MOD/bin/doctor.sh" watchdog 2>&1 )
has "doctor.sh finds the watchdog from any cwd (verified)" "$wdoc" "cap watchdog"
lacks "no path errors leak out of the doctor watchdog section" "$wdoc" "No such file"

# the drive tests above applied modes to the fake tree: put the caps back so the
# live webui test reads a known device
printf "200000\n" > $wdgpu/thermald_max_freq
printf "200000\n" > $wdgpu/bcl_max_freq
rm -f $T/tmp/unisoc-tuner.ceil.* $T/tmp/unisoc-tuner.zones.*

echo "== standalone server =="
if command -v nc >/dev/null 2>&1 && command -v curl >/dev/null 2>&1; then
  PORT=$((20000 + ($$ % 20000)))
  SEP="env UT_PORT=$PORT UT_TMP=$T/tmp UT_LOG=$LOG UT_D=$wdgpu UT_P=$wdp UT_CPU=$wdcpu UT_DEVFREQ=$wddv UT_THERMAL=$wdth UT_CONF=$T/tmp/live.conf"
  ( cd $ecwd && $SEP sh "$MOD/bin/serve.sh" start ) > "$T/start.txt" 2>&1
  TOK=$(cat "$T/tmp/ut.serve.token" 2>/dev/null)
  get() {
    i=0
    while [ $i -lt 10 ]; do
      out=$(curl -s --max-time 3 "$1" 2>/dev/null)
      if [ -n "$out" ]; then printf '%s' "$out"; return 0; fi
      i=$((i + 1))
      sleep 0.4
    done
    printf '%s' "$out"
  }
  if [ -n "$TOK" ]; then ok "server wrote a token"; else bad "server token" "$(cat "$T/start.txt")"; fi
  has "page served" "$(get "http://127.0.0.1:$PORT/?t=$TOK")" "Unisoc Tuner"
  has "where reports the module dir" "$(get "http://127.0.0.1:$PORT/where?t=$TOK")" "dir="
  has "api runs a script" "$(get "http://127.0.0.1:$PORT/api?t=$TOK&run=tuner&args=status")" "mode="
  has "bad token rejected" "$(get "http://127.0.0.1:$PORT/api?t=nope&run=tuner&args=status")" "token"
  has "unknown script rejected" "$(get "http://127.0.0.1:$PORT/api?t=$TOK&run=nope&args=status")" "unknown script"
  has "bad args rejected" "$(get "http://127.0.0.1:$PORT/api?t=$TOK&run=tuner&args=set%20MODE%3Brm")" "bad characters"
  if command -v node >/dev/null 2>&1; then
    LIVE="node"
    command -v timeout >/dev/null 2>&1 && LIVE="timeout 180 node"
    if UT_LIVE_URL="http://127.0.0.1:$PORT/?t=$TOK" UT_LIVE_GPU=$wdgpu UT_LIVE_CPU=$wdcpu UT_LIVE_LOG=$LOG \
       $LIVE "$MOD/tests/webui-live.js" > "$T/live.out" 2>&1; then
      ok "live webui drives the server end to end"
    else
      bad "live webui drives the server end to end" "$(grep -E '^(FAIL|passed)' "$T/live.out" | head -10)"
    fi
  else
    echo "skip live webui (no node)"
  fi
  $SEP sh "$MOD/bin/serve.sh" stop >/dev/null 2>&1
else
  echo "skip standalone server (needs nc and curl)"
fi

echo
echo "passed $PASS, failed $FAILS"
if [ "$FAILS" = 0 ]; then
  rm -rf "$T"
else
  echo "artifacts kept in $T"
fi
[ "$FAILS" = 0 ] || exit 1
exit 0






