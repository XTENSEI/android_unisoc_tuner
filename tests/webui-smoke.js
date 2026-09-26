// Unisoc Tuner webui smoke test - runs webroot/app.js in a tiny DOM + HTTP shim
// and checks it drives the CLI contract (bin/*.sh) the way serve.sh exposes it.
// usage: node tests/webui-smoke.js
"use strict";

const fs = require("fs");
const path = require("path");
const vm = require("vm");

const MOD = path.join(__dirname, "..");

let pass = 0;
let fails = 0;
const ok = (n) => { pass++; console.log("ok   " + n); };
const bad = (n, d) => { fails++; console.log("FAIL " + n + (d ? ": " + d : "")); };
const has = (n, hay, needle) => {
  if (String(hay).indexOf(needle) >= 0) ok(n); else bad(n, "missing " + needle);
};
const eq = (n, got, want) => {
  if (String(got) === String(want)) ok(n); else bad(n, "got " + JSON.stringify(got));
};

// ---- canned CLI output (shape captured from bin/*.sh status) ---------------

const TUNER_STATUS = [
  "mode=auto",
  "freqhz=850000000",
  "pollms=100",
  "boost=0",
  "capunit=1000",
  "governor=simple_ondemand",
  "curhz=850000000",
  "minhz=384000000",
  "maxhz=850000000",
  "thermald=850000",
  "bcl=850000",
  "trans=1042",
  "util=42 0 0",
  "freqlist=384000000 512000000 614400000 768000000 850000000",
].join("\n") + "\n";

const SYS_STATUS = [
  "mode=custom",
  "c0=/sys/devices/system/cpu/cpufreq/policy0|0 1 2 3 4 5|schedutil|1800000|384000|2000000|384000,614400,1200000,1800000,2000000|schedutil,performance,powersave|||",
  "c1=/sys/devices/system/cpu/cpufreq/policy1|6 7|performance|2000000|614400|2000000|614400,1200000,1800000,2000000|schedutil,performance|||",
  "nclus=2",
].join("\n") + "\n";

const DVFS_STATUS = [
  "mode=stock",
  "dv0=scene-frequency|sprd-governor|1536000000|sprd-governor,performance,powersave|768000000,1536000000|768000000|1536000000|11|||scene_frequency",
  "dv1=dpu-dvfs|sprd-governor|400000000|sprd-governor,powersave||0|0|10|||dpu_dvfs",
  "ndv=2",
].join("\n") + "\n";

const WHERE = "dir=/data/adb/modules/unisoc-tuner\nver=v0.4.0\ncpu=1\ndv=1\ndoc=1\n";
const LOG = "09-27 10:00:01 service boot, module v0.4.0\n09-27 10:00:02 tuner apply done mode=auto\n";
const REPORT = "-- notes --\n  nothing unusual\n";

// ---- recorder --------------------------------------------------------------

const calls = [];
const urls = [];

function route(u) {
  const q = {};
  const qs = u.indexOf("?") >= 0 ? u.slice(u.indexOf("?") + 1) : "";
  qs.split("&").forEach((p) => {
    const i = p.indexOf("=");
    if (i > 0) q[p.slice(0, i)] = decodeURIComponent(p.slice(i + 1).replace(/\+/g, " "));
  });
  urls.push(u);
  if (u.indexOf("/where") === 0) return WHERE;
  if (q.run === "doctor") {
    return /^log\b/.test(q.args || "") ? LOG : REPORT;
  }
  if (q.args === "status") {
    if (q.run === "tuner") return TUNER_STATUS;
    if (q.run === "system") return SYS_STATUS;
    if (q.run === "dvfs") return DVFS_STATUS;
  }
  calls.push(q.run + " " + (q.args || ""));
  if (q.run === "tuner" && /^set\b/.test(q.args || "")) {
    return q.args.replace(/^set /, "").replace(/ /g, "=") + "\n" + TUNER_STATUS;
  }
  if (q.run === "system" && /^set\b/.test(q.args || "")) return SYS_STATUS;
  if (q.run === "dvfs" && /^set\b/.test(q.args || "")) return DVFS_STATUS;
  return "";
}

// ---- minimal DOM -----------------------------------------------------------

function El(tag) {
  const o = {
    tag,
    id: "",
    className: "",
    title: "",
    value: "",
    textContent: "",
    children: [],
    childNodes: [],
    style: {},
    listeners: {},
    appendChild(c) { o.children.push(c); o.childNodes.push(c); return c; },
    addEventListener(e, f) { (o.listeners[e] = o.listeners[e] || []).push(f); },
    fire(e) { (o.listeners[e] || []).forEach((f) => f()); },
  };
  Object.defineProperty(o, "innerHTML", {
    get() { return o._html || ""; },
    set(v) { o._html = v; if (v === "") { o.children = []; o.childNodes = []; } },
  });
  return o;
}

