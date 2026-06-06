// site.js — orb mounts + interactive bits (tabs, hold-to-talk).
// Runs on DOMContentLoaded; degrades cleanly if a node is missing.

(function () {
  const ready = (fn) =>
    document.readyState === "loading"
      ? document.addEventListener("DOMContentLoaded", fn)
      : fn();

  ready(() => {

    // ── 1. mount orbs ────────────────────────────────────────────
    const orbs = {};
    document.querySelectorAll("canvas[data-orb]").forEach((c) => {
      const which = c.dataset.orb;
      const config = {
        hero:       { density: 26, intensity: 1.1, reactive: true,  drift: true },
        phone:      { density: 22, intensity: 1.0, reactive: false, drift: true },
        "mac-small":{ density: 14, intensity: 1.0, reactive: false, drift: false },
        vision:     { density: 20, intensity: 1.2, reactive: false, drift: true },
        // Brand mark = a tiny live avatar so the logo matches the hero orb.
        nav:        { density: 11, intensity: 1.15, reactive: false, drift: false },
        foot:       { density: 10, intensity: 1.1,  reactive: false, drift: false },
      }[which] || { density: 22 };
      orbs[which] = window.Orb.mount(c, config);
    });

    // ── 2. surfaces device switcher ──────────────────────────────
    const tabs = document.querySelectorAll(".tab[data-tab]");
    const copies = document.querySelectorAll(".surfaces__copy > div[data-surface]");
    const devices = document.querySelectorAll(".surfaces__device > [data-surface]");

    function setSurface(id) {
      tabs.forEach((t) => t.classList.toggle("is-active", t.dataset.tab === id));
      copies.forEach((d) => d.classList.toggle("is-active", d.dataset.surface === id));
      devices.forEach((d) => d.classList.toggle("is-active", d.dataset.surface === id));
    }
    tabs.forEach((t) => t.addEventListener("click", () => setSurface(t.dataset.tab)));

    // ── 3. hold-to-talk ──────────────────────────────────────────
    // Mirrors the app's voice flow as a three-beat sequence:
    //   1. press & hold → the waveform "lines" spring open (recording)
    //   2. the spoken message transcribes in, character by character
    //   3. once it's fully typed, the lines fold away and the orb flips to
    //      its blue "talking" palette — the assistant taking the turn.
    const strip = document.querySelector("[data-hold]");
    const txt = document.querySelector("[data-hold-txt]");
    const wave = document.querySelector("[data-hold-wave]");
    if (strip && txt) {
      const fullText =
        "open the doc i was editing last night and add a section on pricing — " +
        "pull the numbers from the Notion page called Q3 Plan";

      // Build the waveform bars once, staggering each one's animation so the
      // row ripples rather than pulsing in lockstep.
      if (wave && !wave.childElementCount) {
        for (let b = 0; b < 14; b++) {
          const bar = document.createElement("span");
          bar.style.animationDelay = (b * 0.07).toFixed(2) + "s";
          wave.appendChild(bar);
        }
      }

      let typer = null;
      let i = 0;

      const start = () => {
        if (typer) return;
        // Beat 1 + 2: recording — lines visible, orb still idle, text types in.
        strip.classList.add("is-holding", "is-recording");
        strip.classList.remove("is-talking");
        if (orbs.hero) orbs.hero.setMode("idle");
        i = 0;
        txt.textContent = "";
        typer = setInterval(() => {
          i += 2;
          if (i >= fullText.length) {
            // Beat 3: message fully typed → drop the cursor, fold the lines,
            // and hand the turn to the orb's blue talking state.
            clearInterval(typer);
            typer = null;
            txt.textContent = fullText;
            strip.classList.remove("is-recording");
            strip.classList.add("is-talking");
            if (orbs.hero) orbs.hero.setMode("talking");
            return;
          }
          txt.textContent = fullText.slice(0, i) + "▌";
        }, 35);
      };
      const stop = () => {
        if (typer) { clearInterval(typer); typer = null; }
        strip.classList.remove("is-holding", "is-recording", "is-talking");
        if (orbs.hero) orbs.hero.setMode("idle");
        txt.textContent = "press and hold to speak →";
      };

      strip.addEventListener("mousedown",  start);
      strip.addEventListener("mouseup",    stop);
      strip.addEventListener("mouseleave", stop);
      strip.addEventListener("touchstart", (e) => { e.preventDefault(); start(); }, { passive: false });
      strip.addEventListener("touchend",   stop);
    }
  });
})();
