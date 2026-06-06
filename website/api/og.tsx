// Dynamic Open Graph share card for loopharness.com.
//
// Rendered on the fly by a Vercel Edge Function via @vercel/og (Satori +
// resvg). No static asset, no build step on our end — referenced from
// index.html as <meta property="og:image" content="https://loopharness.com/api/og">.
//
// The orb is the real avatar: the same pixel grid + spherical-spin intensity
// formula as orb.js / AvatarView.swift, frozen at one spin frame and baked
// into an inline SVG so it matches the site exactly.

import { ImageResponse } from "@vercel/og";

export const config = { runtime: "edge" };

const SIZE = { width: 1200, height: 630 };

// ── orb: faithful pixel-grid avatar, one frozen spin frame ──────────────
function orbDataUri(): string {
  const cells = 30;
  const px = 12; // → 360×360 svg
  const t = 1.6; // pleasing spin frame
  const spinSpeed = 1.2;
  const spinBands = 4.0;

  const cx = (cells - 1) / 2;
  const cy = (cells - 1) / 2;
  const baseR = cells * 0.34;
  const r = baseR + baseR * 0.066 * Math.sin(t * 1.4); // idle breathe
  const scale = 0.45;

  let rects = "";
  for (let y = 0; y < cells; y++) {
    for (let x = 0; x < cells; x++) {
      const dx = x - cx;
      const dy = y - cy;
      const d = Math.sqrt(dx * dx + dy * dy);

      let i =
        d < r
          ? (1 - d / Math.max(r, 0.01)) * scale
          : Math.max(0, 1 - (d - r) * 1.4) * scale * 0.7;

      // Spherical spin (matches orb.js `spherical`).
      if (d < r) {
        const z = Math.sqrt(Math.max(0, r * r - dx * dx - dy * dy));
        const lon = Math.atan2(dx, z) + spinSpeed * t;
        const lat = Math.asin(Math.max(-1, Math.min(1, dy / r)));
        const pattern = 0.82 + 0.18 * Math.sin(lon * spinBands + lat * 1.5);
        const limb = 0.55 + 0.45 * Math.pow(z / r, 0.6);
        const nx = dx / r;
        const ny = dy / r;
        const nz = z / r;
        const ldot = Math.max(0, nx * 0.5 + ny * -0.5 + nz * 0.7071);
        const spec = Math.pow(ldot, 16) * 0.25;
        i = i * pattern * limb + spec;
      }

      const a = Math.max(0, Math.min(1, i * 2.3));
      if (a < 0.04) continue;
      rects += `<rect x="${(x * px).toFixed(1)}" y="${(y * px).toFixed(
        1
      )}" width="${px - 1}" height="${px - 1}" fill="rgb(217,222,235)" fill-opacity="${a.toFixed(
        3
      )}"/>`;
    }
  }

  const s = cells * px;
  const svg = `<svg xmlns="http://www.w3.org/2000/svg" width="${s}" height="${s}" viewBox="0 0 ${s} ${s}">${rects}</svg>`;
  return `data:image/svg+xml;base64,${btoa(svg)}`;
}

// ── fonts: pull just the glyphs we need from Google Fonts ───────────────
// Old UA forces a TTF src (Satori parses TTF/OTF reliably). Subsetting via
// `&text=` keeps each fetch tiny.
async function loadFont(family: string, weight: number, text: string) {
  const url = `https://fonts.googleapis.com/css2?family=${family.replace(
    / /g,
    "+"
  )}:wght@${weight}&text=${encodeURIComponent(text)}`;
  const css = await (
    await fetch(url, { headers: { "User-Agent": "Mozilla/5.0 (Windows NT 5.1)" } })
  ).text();
  const m = css.match(/src: url\((.+?)\) format\('(?:opentype|truetype)'\)/);
  if (!m) throw new Error(`font fetch failed: ${family}`);
  const res = await fetch(m[1]);
  if (!res.ok) throw new Error(`font download failed: ${family}`);
  return res.arrayBuffer();
}

const WORDMARK = "Loop";
const TAGLINE = "A personal AI that lives on your devices.";
const DEVICES = "IPHONE · MAC · VISION · OPEN-SOURCE";

export default async function handler() {
  const orb = orbDataUri();

  // If Google Fonts is unreachable, still return a valid card (orb only)
  // so shares never break.
  let fonts: { name: string; data: ArrayBuffer; weight: 400 | 600; style: "normal" }[] = [];
  try {
    const [interBold, interReg, serif] = await Promise.all([
      loadFont("Inter Tight", 600, WORDMARK),
      loadFont("Inter Tight", 400, DEVICES),
      loadFont("Instrument Serif", 400, TAGLINE),
    ]);
    fonts = [
      { name: "Inter Tight", data: interBold, weight: 600, style: "normal" },
      { name: "Inter Tight", data: interReg, weight: 400, style: "normal" },
      { name: "Instrument Serif", data: serif, weight: 400, style: "normal" },
    ];
  } catch {
    fonts = [];
  }

  const hasFonts = fonts.length > 0;

  return new ImageResponse(
    (
      <div
        style={{
          width: "100%",
          height: "100%",
          display: "flex",
          flexDirection: "column",
          alignItems: "center",
          justifyContent: "center",
          background: "#0a0a0a",
        }}
      >
        {/* eslint-disable-next-line @next/next/no-img-element */}
        <img width={300} height={300} src={orb} alt="" />

        {hasFonts && (
          <div
            style={{
              fontFamily: "Inter Tight",
              fontWeight: 600,
              fontSize: 104,
              color: "#e9e4d8",
              letterSpacing: "-0.04em",
              marginTop: 8,
            }}
          >
            {WORDMARK}
          </div>
        )}

        {hasFonts && (
          <div
            style={{
              fontFamily: "Instrument Serif",
              fontSize: 42,
              color: "rgba(233,228,216,0.72)",
              marginTop: 4,
            }}
          >
            {TAGLINE}
          </div>
        )}

        {hasFonts && (
          <div
            style={{
              fontFamily: "Inter Tight",
              fontWeight: 400,
              fontSize: 21,
              color: "rgba(233,228,216,0.40)",
              letterSpacing: "0.2em",
              marginTop: 30,
            }}
          >
            {DEVICES}
          </div>
        )}
      </div>
    ),
    {
      ...SIZE,
      fonts,
      headers: {
        "cache-control": "public, immutable, no-transform, max-age=86400, s-maxage=604800",
      },
    }
  );
}
