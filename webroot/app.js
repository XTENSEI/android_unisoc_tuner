(() => {
  // probe contract: the self-check verifies these five exist
  const moddir = "/data/adb/modules/unisoc-tuner";
  const modver = "v0.4.0";
  const modcpu = false;
  const moddv = false;
  const moddoc = false;

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

  const bridge = window.ksu || window.apatch || null;

  // standalone mode: bin/serve.sh serves this page and runs the scripts as root,
  // so any browser works without a manager bridge
  const SERVER = !bridge && typeof fetch === "function" &&
    (location.protocol === "http:" || location.protocol === "https:") &&
    (location.hostname === "127.0.0.1" || location.hostname === "localhost");
  const TOKEN = (location.search.match(/[?&]t=([^&]+)/) || [""]) [1];
  const LIVE = !!bridge || SERVER;

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

  let st = {};
  let ss = {};
  let ds = {};
  let gerr = "";
  let serr = "";
  let dverr = "";
  let busy = false;

  function run(cmd) {
    return new Promise((resolve) => {
      let done = false;
      const fin = (v) => { if (!done) { done = true; resolve(v); } };

      const send = (path) => {
        const xhr = new XMLHttpRequest();
        xhr.open("GET", path, true);
        xhr.responseType = "text";
        xhr.onload = () => { fin(xhr.responseText); };
        xhr.onerror = () => { fin(""); };
        xhr.send();
      };

      if (LIVE) {
        if (SERVER) send("/api?t=" + TOKEN + "&run=" + cmd);
        else {
          bridge.exec(cmd, (e, o) => { fin(e ? e + "\n" + (o || "") : o || ""); });
        }
        return;
      }

      const probe = async () => {
        for (const c of CANDS) {
          const p = c + "/bin/tuner.sh";
          try { await new Promise((res) => { const r = new XMLHttpRequest(); r.open("GET", p, true); r.onload = () => res(true); r.onerror = () => res(false); r.send(); }); }
          catch (e) { /* noop */ }
        }
        resolve();
      };
      probe();
    });
  }
})();
