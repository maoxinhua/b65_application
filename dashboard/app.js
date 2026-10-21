const $ = (id) => document.getElementById(id);

function setText(id, value) {
  const el = $(id);
  if (el) el.textContent = value;
}

function setBar(barId, textId, pct, label, warnAt = 80, badAt = 92) {
  const bar = $(barId);
  const text = $(textId);
  const v = Math.max(0, Math.min(100, Number(pct) || 0));
  if (bar) {
    bar.style.width = v.toFixed(1) + "%";
    bar.classList.remove("warn", "bad");
    if (v >= badAt) bar.classList.add("bad");
    else if (v >= warnAt) bar.classList.add("warn");
  }
  if (text) text.textContent = label;
}

function fmtMem(mb) {
  if (!mb) return "0 MB";
  if (mb >= 1024) return (mb / 1024).toFixed(1) + " GB";
  return Math.round(mb) + " MB";
}

async function refresh() {
  try {
    const res = await fetch("/api/status", { cache: "no-store" });
    const s = await res.json();
    const mode = (s.mode || "idle").toLowerCase();
    const modeEl = $("mode");
    modeEl.textContent = mode;
    modeEl.className = "mode " + mode;

    setText("gpu-name", s.gpu && s.gpu.Name ? s.gpu.Name : "GPU");
    const mem = s.memory || {};
    setBar("ram-bar", "ram-text", mem.UsedPct || 0,
      `${(mem.FreeGB ?? 0).toFixed(1)} GB free / ${(mem.TotalGB ?? 0).toFixed(1)} GB`);
    setBar("pf-bar", "pf-text", mem.PageFilePct || 0,
      `${(mem.PageFilePct ?? 0).toFixed(0)}%`);
    const vramPct = ((s.gpu && s.gpu.DedicatedMB ? s.gpu.DedicatedMB : 0) / 32768) * 100;
    setBar("vram-bar", "vram-text", vramPct,
      `${fmtMem(s.gpu && s.gpu.DedicatedMB)} / 32 GB`, 85, 95);
    setBar("gpu-bar", "gpu-text", (s.gpu && s.gpu.UtilPct) || 0,
      `${(s.gpu && s.gpu.UtilPct) || 0}%`);

    const llm = s.llm || {};
    setText("llm-state", llm.running ? "running" : "stopped");
    $("llm-state").className = "pill " + (llm.running ? "on" : "");
    setText("llm-model", llm.model || "—");
    setText("llm-ctx", llm.context ? (llm.context / 1024).toFixed(0) + "K" : "—");
    setText("llm-pid", llm.pid || "—");
    setText("llm-mem", llm.running ? `${fmtMem(llm.stats && llm.stats.WorkingSetMB)} / ${fmtMem(llm.vramMB)}` : "—");
    const host = s.lanIp || "127.0.0.1";
    setText("llm-url", llm.running ? `http://${host}:${llm.port}/v1` : "—");
    $("api-key").value = llm.apiKey || "";

    const vid = s.video || {};
    setText("video-state", vid.running ? "running" : "stopped");
    $("video-state").className = "pill " + (vid.running ? "on" : "");
    setText("video-port", vid.port || "—");
    setText("video-pid", vid.pid || "—");
    setText("video-mem", vid.running ? `${fmtMem(vid.stats && vid.stats.WorkingSetMB)} / ${fmtMem(vid.vramMB)}` : "—");

    if (s.watchdog) {
      setText("watchdog", `${s.watchdog.target} · ${s.watchdog.action}`);
    } else {
      setText("watchdog", "—");
    }
    setText("updated", new Date().toLocaleTimeString());
  } catch (err) {
    setText("updated", "connection lost");
  }
}

async function act(name) {
  const buttons = document.querySelectorAll("button");
  buttons.forEach((b) => (b.disabled = true));
  try {
    await fetch("/api/action", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ action: name }),
    });
    setTimeout(refresh, 800);
  } finally {
    setTimeout(() => buttons.forEach((b) => (b.disabled = false)), 1500);
  }
}

async function loadLogs() {
  const name = $("log-name").value;
  try {
    const res = await fetch(`/api/logs?name=${encodeURIComponent(name)}&lines=160`, { cache: "no-store" });
    const lines = await res.json();
    $("logs").textContent = Array.isArray(lines) ? lines.join("\n") : String(lines);
    $("logs").scrollTop = $("logs").scrollHeight;
  } catch {
    $("logs").textContent = "log unavailable";
  }
}

function copyKey() {
  const input = $("api-key");
  if (!input.value) return;
  navigator.clipboard.writeText(input.value).catch(() => {
    input.select();
    document.execCommand("copy");
  });
}

refresh();
loadLogs();
setInterval(refresh, 2500);
setInterval(loadLogs, 6000);

async function queueRender() {
  const profile = $("render-profile").value;
  const image = $("render-image").value.trim();
  const prompt = $("render-prompt").value.trim();
  if (!image || !prompt) {
    $("render-msg").textContent = "image and prompt are required";
    return;
  }
  $("render-pill").textContent = "queuing";
  try {
    const res = await fetch("/api/render", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ profile, image, prompt }),
    });
    const data = await res.json();
    if (data.ok) {
      $("render-pill").textContent = "queued";
      $("render-msg").textContent = "queued — progress is in the logs and output/shots";
    } else {
      $("render-pill").textContent = "error";
      $("render-msg").textContent = data.error || "render failed to queue";
    }
  } catch (err) {
    $("render-pill").textContent = "error";
    $("render-msg").textContent = String(err);
  }
}

async function loadOutputs() {
  try {
    const res = await fetch("/api/outputs", { cache: "no-store" });
    const list = await res.json();
    const box = $("outputs");
    box.innerHTML = "";
    (list || []).forEach((f) => {
      const a = document.createElement("a");
      a.href = f.url;
      a.target = "_blank";
      a.textContent = `${f.name}  ·  ${f.sizeMB} MB  ·  ${f.time}`;
      box.appendChild(a);
    });
  } catch {
    // keep the last list
  }
}

loadOutputs();
setInterval(loadOutputs, 8000);
