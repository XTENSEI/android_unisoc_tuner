# Unisoc Tuner

KernelSU / Magisk module that tunes the performance nodes of the Nubia V80 Max
(Z2577) and boards close to it: Unisoc UMS9230 (T7250), Mali-G57 MP1.

## What it touches

| Area | Nodes | Modes |
|---|---|---|
| GPU | `23100000.gpu` devfreq governor, polling, frequency cap, `gpu_boost_level2` | stock / auto / perf / manual / cap |
| CPU | both cpufreq policies (6x A55 + 2x A75) | stock / perf / balanced / per-cluster |
| Memory + media | non-GPU devfreq devices (DDR `scene-frequency`, `dpu-dvfs`, ...) | stock / auto / perf / powersave / custom |

A cap watchdog re-applies the ceilings that Android's thermal and BCL daemons
overwrite after boot, and every write lands in `/data/adb/unisoc-tuner.log`, so
a changed knob is always traceable.

## Install

Flash the zip in KernelSU or Magisk and reboot. `service.sh` re-applies the
saved config on every boot.

## Use

- **WebUI** (manager button): live GPU state, CPU clusters, devfreq devices,
  doctor report, boot-over-boot drift.
- **Action button**: cycles the GPU mode stock -> auto -> perf -> manual -> cap.
- **No manager bridge?** Run
  `sh /data/adb/modules/unisoc-tuner/bin/serve.sh start` as root and open the
  URL it prints; the page runs the same scripts over the local API.
- **CLI**:

  ```sh
  bin/tuner.sh  status | apply | set KEY VALUE | dwell SECS | reset
  bin/system.sh status | apply | set KEY VALUE | reset
  bin/dvfs.sh   status | apply | set KEY VALUE | reset
  bin/doctor.sh report | log [n] | logold [n] | diff | drift | watchdog
  ```

## Keys

`tuner.sh set` takes `MODE` (stock/auto/perf/manual/cap), `FREQHZ` (one of the
GPU frequencies), `POLLMS` (20-400), `BOOST` (0-3) and `CAPUNIT` (1 or 1000).

`system.sh set` takes `MODE` (stock/perf/balanced/custom) plus per-cluster
`GOV0`-`GOV3` and `MAX0`-`MAX3`.

`dvfs.sh set` takes `MODE` (stock/auto/perf/powersave/custom) plus per-device
`GOV:<device>` and `MAX:<device>`, with the device key printed by `status`.

## Safety

Every knob is a sysfs write whose previous value is recorded first, so `reset`
restores the vendor defaults and uninstalling the module does the same. Nothing
is written until a mode other than `stock` is selected.

## Tests

```sh
sh tests/selfcheck.sh
```

Rebuilds fake sysfs trees under `$TMPDIR` and exercises every script path, the
watchdog drift re-apply, the standalone server and the web page
(`tests/webui-smoke.js` runs as part of it). CI runs the same gate on every push.
