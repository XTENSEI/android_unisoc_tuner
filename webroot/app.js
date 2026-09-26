(() => {
  "use strict";

  // probe contract: the self-check verifies these five exist
  const moddir = "/data/adb/modules/unisoc-tuner";
  const modver = "v0.4.0";
  // the module always ships all three; detect() hides what this device lacks
  const modcpu = true;
  const moddv = true;
  const moddoc = true;

  // DOM element ids used by the page
  const IDS = [
    "apply",
    "boost",
    "bootdiff",
    "cmode",
    "cpreset",
    "cpu",
    "cpuclusters",
    "devfreq",
    "dmode",
    "doctor",
    "dv",
    "dvreset",
    "foot",
    "freq",
    "gpu",
    "head",
    "live",
    "loglines",
    "mode",
    "msg",
    "out",
    "poll",
    "refresh",
    "system",
    "ver",
    "wrap",
  ];

  const el = (id) => document.getElementById(id);
  const missing = IDS.filter((i) => !el(i));
  if (missing.length && window.console) {
    console.log("unisoc-tuner: index.html is missing " + missing.join(","));
  }

  const bridge = window.ksu || window.apatch || null;
  const isHttp = location.protocol === "http:" || location.protocol === "https:";
  const isLocal = location.hostname === "127.0.0.1" || location.hostname === "localhost";
  const TOKEN = (location.search.match(/[?&]t=([^&#]+)/) || ["", ""])[1];

  // standalone mode: bin/serve.sh serves this page and runs the scripts as root,
  // so any browser works without a manager bridge
  const SERVER = !bridge && isHttp && isLocal;
  const LIVE = !!bridge || SERVER;

  // installed layouts seen in the wild; the shell side picks the first hit
  const CANDS = [
    "/data/adb/modules/unisoc-tuner",
    "/data/adb/modules/unisoc-gpu-tuner",
    "/data/adb/modules_update/unisoc-tuner",
    "/data/adb/modules_update/unisoc-gpu-tuner",
  ];

  const MODES = [
    ["stock", "Stock", "no changes"],
    ["auto", "Auto", "ondemand + poll"],
    ["perf", "Perf", "pin max"],
    ["manual", "Manual", "pin one freq"],
    ["cap", "Cap", "ceiling"],
  ];
  const CMODES = [
    ["stock", "Stock", "no changes"],
    ["perf", "Perf", "all clusters performance"],
    ["balanced", "Balanced", "schedutil / ondemand"],
    ["custom", "Custom", "per-cluster control"],
  ];
  const DVMODES = [
    ["stock", "Stock", "no changes"],
    ["auto", "Auto", "recorded defaults"],
    ["perf", "Perf", "performance where offered"],
    ["powersave", "Save", "powersave where offered"],
    ["custom", "Custom", "per device"],
  ];
  const FREQS = [384000000, 512000000, 614400000, 768000000, 850000000];
  const SCRIPTS = ["tuner", "system", "dvfs", "doctor"];

  // resolved module location; detect() overwrites this with what is installed
  const W = { dir: moddir, ver: modver, cpu: modcpu, dv: moddv, doc: moddoc };
  let st = {};
  let ss = {};
  let ds = {};
  let clusters = [];
  let devs = [];
  let gerr = "";
  let serr = "";
  let dverr = "";
  let busy = false;

  // ---- shell plumbing ------------------------------------------------------

  const safe = (s) => String(s == null ? "" : s).replace(/[^0-9A-Za-z_:., -]/g, "");

  function stamp() {
    const d = new Date();
    const p = (n) => (n < 10 ? "0" : "") + n;
    return p(d.getHours()) + ":" + p(d.getMinutes()) + ":" + p(d.getSeconds());
  }
  function say(msg) {
    el("msg").textContent = "[" + stamp() + "] " + msg;
  }
  function show(txt) {
    el("out").textContent = txt;
  }

  let cbn = 0;
  // KernelSU hands the result to a named global callback, not to a function value
  function shell(cmd) {
    return new Promise((resolve) => {
      if (!bridge || typeof bridge.exec !== "function") {
        resolve("err=no shell bridge");
        return;
      }
      const name = "utcb" + (cbn++);
      let done = false;
      const fin = (v) => { if (!done) { done = true; resolve(v); } };
      window[name] = (errno, stdout, stderr) => {
        delete window[name];
        let o = stdout || "";
        if (stderr) o += (o ? "\n" : "") + stderr;
        if (errno) o += (o ? "\n" : "") + "errno=" + errno;
        fin(o);
      };
      try {
        bridge.exec(cmd, "{}", name);
      } catch (e) {
        delete window[name];
        fin("err=shell call blocked");
      }
    });
  }

  function get(path) {
    return new Promise((resolve) => {
      const xhr = new XMLHttpRequest();
      xhr.open("GET", path, true);
      xhr.onload = () => resolve(xhr.responseText || "");
      xhr.onerror = () => resolve("");
      xhr.send();
    });
  }

  function api(script, args) {
    return get("/api?t=" + encodeURIComponent(TOKEN) + "&run=" + script +
      (args ? "&args=" + encodeURIComponent(args) : ""));
  }

  function cmdFor(script, args) {
    let probe = "";
    CANDS.forEach((c) => { probe += '[ -f "' + c + '/bin/tuner.sh" ] && D="' + c + '"; '; });
    return 'D=""; ' + probe + 'sh "$D/bin/' + script + '.sh" ' + (args || "");
  }

  // every script call goes through here, so the two transports stay in one place
  function run(script, args) {
    if (!LIVE) return Promise.resolve("err=read-only preview");
    if (SCRIPTS.indexOf(script) < 0) return Promise.resolve("err=unknown script");
    const a = safe(args);
    return SERVER ? api(script, a) : shell(cmdFor(script, a) + " 2>&1");
  }

  // ---- parsers -------------------------------------------------------------

  function kv(txt) {
    const o = {};
    String(txt || "").split("\n").forEach((ln) => {
      const i = ln.indexOf("=");
      if (i > 0) o[ln.slice(0, i)] = ln.slice(i + 1).trim();
    });
    return o;
  }
  // status emits numbered records (c0=, dv0=), not a bare tag
  function rows(txt, tag) {
    const re = new RegExp("^" + tag + "\\d+=(.*)$");
    const out = [];
    String(txt || "").split("\n").forEach((ln) => {
      const m = ln.match(re);
      if (m) out.push(m[1].split("|"));
    });
    return out;
  }
  function list(csv) {
    return String(csv || "").split(",").filter((s) => s !== "");
  }
  function errOf(txt) {
    return (String(txt || "").match(/^err=.*$/m) || [""])[0];
  }
  function mhz(v) {
    const n = Number(v);
    return n > 0 ? Math.round(n / 1000000) + " MHz" : "?";
  }
  // caps use the unit the node reports: hz when capunit is 1, khz otherwise
  function mhzCap(v, unit) {
    const n = Number(v);
    return n > 0 ? Math.round((Number(unit) === 1 ? n : n * 1000) / 1000000) + " MHz" : "?";
  }

  function opts(sel, values, cur) {
    sel.innerHTML = "";
    values.forEach((v) => {
      const pair = typeof v === "string" ? [v, v] : v;
      const o = document.createElement("option");
      o.value = pair[0];
      o.textContent = pair[1];
      if (pair[2]) o.title = pair[2];
      if (pair[0] === cur) o.selected = true;
      sel.appendChild(o);
    });
  }

  // ---- render --------------------------------------------------------------

  function gpuRead() {
    return run("tuner", "status").then((t) => {
      st = kv(t);
      gerr = st.err || "";
      opts(el("mode"), MODES, st.mode);
      el("freq").value = st.freqhz || "";
      el("poll").value = st.pollms || "";
      el("boost").value = st.boost || "";
      el("live").textContent =
        "governor " + (st.governor || "?") +
        "   cur " + mhz(st.curhz) +
        "   min " + mhz(st.minhz) +
        "   max " + mhz(st.maxhz) + "\n" +
        "cap thermald " + mhzCap(st.thermald, st.capunit) +
        "   bcl " + mhzCap(st.bcl, st.capunit) +
        "   unit " + (st.capunit || "?") +
        "   transitions " + (st.trans || "?") + "\n" +
        "freqs " + String(st.freqlist || FREQS.join(" ")).replace(/ /g, " / ") + "\n" +
        (st.util ? "util " + st.util : "util needs debugfs");
    });
  }

  function clusterRow(i, f) {
    const d = document.createElement("div");
    d.className = "row";
    const h = document.createElement("div");
    h.className = "head";
    h.textContent = "policy" + i + "   cpu " + (f[1] || "?") + "   " + (f[2] || "?") +
      "   cur " + mhz(f[3]) + "   min " + mhz(f[4]) + "   max " + mhz(f[5]);
    const g = document.createElement("select");
    opts(g, list(f[7]), f[2]);
    const m = document.createElement("input");
    m.value = f[5] || "";
    m.title = "max freq in hz, one of " + list(f[6]).join(" / ");
    const b = document.createElement("button");
    b.textContent = "set";
    b.addEventListener("click", () => { setCluster(i, g.value, m.value); });
    d.appendChild(h);
    d.appendChild(g);
    d.appendChild(m);
    d.appendChild(b);
    return d;
  }

  function cpuRead() {
    if (!W.cpu) return Promise.resolve();
    return run("system", "status").then((t) => {
      ss = kv(t);
      serr = ss.err || "";
      opts(el("cmode"), CMODES, ss.mode);
      clusters = rows(t, "c");
      const box = el("cpuclusters");
      box.innerHTML = "";
      clusters.forEach((f, i) => box.appendChild(clusterRow(i, f)));
      if (!box.childNodes.length) box.textContent = "no cpufreq policies found";
    });
  }

  function devRow(f) {
    const d = document.createElement("div");
    d.className = "row";
    const h = document.createElement("div");
    h.className = "head";
    h.textContent = f[0] + "   " + (f[1] || "?") +
      "   cur " + mhz(f[2]) +
      "   min " + mhz(f[5]) +
      "   max " + mhz(f[6]) +
      (f[7] === "00" ? "   (read only)" : "");
    const g = document.createElement("select");
    opts(g, list(f[3]), f[1]);
    const m = document.createElement("input");
    m.value = f[6] || "";
    m.title = "max freq in hz, one of " + list(f[4]).join(" / ");
    const b = document.createElement("button");
    b.textContent = "set";
    b.addEventListener("click", () => { setDev(f, g.value, m.value); });
    d.appendChild(h);
    d.appendChild(g);
    d.appendChild(m);
    d.appendChild(b);
    return d;
  }

  function dvRead() {
    if (!W.dv) return Promise.resolve();
    return run("dvfs", "status").then((t) => {
      ds = kv(t);
      dverr = ds.err || "";
      opts(el("dmode"), DVMODES, ds.mode);
      devs = rows(t, "dv");
      const box = el("devfreq");
      box.innerHTML = "";
      devs.forEach((f) => box.appendChild(devRow(f)));
      if (!box.childNodes.length) box.textContent = "no devfreq devices";
    });
  }

  function readLog() {
    const n = Math.max(1, Math.min(100, Number(el("loglines").value) || 20));
    return run("doctor", "log " + n).then(show);
  }

  // ---- actions -------------------------------------------------------------

  // `set` applies as it saves, so a batch is just the calls in order
  function applySet(script, jobs, reload, label) {
    if (busy) return;
    if (!jobs.length) { say(label + ": nothing changed"); return; }
    busy = true;
    say(label + ": " + jobs.join(", "));
    let err = "";
    let p = Promise.resolve("");
    jobs.forEach((a) => {
      p = p.then(() => run(script, "set " + a)).then((o) => {
        const e = errOf(o);
        if (e && !err) err = e;
      });
    });
    p.then(reload).then(() => {
      busy = false;
      say(err ? label + " rejected: " + err : label + " applied");
    });
  }

  function applyMode(script, mod) {
    const sys = script === "system";
    applySet(script, ["MODE " + mod], sys ? cpuRead : dvRead, sys ? "cpu mode" : "memory mode");
  }

  function resetTo(script, label, reload) {
    if (busy) return;
    busy = true;
    say(label + " ...");
    run(script, "reset").then((o) => {
      show(o);
      return Promise.resolve(reload()).then(() => {
        busy = false;
        say(label + " done, defaults restored");
      });
    });
  }

  function report(script, args, label) {
    if (busy) return;
    busy = true;
    say(label + " ...");
    run(script, args).then((o) => {
      busy = false;
      show(o);
      say(label + " (" + stamp() + ")");
    });
  }

  function gpuApply() {
    const v = (id) => String(el(id).value).trim();
    const jobs = [];
    if (v("mode") !== (st.mode || "")) jobs.push("MODE " + v("mode"));
    if (v("freq") && v("freq") !== (st.freqhz || "")) jobs.push("FREQHZ " + v("freq"));
    if (v("poll") && v("poll") !== (st.pollms || "")) jobs.push("POLLMS " + v("poll"));
    if (v("boost") !== "" && v("boost") !== (st.boost || "")) jobs.push("BOOST " + v("boost"));
    applySet("tuner", jobs, gpuRead, "gpu");
  }

  function setCluster(i, gov, max) {
    const f = clusters[i] || [];
    const jobs = [];
    if (gov && gov !== f[2]) jobs.push("GOV" + i + " " + gov);
    if (max && max !== f[5]) jobs.push("MAX" + i + " " + max);
    applySet("system", jobs, cpuRead, "policy" + i);
  }

  function setDev(f, gov, max) {
    const jobs = [];
    if (gov && gov !== f[1]) jobs.push("GOV:" + f[10] + " " + gov);
    if (max && max !== f[6]) jobs.push("MAX:" + f[10] + " " + max);
    applySet("dvfs", jobs, dvRead, f[0]);
  }

  function refresh() {
    if (busy) return Promise.resolve();
    busy = true;
    say("reading device state ...");
    return Promise.all([gpuRead(), cpuRead(), dvRead(), readLog()]).then(() => {
      busy = false;
      const errs = [gerr, serr, dverr].filter((x) => x);
      say(errs.length ? "warnings: " + errs.join(" | ") : "state read");
    });
  }

  // ---- wiring --------------------------------------------------------------

  function detect() {
    function adopt(t) {
      const w = kv(t);
      const on = (v) => v === "1" || v === "yes";
      W.dir = w.dir || moddir;
      W.ver = w.ver || modver;
      W.cpu = on(w.has_system) || on(w.cpu);
      W.dv = on(w.has_dvfs) || on(w.dv);
      W.doc = on(w.has_doctor) || on(w.doc);
      el("ver").textContent = W.ver + (SERVER ? " / server" : bridge ? "" : " / preview");
      el("cpu").style.display = W.cpu ? "" : "none";
      el("dv").style.display = W.dv ? "" : "none";
    }
    if (SERVER) return get("/where?t=" + encodeURIComponent(TOKEN)).then(adopt);
    let probe = 'D=""; for c in ' + CANDS.join(" ") + '; do [ -f "$c/module.prop" ] && D=$c; done; ';
    probe += 'echo dir=$D; echo ver=$(sed -n "s/^version=//p" "$D/module.prop" 2>/dev/null); ';
    probe += 'for f in system dvfs doctor; do [ -f "$D/bin/$f.sh" ] && echo has_$f=1; done';
    return shell(probe).then(adopt);
  }

  function boot() {
    opts(el("mode"), MODES, "");
    opts(el("cmode"), CMODES, "");
    opts(el("dmode"), DVMODES, "");
    el("ver").textContent = modver + " / preview";
    el("live").textContent =
      "module " + W.dir + "\n" +
      "scripts " + SCRIPTS.map((s) => s + ".sh").join(" ") + "\n" +
      "gpu freqs " + FREQS.map((f) => f / 1000000).join(" / ") + " MHz";
    if (!LIVE) {
      say("no shell access: open this page from the module manager or run bin/serve.sh");
      return;
    }
    say("connecting ...");
    detect().then(refresh);
  }

  el("apply").addEventListener("click", gpuApply);
  el("cpreset").addEventListener("click", () => { resetTo("system", "cpu reset", cpuRead); });
  el("dvreset").addEventListener("click", () => { resetTo("dvfs", "memory reset", dvRead); });
  el("refresh").addEventListener("click", () => { refresh(); });
  el("bootdiff").addEventListener("click", () => { report("doctor", "diff", "compare boots"); });
  el("doctor").addEventListener("click", () => { report("doctor", "", "doctor report"); });
  el("loglines").addEventListener("change", () => { readLog(); });
  el("cmode").addEventListener("change", () => {
    const m = el("cmode").value;
    if (m !== (ss.mode || "")) applyMode("system", m);
  });
  el("dmode").addEventListener("change", () => {
    const m = el("dmode").value;
    if (m !== (ds.mode || "")) applyMode("dvfs", m);
  });

  boot();
})();
