#!/usr/bin/env node
// check-assets.mjs — deploy preflight for the media that is NOT in git.
//
// The demo tour's two video files sit right under the 25 MiB Workers Static
// Assets cap and are not tracked, so a fresh clone would deploy a demo whose
// video 404s — the site's primary CTA, dead, with nothing in CI to say so
// (audit F-H-10). The player degrades honestly ("This tour's video isn't
// available right now") rather than showing a black stage, but the deploy
// should still refuse to be silent about it.
//
// Long term these belong in the public R2 bucket like a real tour's media;
// see HANDOFF.md.

import { statSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const MAX_BYTES = 25 * 1024 * 1024; // Workers Static Assets per-file cap

const REQUIRED = [
  ["public/assets/demo-tour.mp4", "the scroll-scrub master behind /f/estate-demo"],
  ["public/assets/demo-reel.mp4", "the vertical social reel in the demo's Reel section"],
];

const problems = [];
for (const [rel, what] of REQUIRED) {
  let st;
  try { st = statSync(join(ROOT, rel)); }
  catch { problems.push(`missing ${rel} — ${what}`); continue; }
  if (!st.size) problems.push(`${rel} is empty`);
  else if (st.size > MAX_BYTES) {
    problems.push(`${rel} is ${(st.size / 1048576).toFixed(1)} MiB — over the 25 MiB Static Assets cap, so the deploy will reject it`);
  }
}

if (problems.length) {
  console.error("\u2716 asset preflight FAILED:\n");
  for (const p of problems) console.error("  - " + p);
  console.error("\n  These files are deliberately not in git (size). Copy them into\n  public/assets before deploying, or the demo tour ships without video.\n");
  process.exitCode = 1;
} else {
  console.log(`\u2714 asset preflight passed — ${REQUIRED.length} demo media files present and under the 25 MiB cap.`);
}
