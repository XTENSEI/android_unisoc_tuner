// Unisoc Tuner live webui test - runs webroot/app.js against a real bin/serve.sh
// and checks the fake device tree it serves actually changes.
// usage: UT_LIVE_URL='http://127.0.0.1:PORT/?t=TOKEN' UT_LIVE_GPU=/path/to/gpu/dir \
//        node tests/webui-live.js
"use strict";

const fs = require("fs");
const http = require("http");
const path = require("path");
const vm = require("vm");

const MOD = path.join(__dirname, "..");
const URL_ = process.env.UT_LIVE_URL || "";
const GPU = process.env.UT_LIVE_GPU || "";
const CPU = process.env.UT_LIVE_CPU || "";
const LOG = process.env.UT_LIVE_LOG || "";
const TOKEN = (URL_.match(/[?&]t=([^&#]+)/) || ["", ""])[1];
const HOST = (URL_.match(/^https?:\/\/([^/:]+)/) || ["", "127.0.0.1"])[1];
const PORT = Number((URL_.match(/:(\d+)/) || ["", "0"])[1]);

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

if (!TOKEN || !PORT || !GPU || !CPU || !LOG) {
  console.log("skip live webui (set UT_LIVE_URL, UT_LIVE_GPU, UT_LIVE_CPU, UT_LIVE_LOG)");
  process.exit(0);
}

const rd = (p) => {
  try { return fs.readFileSync(path.join(GPU, p), "utf8").trim(); } catch (e) { return ""; }
};

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

// every request really goes to serve.sh over the loopback socket
function XHR() {
  this.status = 200;
  this.responseText = "";
  this.open = (m, u) => { this.url = u; };
  this.send = () => {
    if (process.env.UT_LIVE_DEBUG) console.log("REQ " + this.url);
    const req = http.get({ host: HOST, port: PORT, path: this.url }, (res) => {
      let body = "";
      res.on("data", (c) => { body += c; });
      res.on("end", () => {
        this.status = res.statusCode;
        this.responseText = body;
        if (process.env.UT_LIVE_DEBUG) console.log("RES " + res.statusCode + " " + JSON.stringify(body.slice(0, 40)));
        if (this.onload) this.onload();
      });
    });
    req.on("error", (e) => {
      if (process.env.UT_LIVE_DEBUG) console.log("ERR " + e.message);
      this.responseText = "";
      if (this.onerror) this.onerror();
      else if (this.onload) this.onload();
    });
  };
}

const sandbox = {
  document,
  XMLHttpRequest: XHR,
  location: { protocol: "http:", hostname: HOST, search: "?t=" + TOKEN },
  setTimeout,
  console,
};
sandbox.window = sandbox;
vm.createContext(sandbox);
vm.runInContext(fs.readFileSync(path.join(MOD, "webroot", "app.js"), "utf8"), sandbox, {
  filename: "webroot/app.js",
});

const wait = (ms) => new Promise((r) => setTimeout(r, ms || 60));
async function until(fn, ms) {
  const t0 = Date.now();
  while (Date.now() - t0 < (ms || 5000)) {
    if (fn()) return true;
    await wait(60);
  }
  return false;
}

(async () => {
  // wait for data only the server can produce: the selects are filled from the
  // markup before any request is made, so they are not a readiness signal
  const rendered = await until(
    () => /server/.test(ids.ver.textContent) && ids.cpuclusters.children.length > 0
      && ids.devfreq.children.length > 0 && ids.out.textContent.length > 0, 10000);
  if (rendered) {
    ok("page rendered from the live server");
  } else {
    bad("page rendered from the live server",
      "ver=" + ids.ver.textContent + " clusters=" + ids.cpuclusters.children.length +
      " devfreq=" + ids.devfreq.children.length + " out=" + ids.out.textContent.length);
  }

  has("version comes from the running module", ids.ver.textContent, "server");
  eq("gpu mode read from the device", ids.mode.children.filter((o) => o.selected).map((o) => o.value).join(","), "stock");
  has("live panel shows the device governor", ids.live.textContent, "governor simple_ondemand");
  has("live panel shows the device cap", ids.live.textContent, "cap thermald 200 MHz");
  eq("one row per real cpu cluster", ids.cpuclusters.children.length, 2);
  has("cluster row shows the device cpus", ids.cpuclusters.children[0].children[0].textContent, "cpu 0 1 2 3 4 5");
  const dvRows = ids.devfreq.children.length;
  if (dvRows >= 2) ok("a row per real devfreq device (" + dvRows + ")"); else bad("a row per real devfreq device", "got " + dvRows);
  const dvHeads = ids.devfreq.children.map((r) => r.children[0].textContent).join(" | ");
  has("devfreq rows name the real devices", dvHeads, "scene-frequency");
  has("devfreq rows name the second device", dvHeads, "dpu-dvfs");
  has("log tail came back", ids.out.textContent, "serve standalone server on port");

  // gpu apply has to reach the fake sysfs
  ids.mode.value = "perf";
  ids.apply.fire("click");
  const applied = await until(() => rd("governor") === "performance");
  if (applied) ok("gpu apply wrote the device governor"); else bad("gpu apply wrote the device governor", "governor=" + rd("governor"));
  eq("gpu apply wrote the device cap in khz", rd("thermald_max_freq"), "850000");
  await until(() => String(ids.msg.textContent).indexOf("gpu applied") > 0, 8000);
  has("gpu apply reports back in the page", ids.msg.textContent, "gpu applied");

  // cluster apply has to reach the fake sysfs too
  const row0 = ids.cpuclusters.children[0];
  const govSel = row0.children[1];
  const maxIn = row0.children[2];
  const setBtn = row0.children[3];
  govSel.value = "performance";
  maxIn.value = "1200000";
  setBtn.fire("click");
  const cluster = await until(
    () => String(ids.msg.textContent).indexOf("policy0 applied") > 0, 10000);
  if (cluster) ok("cluster apply reports back in the page"); else bad("cluster apply reports back in the page", ids.msg.textContent);
  has("cluster apply wrote through the api", fs.readFileSync(path.join(CPU, "cpufreq", "policy0", "scaling_governor"), "utf8"), "performance");

  // a bad value must come back as an error, not a silent write
  ids.boost.value = "9";
  ids.apply.fire("click");
  await until(() => String(ids.msg.textContent).indexOf("rejected") > 0, 10000);
  has("bad input is rejected in the page", ids.msg.textContent, "rejected");
  has("bad input is rejected by the script", fs.readFileSync(LOG, "utf8"), "tuner reject set BOOST=9");

  console.log("\npassed " + pass + ", failed " + fails);
  process.exitCode = fails ? 1 : 0;
})();
