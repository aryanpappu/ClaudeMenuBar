// Synthesized sounds, ported from Sources/App/SoundManager.swift:
// rain while running, knock-knock-knock every 2.5 s while waiting, a whistle when done.
// Buffers are generated once and cached; the AudioContext is suspended when silent.
"use strict";
const Sounds = (() => {
  let ctx = null, rainNode = null, knockTimer = null, idleTimer = null, gen = 0;
  const oneShots = new Set();   // whistle / knock buffers still playing
  const cache = {};
  let muted = false, rainMuted = false;

  function context() {
    if (!ctx) ctx = new (window.AudioContext || window.webkitAudioContext)();
    if (ctx.state === "suspended") ctx.resume().catch(() => {});
    clearTimeout(idleTimer);
    return ctx;
  }
  function buffer(name, seconds, fn) {
    if (cache[name]) return cache[name];
    const c = context(), n = Math.floor(c.sampleRate * seconds);
    const buf = c.createBuffer(1, n, c.sampleRate), d = buf.getChannelData(0);
    for (let i = 0; i < n; i++) d[i] = fn(i / c.sampleRate);
    return (cache[name] = buf);
  }
  function play(buf, loop = false) {
    const src = context().createBufferSource();
    src.buffer = buf; src.loop = loop; src.connect(ctx.destination); src.start();
    if (!loop) { oneShots.add(src); src.onended = () => oneShots.delete(src); }
    return src;
  }
  function suspendSoon(ms = 300) {
    clearTimeout(idleTimer);
    const g = gen;
    idleTimer = setTimeout(() => {
      if (g === gen && ctx && !rainNode && !knockTimer && oneShots.size === 0) ctx.suspend().catch(() => {});
    }, ms);
  }

  const rain = () => {
    let z = 0;
    return buffer("rain", 2.0, () => { z = 0.18 * (Math.random() * 2 - 1) + 0.82 * z; return z * 0.10; });
  };
  const whistle = () => buffer("whistle", 0.75, t => {
    const p = t / 0.75;
    // integrate the frequency glide so the tone stays smooth
    return Math.sin(Math.PI * p) * 0.38 * Math.sin(2 * Math.PI * (600 * t + 500 * 0.75 / Math.PI * (1 - Math.cos(Math.PI * p))));
  });
  const knock = () => buffer("knock", 0.8, t => {
    const one = o => {
      const dt = t - o;
      if (dt < 0 || dt >= 0.22) return 0;
      const knuckle = (Math.random() * 2 - 1) * Math.exp(-dt / 0.003) * 0.9;
      const body = Math.sin(2 * Math.PI * 65 * dt) * Math.exp(-dt / 0.065) * 0.7;
      const partial = Math.sin(2 * Math.PI * 130 * dt) * Math.exp(-dt / 0.018) * 0.18;
      return (knuckle + body + partial) * 0.68;
    };
    return one(0) + one(0.21) + one(0.42);
  });

  function stopLoops() {
    gen++;
    if (rainNode) { try { rainNode.stop(); } catch (_) {} rainNode = null; }
    clearInterval(knockTimer); knockTimer = null;
  }
  function stopEverything() {
    stopLoops();
    for (const src of oneShots) { try { src.stop(); } catch (_) {} }
    oneShots.clear();
  }

  /** Continuous sounds for a state: rain (running), knock (waiting). */
  function loopsFor(state) {
    if (muted) return;
    const g = gen;
    if (state === "running" && !rainMuted) rainNode = play(rain(), true);
    if (state === "waiting") {
      play(knock());
      knockTimer = setInterval(() => { if (g === gen && !muted) play(knock()); }, 2500);
    }
  }

  /** Called when the overall state changes (a real transition). */
  function forState(state) {
    stopLoops();
    if (muted) { suspendSoon(); return; }
    if (state === "done") { play(whistle()); suspendSoon(1050); return; }
    loopsFor(state);
    if (!rainNode && !knockTimer) suspendSoon();
  }
  return {
    forState,
    /** Initial settings; plays nothing (the first load is silent). */
    init(m, r) { muted = m; rainMuted = r; },
    /** Muting stops everything at once; unmuting resumes only the loops
     *  (a finished task's whistle is not replayed). */
    setMuted(v, current) {
      muted = v;
      stopEverything();
      if (!v) loopsFor(current);
      if (!rainNode && !knockTimer) suspendSoon();
    },
    setRainMuted(v, current) {
      rainMuted = v;
      if (current === "running") { stopLoops(); loopsFor(current); if (!rainNode) suspendSoon(); }
    },
  };
})();
