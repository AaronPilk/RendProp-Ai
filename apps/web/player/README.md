# Rendprop Scroll-Scrub Player — ARCHIVED PROTOTYPE

**Status: archived (2026-09-03), confirmed against the 24 September source.**
Nothing in the production build or serving paths uses this directory. For the
current browser creation product, see [Rendprop Studio](../../studio/README.md) and
[its latest release](../../../docs/handoff/CODEX-STUDIO-LIVE-20260924.md).

This was the Phase-0 proof of the scroll-scrub idea (Master Build Prompt Parts 5,
27, 37). It is kept as a runnable reference only. The product's real engines live
elsewhere and have diverged from this file:

| Copy | Role | Status |
|---|---|---|
| [tour-host player.ts](../../../services/edge/tour-host/src/player.ts) (`ENGINE_JS`) | **Canonical.** The hosted tour page at `rendprop.com/f/<slug>` — real `/leads` + `/beacon` endpoints, per-industry lead fields, SOLD/Archived state, "video unavailable" state, decaying jank watchdog, XSS hardening. | production |
| [iOS bundled player](../../ios/Rendprop/Resources/player/index.html) | In-app preview: a copy of the same `tick()`/watchdog logic with local stubs for the form/beacon. | production (bundled) |
| [index.html](index.html) (this directory) | Original prototype. Naive jank watchdog, no NaN/readyState guards, hardcoded data, `localStorage` stubs. | **archived** |

When the tour engine changes, update the canonical host implementation and check
parity with the bundled iOS preview. Use the [tour-host checks](../../../services/edge/tour-host/README.md)
for public behavior; shipping native preview changes requires a separate iOS build.
Do not fix bugs here.

## Run the prototype (reference only)

```bash
cd apps/web/player
python3 -m http.server 8080
# open http://localhost:8080 — or your LAN IP on an iPhone
```

It expects a `demo.mp4` next to `index.html` (not in git). Any short all-intra
mp4 works; `CHAPTERS` in the file are hardcoded for the original 55 s sample.
