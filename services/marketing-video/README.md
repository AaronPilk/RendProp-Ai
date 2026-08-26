# Rendprop — Marketing Video (agent reels)

Turns a listing's walkthrough clip + its data (address, price, beds/baths, features)
into a cinematic, captioned vertical marketing reel (1080×1920) for agents to post.

Two render paths, same design language (Rendprop purple, glass captions, hero moments):

## 1) HyperFrames composition — `composition/index.html`  (production path)
An HTML→video composition for **HyperFrames** (HeyGen's open-source engine, Apache-2.0).
Lint-clean, seek-safe (GSAP paused timeline, hard-kills at clip boundaries).
Render on any Node 22 + FFmpeg + headless-Chrome host:

    npx hyperframes render composition        # -> renders/main.mp4

Hosts: a small container (Fly.io/Render/Railway), AWS Lambda (`hyperframes lambda`),
or HeyGen cloud (`hyperframes cloud`, no local Chrome/ffmpeg). This is the path to
productize: a render worker takes {listing, agent clip} → mp4 → R2 → surfaced in the app.

Note: headless Chrome needs display libs — it does NOT run in a stock non-root
sandbox. Use a proper render host / container image with the deps installed.

## 2) FFmpeg fallback — `ffmpeg-fallback/gen.py`  (zero-browser path)
Pillow renders the background + glass caption frames; FFmpeg composites them over the
clip with timed fades + a progress bar. No headless Chrome — runs anywhere with
Python (Pillow, cairosvg) + FFmpeg. Lower motion fidelity than HyperFrames, but
dependency-light. This is what rendered the shipped sample.

    python3 ffmpeg-fallback/gen.py && ffmpeg ...   # see gen.py header

## Sample
`rendprop-marketing.mp4` (demo estate "1180 Crestline Ridge"). The footage is the app's
bundled demo reel; real listings use the agent's own walkthrough.

## Productization sketch
iOS "Marketing Video" screen → pick listing + clip + template → POST to a render
worker → poll (same pattern as the AI-video job flow) → download/share the mp4.
Captions are 100% data-driven from the listing, so every agent's reel is auto-built.
