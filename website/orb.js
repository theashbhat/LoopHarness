// Loop's pixel-grid orb, ported from LoopIOS/HelperViews/AvatarView.swift.
// Square grid for the web (the iOS app uses 25×15 — wider than tall so it
// crops into the chat layout — but on the web the orb stands alone so a
// square reads more like a sphere). Same radial intensity formula, same
// per-mode palette, same idle breathing math. Same spherical "spin" the app
// uses (SpinMode.spherical): each pixel is a point on a 3D sphere rotating
// around the Y axis, so the surface texture orbits the center instead of
// just sitting there. Adds two web-only delighters absent from the native
// app: cursor-lean and a click ripple.
//
// Public API:
//   Orb.mount(canvas, { density, mode, intensity, reactive, spin }) → handle
//   handle.setMode('idle' | 'listening') — flips palette for hold-to-talk
//
// No framework. ~140 LOC of vanilla JS. Reads as a single self-contained IIFE.

(function () {
  const PALETTES = {
    idle:      "217, 222, 235",   // (0.85, 0.87, 0.92) — soft cool white
    listening: "51, 199, 255",    // systemCyan — attentive, resting
    talking:   "51, 199, 255",    // systemCyan — actively responding (animated)
  };

  function mount(canvas, opts) {
    const o = Object.assign(
      {
        density: 25,
        mode: "idle",
        intensity: 1.0,
        reactive: true,
        drift: true,
        // Spherical spin (AvatarView.SpinMode.spherical). `spin` toggles it;
        // spinSpeed is Y-axis rotation in rad/s; spinBands is the longitudinal
        // band count of the procedural surface texture. Both lifted from
        // AvatarView.swift's `rotationSpeed` / `spinBandCount`.
        spin: true,
        spinSpeed: 1.2,
        spinBands: 4.0,
      },
      opts || {}
    );

    const ctx = canvas.getContext("2d");
    const dpr = Math.min(window.devicePixelRatio || 1, 2);

    let cells = o.density;
    let cellSize = 1;
    let size = 1;

    function resize() {
      const rect = canvas.getBoundingClientRect();
      size = Math.max(1, Math.min(rect.width, rect.height));
      canvas.width = Math.round(size * dpr);
      canvas.height = Math.round(size * dpr);
      ctx.setTransform(1, 0, 0, 1, 0, 0);
      ctx.scale(dpr, dpr);
      cellSize = size / cells;
    }

    resize();
    const ro = new ResizeObserver(resize);
    ro.observe(canvas);

    const mouse = { x: 0.5, y: 0.5, active: false, ping: 0 };
    let mode = o.mode;
    let raf = 0;
    const start = performance.now();

    function rgba(level) {
      // Continuous per-cell alpha, like the native orb (AvatarView draws each
      // cell with `withAlphaComponent(alpha)` — no quantization). The grid
      // itself supplies the pixel-art look; quantizing the alpha on top of it
      // just flattens the spin's subtle band modulation into a single bin, so
      // the orb reads as static. Keeping alpha smooth lets the rotation show.
      const q = Math.max(0, Math.min(1, level));
      return `rgba(${PALETTES[mode]}, ${(q * o.intensity).toFixed(3)})`;
    }

    // Port of AvatarView.swift `sphericalIntensity`: treat the cell (dx, dy)
    // as a point on a sphere of radius r, recover z, then rotate longitude by
    // spinSpeed·t so the banded surface texture orbits the center. Equator
    // moves fast, poles barely move — reads as a spinning globe. Limb
    // darkening + a fixed specular highlight give it volume.
    function spherical(base, dx, dy, r, t) {
      const d = Math.sqrt(dx * dx + dy * dy);
      if (d >= r) return base;

      const z = Math.sqrt(Math.max(0, r * r - dx * dx - dy * dy));
      const lon = Math.atan2(dx, z) + o.spinSpeed * t;
      const lat = Math.asin(Math.max(-1, Math.min(1, dy / r)));
      const pattern = 0.82 + 0.18 * Math.sin(lon * o.spinBands + lat * 1.5);

      const cosAngle = z / r;
      const limb = 0.55 + 0.45 * Math.pow(cosAngle, 0.6);

      const nx = dx / r, ny = dy / r, nz = z / r;
      const ldot = Math.max(0, nx * 0.5 + ny * -0.5 + nz * 0.7071);
      const spec = Math.pow(ldot, 16) * 0.25;

      return base * pattern * limb + spec;
    }

    function draw() {
      const t = (performance.now() - start) / 1000;
      ctx.clearRect(0, 0, size, size);

      const cx = (cells - 1) / 2;
      const cy = (cells - 1) / 2;

      // Per-mode radius + fill, pulled from AvatarView.swift `shape(for:)`.
      //   idle      — gentle breathing, sin(t*1.4)*0.066*baseR
      //   listening — shrinks the resting radius so the cyan glow reads "attentive"
      //   talking   — speaking wobble: the orb actively grows/pulses as if it's
      //               mid-response (AvatarView's .speaking fallback, two summed sines)
      const baseR = cells * 0.34;
      let breathe, scale;
      if (mode === "talking") {
        const wobble = Math.abs(0.5 * Math.sin(t * 7.0) + 0.3 * Math.sin(t * 4.3));
        breathe = baseR + baseR * 0.474 * wobble;
        scale = 0.7 + 0.3 * wobble;
      } else if (mode === "listening") {
        breathe = baseR - baseR * 0.08;
        scale = 0.62;
      } else {
        breathe = baseR + baseR * 0.066 * Math.sin(t * 1.4);
        scale = 0.45;
      }

      // Cursor-lean (web-only): shifts the highlight center toward the
      // cursor by up to ±0.18 grid units of the radius. Tiny but readable.
      const leanX = o.reactive && mouse.active ? (mouse.x - 0.5) * cells * 0.18 : 0;
      const leanY = o.reactive && mouse.active ? (mouse.y - 0.5) * cells * 0.18 : 0;
      const driftX = o.drift ? Math.sin(t * 0.6) * 0.8 : 0;
      const driftY = o.drift ? Math.cos(t * 0.45) * 0.6 : 0;
      const hx = cx + leanX + driftX;
      const hy = cy + leanY + driftY;

      // Click ripple — decays over ~1s, draws as a bright band.
      const ping = mouse.ping;
      if (ping > 0) mouse.ping = Math.max(0, ping - 0.018);

      const r = breathe;

      for (let y = 0; y < cells; y++) {
        for (let x = 0; x < cells; x++) {
          const dx = x - cx;
          const dy = y - cy;
          const d = Math.sqrt(dx * dx + dy * dy);

          // Match AvatarView.swift `intensity(for:dx:dy:t:)` non-thinking branch:
          //   inside: (1 - d/r) * scale
          //   outside soft band: max(0, 1 - (d-r)*1.4) * scale * 0.7
          let i;
          if (d < r) {
            i = (1 - d / Math.max(r, 0.01)) * scale;
          } else {
            i = Math.max(0, 1 - (d - r) * 1.4) * scale * 0.7;
          }

          // Orbit the surface texture around the center (matches the app).
          if (o.spin) i = spherical(i, dx, dy, r, t);

          if (i < 0.04) continue;

          // Cursor highlight: lift cells near (hx, hy).
          const hd = Math.sqrt((x - hx) ** 2 + (y - hy) ** 2);
          const lift = Math.max(0, 1 - hd / (cells * 0.55)) * 0.35;
          i += lift * scale;

          // Click ripple band.
          if (ping > 0) {
            const bandR = r * (1.0 + (1 - ping) * 0.8);
            if (Math.abs(d - bandR) < 0.55) {
              i = Math.max(i, ping * 0.8);
            }
          }

          ctx.fillStyle = rgba(i);
          const px = x * cellSize;
          const py = y * cellSize;
          ctx.fillRect(px, py, cellSize - 1, cellSize - 1);
        }
      }

      raf = requestAnimationFrame(draw);
    }
    raf = requestAnimationFrame(draw);

    if (o.reactive) {
      canvas.addEventListener("mousemove", (e) => {
        const rect = canvas.getBoundingClientRect();
        mouse.x = (e.clientX - rect.left) / rect.width;
        mouse.y = (e.clientY - rect.top) / rect.height;
        mouse.active = true;
      });
      canvas.addEventListener("mouseleave", () => {
        mouse.x = 0.5; mouse.y = 0.5; mouse.active = false;
      });
      canvas.addEventListener("mousedown", () => { mouse.ping = 1; });
    }

    return {
      setMode(next) { if (PALETTES[next]) mode = next; },
      destroy() { cancelAnimationFrame(raf); ro.disconnect(); }
    };
  }

  window.Orb = { mount };
})();
