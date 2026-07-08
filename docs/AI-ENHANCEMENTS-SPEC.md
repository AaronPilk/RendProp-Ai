# Rendprop AI Enhancements — Declutter & Virtual Restaging

Add-on layer on top of the deterministic pipeline. Two products, one rule: **furniture and decor only — the architecture never changes.** Walls, windows, floors, fixtures, and views are sacred; a buyer who shows up to a different house is a lawsuit and a brand killer.

## The two add-ons

| Add-on | What it does | Price (v1) | UI |
|---|---|---|---|
| **Auto-declutter** | Removes boxes, mess, cords, counter clutter from every room | **+$19/render** | Toggle in Review & Submit |
| **Virtual restage** | Re-styles furniture, wall art, and decor in a chosen design style | **+$49/render** | Style picker: As-is · Modern · Rustic · Minimalist · Scandinavian |

Both are wired end-to-end in the iOS app (`Enhancements` model → API → render job → status steps) and stored on `render_jobs.enhancements` (jsonb).

## Provider stack

| Role | Provider | Why |
|---|---|---|
| **Orchestration, room understanding & QC judge** | **Claude (Fable 5) API** | Vision calls: classify rooms, detect clutter objects to mask, write per-segment restage prompts, and act as the **drift judge** — compare source vs. enhanced frames and score structural consistency (0–100). Below threshold → auto-regen or fall back to original. |
| **Generative video (restage, hero clips)** | **Higgsfield** | Video generation/restyle + i2v; also covers upscale/reframe utilities. Already connected via MCP for prototyping — we can test restage looks on real frames before writing a line of pipeline code. |
| **Image-to-video (hero clips, doorway transitions, restage seeds)** | **Seedance** | The master spec's pick for i2v seeded from real frames; strong prompt adherence and structural fidelity on 8–15s clips. |
| Masking (declutter) | SAM-2 (self-hosted GPU) | Object masks for clutter items across frames |
| Video inpainting (declutter) | ProPainter-class model (self-hosted) | Temporally consistent removal — no flicker |

All behind the `GenerativeVideoProvider` / `RenderStep` abstractions (master spec Appendix G) so providers can be swapped per cost/quality.

## How it actually works (per room segment, never full-length)

**Declutter:**
1. Fable 5 vision pass on segment keyframes → list of removable clutter (boxes, piles, cords) with bounding hints. Explicit denylist: anything structural, anything that looks like personal property disputes (art the seller keeps is fine to remove; a wall is not).
2. SAM-2 propagates masks across the segment's frames.
3. Video inpainting fills the masked regions with temporal consistency.
4. QC: Fable 5 judges before/after keyframes — geometry unchanged? artifacts? → pass / regen (capped) / fall back to original segment.

**Restage:**
1. Segment the walkthrough by room (chapter tags + Fable 5 room classification).
2. Per segment: extract keyframes → depth/edge maps (structure lock).
3. Structure-conditioned restyle (Higgsfield/Seedance i2v seeded from REAL frames + style prompt from a per-style template library) — regenerate the segment's look while motion and geometry follow the original.
4. QC drift judge (Fable 5): room layout identical? windows/doors unmoved? style coherent with adjacent segments? → pass / regen / fall back.
5. Stitch enhanced segments back into the deterministic backbone with crossfades.

**Cost ceilings:** per-job generative budget (declutter ~$3–6, restage ~$8–20 depending on duration) with a hard ceiling; if exceeded → pause + ops alert (master spec 6.4). Priced at 3–5× COGS.

## Compliance (non-negotiable)

- Any render with an active enhancement sets `virtually_staged=true` on its share page → the player shows the **"✦ Virtually staged"** chip (already built into the player).
- MLS/board rules require disclosure of digitally altered/staged media. Never remove or alter structural elements, permanent fixtures, or views. Never "repair" visible defects (that's misrepresentation).
- The app tells the agent about the disclosure at purchase time (built into Review & Submit).

## Phasing

- **Now (done):** app UX + pricing + API pass-through + pipeline step slots + disclosure chip.
- **Phase 2a:** stills first — declutter/restage listing PHOTOS (much easier, instant market value, same providers). Prototype restage looks via Higgsfield MCP on real keyframes.
- **Phase 2b:** video declutter on locked-off/slow segments; restage on short room segments with QC gates.
- **Phase 3:** full-walkthrough restage as models mature; per-style preview thumbnails in the picker (generate one restaged keyframe per style before the agent buys).
