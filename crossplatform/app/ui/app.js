// Panel UI for the Windows/Linux app. All data comes from the Rust side
// (crossplatform/app/src-tauri) through the "snapshot" event and these commands:
//   get_snapshot() -> Snapshot      set_model({ model: string|null }) -> ()  (error: string)
//   open_session({ id })            set_pref({ key, value: bool })            hide_panel()
"use strict";
const { invoke } = window.__TAURI__.core;
const { listen } = window.__TAURI__.event;

const MODELS = [[null, "Auto"], ["haiku", "Haiku"], ["sonnet", "Sonnet"], ["opus", "Opus"]];
const LABELS = { idle: "Ready", running: "Working", waiting: "Waiting", done: "Done" };
const COLORS = { idle: "var(--idle)", running: "var(--running)", waiting: "var(--waiting)", done: "var(--done)" };
const $ = id => document.getElementById(id);

let snap = null;
let rev = -1;           // newest snapshot revision shown
let lastState = null;   // null until the first snapshot: the first load is silent

function el(tag, cls, text) {
  const e = document.createElement(tag);
  if (cls) e.className = cls;
  if (text != null) e.textContent = text;   // textContent only: session data is untrusted
  return e;
}

function subtitle(s) {
  if (s.state === "waiting") return s.kind === "question" ? "has a question" : (s.request ? `wants ${s.request}` : "needs approval");
  return [s.branch, s.title].filter(Boolean).join(" · ") || s.cwd || "";
}

function renderSessions(list) {
  const ul = $("sessions");
  ul.replaceChildren();
  for (const s of list) {
    const li = el("li", "session");
    const dot = el("span", "dot");
    dot.style.background = s.state === "waiting" && s.kind === "question" ? "var(--question)" : COLORS[s.state];
    const text = el("div");
    text.append(el("div", "name", s.name), el("div", "sub", subtitle(s)));
    text.title = s.cwd || "";
    let right;
    if (s.state === "waiting") {
      right = el("button", "action" + (s.kind === "question" ? " question" : ""), snap.can_open ? "Open" : "Copy path");
      right.addEventListener("click", () => openSession(s, right));
    } else {
      right = el("span", "tag", LABELS[s.state]);
      right.style.color = COLORS[s.state];
    }
    li.append(dot, text, right);
    ul.append(li);
  }
  $("sessionCount").textContent = list.length;
  $("emptySessions").hidden = list.length > 0;
}

// Brings the session's terminal forward; if that isn't possible (no matching
// window, or Wayland), copies the project path so it's easy to find.
async function openSession(s, button) {
  let focused = false;
  if (snap.can_open) {
    try { focused = await invoke("open_session", { id: s.id }); } catch (e) { console.warn(e); }
  }
  if (!focused && s.cwd && navigator.clipboard) {
    try {
      await navigator.clipboard.writeText(s.cwd);
      button.textContent = "Path copied";
    } catch (_) {
      button.textContent = "Not found";
    }
  }
}

function renderModels(current) {
  const box = $("models");
  box.replaceChildren();
  for (const [id, label] of MODELS) {
    const b = el("button", "pill", label);
    b.setAttribute("aria-pressed", String((current ?? null) === id));
    b.addEventListener("click", async () => {
      $("modelError").hidden = true;
      try { await invoke("set_model", { model: id }); }
      catch (e) { $("modelError").textContent = String(e); $("modelError").hidden = false; }
    });
    box.append(b);
  }
}

function render(s) {
  if (s.rev <= rev) return;   // an older snapshot arrived late
  rev = s.rev;
  snap = s;
  document.querySelector(".panel").dataset.state = s.state;
  $("stateLabel").textContent = LABELS[s.state] || s.state;
  renderSessions(s.sessions);
  renderModels(s.model);
  $("today").textContent = `${s.today} msgs`;
  $("week").textContent = `${s.week} msgs`;
  $("muteBtn").textContent = s.prefs.muted ? "Sound off" : "Sound on";
  $("muteBtn").classList.toggle("off", s.prefs.muted);
  $("rainBtn").classList.toggle("off", s.prefs.rain_muted || s.prefs.muted);
  for (const [name, open] of Object.entries(s.prefs.sections || {})) {
    const head = document.querySelector(`[data-section="${name}"]`);
    if (head) head.setAttribute("aria-expanded", String(open));
  }
  if (lastState !== null && s.state !== lastState) Sounds.forState(s.state);
  lastState = s.state;
}

document.querySelectorAll(".section-head").forEach(h => h.addEventListener("click", () => {
  const open = h.getAttribute("aria-expanded") !== "true";
  h.setAttribute("aria-expanded", String(open));
  invoke("set_pref", { key: `section_${h.dataset.section}`, value: open }).catch(() => {});
}));
$("muteBtn").addEventListener("click", () => {
  const v = !snap.prefs.muted;
  Sounds.setMuted(v, snap.state);
  snap.prefs.muted = v;
  invoke("set_pref", { key: "muted", value: v }).catch(() => {});
});
$("rainBtn").addEventListener("click", () => {
  const v = !snap.prefs.rain_muted;
  Sounds.setRainMuted(v, snap.state);
  snap.prefs.rain_muted = v;
  invoke("set_pref", { key: "rain_muted", value: v }).catch(() => {});
});
$("hideBtn").addEventListener("click", () => invoke("hide_panel").catch(() => {}));

// Subscribe first, then fetch, so no update can slip in between.
(async () => {
  await listen("snapshot", e => render(e.payload));
  const s = await invoke("get_snapshot");
  Sounds.init(s.prefs.muted, s.prefs.rain_muted);
  render(s);
})().catch(e => console.error(e));