const ids = {};
const document = {
  getElementById(id) { if (!ids[id]) { ids[id] = El("div"); ids[id].id = id; } return ids[id]; },
  createElement(tag) { return El(tag); },
};

function XHR() {
  this.status = 200;
  this.responseText = "";
  this.open = (m, u) => { this.url = u; };
  this.send = () => {
    this.responseText = route(this.url);
    setTimeout(() => { if (this.onload) this.onload(); }, 0);
  };
}

// ---- run app.js ------------------------------------------------------------

const sandbox = {
  document,
  XMLHttpRequest: XHR,
  location: { protocol: "http:", hostname: "127.0.0.1", search: "?t=tok" },
  console,
};
sandbox.window = sandbox;
vm.createContext(sandbox);
vm.runInContext(fs.readFileSync(path.join(MOD, "webroot", "app.js"), "utf8"), sandbox, {
  filename: "webroot/app.js",
});

const pump = (ms) => new Promise((r) => setTimeout(r, ms || 40));

(async () => {
  await pump(300);

  has("page asks where the module lives", urls.join("\n"), "/where?t=tok");
  has("page reads the gpu status", urls.join("\n"), "run=tuner&args=status");
  has("page reads the cpu status", urls.join("\n"), "run=system&args=status");
  has("page reads the devfreq status", urls.join("\n"), "run=dvfs&args=status");
  has("page tails the log", urls.join("\n"), "run=doctor&args=log%2020");
  if (urls.every((u) => u.indexOf("/api") !== 0 || u.indexOf("t=tok") > 0)) {
    ok("every api call carries the token");
  } else {
    bad("every api call carries the token");
  }

  has("version line names the install", ids.ver.textContent, "v0.4.0 / server");
  eq("gpu mode select follows status", ids.mode.children.filter((o) => o.selected).map((o) => o.value).join(","), "auto");
  eq("gpu mode select lists every mode", ids.mode.children.length, 5);
  eq("freq input follows status", ids.freq.value, "850000000");
  eq("poll input follows status", ids.poll.value, "100");
  has("live panel shows the governor", ids.live.textContent, "governor simple_ondemand");
  has("live panel shows the cap", ids.live.textContent, "cap thermald 850 MHz");
  has("live panel shows utilisation", ids.live.textContent, "util 42 0 0");
  eq("one row per cpu cluster", ids.cpuclusters.children.length, 2);
  has("cluster row shows the cpus", ids.cpuclusters.children[0].children[0].textContent, "cpu 0 1 2 3 4 5");
  has("cluster row shows the governors", ids.cpuclusters.children[0].children[1].children.map((o) => o.value).join(","), "schedutil,performance,powersave");
  eq("one row per devfreq device", ids.devfreq.children.length, 2);
  has("devfreq row shows the device", ids.devfreq.children[0].children[0].textContent, "scene-frequency");
  has("devfreq row shows the limit", ids.devfreq.children[0].children[0].textContent, "max 1536 MHz");
  has("log tail is shown", ids.out.textContent, "tuner apply done mode=auto");

  ids.mode.value = "cap";
  ids.apply.fire("click");
  await pump(250);
  has("apply sends the changed gpu mode", calls.join("\n"), "tuner set MODE cap");
  has("apply reports back", ids.msg.textContent, "gpu applied");

  ids.cmode.value = "perf";
  ids.cmode.fire("change");
  await pump(250);
  has("cpu mode change is applied", calls.join("\n"), "system set MODE perf");

  ids.dmode.value = "powersave";
  ids.dmode.fire("change");
  await pump(250);
  has("memory mode change is applied", calls.join("\n"), "dvfs set MODE powersave");

  ids.cpreset.fire("click");
  await pump(250);
  has("cpu reset runs the script", calls.join("\n"), "system reset");
  calls.length = 0;

  ids.dvreset.fire("click");
  await pump(250);

  ids.bootdiff.fire("click");
  await pump(150);
  has("compare boots runs the diff", urls.join("\n"), "run=doctor&args=diff");

  ids.loglines.value = "5";
  ids.loglines.fire("change");
  await pump(150);
  has("log size is honoured", urls.join("\n"), "run=doctor&args=log%205");

  const bad_ = calls.filter((c) => !/^(tuner|system|dvfs|doctor) /.test(c));
  if (!bad_.length) ok("no stray script calls"); else bad("no stray script calls", bad_.join(" "));

  console.log("\npassed " + pass + ", failed " + fails);
  process.exitCode = fails ? 1 : 0;
})();
