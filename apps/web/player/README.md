# Rendprop Scroll-Scrub Player

The product's face — the link shared to Instagram and opened by prospects on their phones. Spec: Master Build Prompt Parts 5, 27, 37.

## Run the demo

```bash
cd apps/web/player
python3 -m http.server 8080
# open http://localhost:8080 — or your LAN IP on an iPhone
```

`demo.mp4` is a synthetic 55s "walkthrough" (6 color-graded scenes with crossfades, encoded all-intra-ish `-g 3` for instant seeks). Swap in a real stabilized walkthrough encoded with the scrub-proxy recipe in `services/pipeline/README.md` and update `CHAPTERS` in `index.html`.

## What's implemented (Path A — video-scrub)

- Tall track + sticky 100svh video; scroll position → `video.currentTime` via rAF lerp (`curT += (target-curT)*0.1`) with 0.02s set-threshold — the butter
- Buffer gate at 96% with % loader; `canplaythrough` fallback; 6s never-strand fallback
- Room labels fading by scroll anchor (transform/opacity only, no layout in the loop)
- Chapter rail (tap a room → smooth-scroll to anchor)
- Progress bar `scaleX(p)`; scrub hint that fades on first interaction
- Listing chip, agent card, "Book a showing" lead form end-card
- "Made with Rendprop" watermark (growth loop)
- Jank watchdog → autoplay-loop fallback (Low Power Mode / IG-webview ladder)
- `visualViewport` resize handling (iOS toolbar show/hide), `100svh`, safe-area insets
- Metering stub: streamed-minutes + scroll-depth accumulated, flushed on pagehide (swap `localStorage` for `navigator.sendBeacon('/f/:slug/view')` in prod)
- `prefers-reduced-motion` gentler lerp
- `muted playsinline preload=auto disablepictureinpicture disableremoteplayback` + `webkit-playsinline`

## Still to do for prod

- HLS scrub proxy (native on iOS Safari, hls.js elsewhere) instead of a flat MP4
- Tap/fullscreen swap to high-bitrate playback rendition (1080p/4K)
- Sprite/VTT hover thumbnails (desktop) + timeline room ticks (mobile)
- Real beacon endpoint + signed playback URLs + OG image per render
- The #1 test surface: Instagram/TikTok in-app webviews on real devices (Part 37 ship gate)
