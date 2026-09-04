# 3D + Promo-Video Capability — Decision Brief

**Date:** 2026-09-04 · **For:** Rendprop AI route logic
**Question asked:** "Astra can turn a Zillow listing into a 3D model and a polished promo video, and model a house in Blender. Can we add that?"

**Short answer:** The premise is wrong in three separate places, but there is a real, buildable, cheap capability underneath it — and Rendprop is unusually well-positioned to ship it because the walkthrough video you already capture is exactly the input the good technique wants. The Zillow-photo ingestion half is not viable and should be dropped outright.

---

## 0. Bottom line up front

| Claim | Reality |
|---|---|
| "GPT's Astra" | **Astra is Google's, not OpenAI's.** It shipped as **Gemini Live**. It is a live-camera assistant. It does not build 3D models and does not generate video. |
| OpenAI can do this | **OpenAI has no video generation product as of 20 days from now.** The Sora app shut down 26 Apr 2026; the Videos API and every `sora-2` alias are **removed from the API on 24 Sep 2026**, with **no replacement named**. |
| "Build a 3D model of the house from listing photos" | Callable today via **World Labs' World API (Marble)** at **$0.20–$2.40 per space** — but it reconstructs **one room per call**, invents anything the camera never saw, and has **no API to join rooms into a house**. |
| "Model a house with Blender" | Technically true, economically absurd as a per-listing pipeline: **Cycles interior ≈ $270–$720 of GPU per 30-second clip**. Also nobody has authored the scene. |
| "From a Zillow listing's photos" | **Do not build this.** Zillow's ToU bans automated access outright; the photos are third-party copyright; the only fully-litigated case on exactly this fact pattern ended in **2,700 separate statutory awards and $1,927,200**. Zillow's own licensed data feed **does not include listing photos at all**. |

**What to build instead:** per-room Gaussian splats generated from the walkthrough video the agent already shoots, rendered live in the existing scroll-scrub player with an MIT-licensed renderer. **~$1.28/room, ~5 min, zero new legal exposure, no video render step at all.** Details in §5.

---

## 1. What "Astra" actually is, and what is callable today

### 1.1 Astra is Google's, and it is not this

Project Astra is a **Google DeepMind research prototype** — "a research prototype exploring breakthrough capabilities for Google products — on the way to building a universal AI assistant." What shipped from it is **Gemini Live**: real-time camera and screen sharing, native audio dialogue in 24 languages, context-aware answers. Everything else (agentic actions, advanced memory, XR glasses) is a **Trusted Tester waitlist prototype**. ([Android Central](https://www.androidcentral.com/apps-software/ai/project-astra))

**Astra has no 3D reconstruction and no video generation, in any tier, demo or shipped.** Whoever wrote the thing the owner read conflated Astra with Veo, Genie, and Marble.

### 1.2 OpenAI: the video capability is being switched off this month

This is the most operationally urgent fact in this brief.

From OpenAI's own deprecations page: *"On March 24th, 2026, we notified developers using the Videos API and Sora 2 video generation model aliases and snapshots of their deprecation and removal from the API on September 24, 2026."* Affected: the **Videos API**, `sora-2`, `sora-2-pro`, `sora-2-2025-10-06`, `sora-2-2025-12-08`, `sora-2-pro-2025-10-06`. **Recommended replacement: none listed.** ([OpenAI deprecations](https://developers.openai.com/api/docs/deprecations))

The consumer Sora app was shut down **26 April 2026**. Reported drivers: ~$1M/day to operate, worldwide users peaked near 1M then fell below 500K, and a strategic pivot to enterprise under compute constraints. ([Wikipedia](https://en.wikipedia.org/wiki/Sora_(text-to-video_model)))

**Action item independent of this brief:** if any code path, doc, or roadmap in Rendprop names Sora as a fallback, remove it. It is dead in 20 days. (I checked — `services/pipeline` does not reference it. Confirm nothing in the marketing-video service or docs does.)

### 1.3 Google: what is actually callable

| Thing | Status | Callable? |
|---|---|---|
| **Gemini Live** (the Astra product) | GA | Live API — assistant, not generation |
| **Veo 3.1** | GA | Yes — Gemini API, and on fal (see §3.4 for prices) |
| **Gemini 3.1 Flash Image** ("Nano Banana 2") | GA | Yes — `gemini-3.1-flash-image`, $0.045/0.5K · $0.067/1K · $0.101/2K · $0.151/4K per image ([pricing](https://ai.google.dev/gemini-api/docs/pricing)) |
| **Gemini Omni Flash** video output | GA | `gemini-omni-1.1-flash`, ~$0.10/sec at 720p |
| **Genie 3 / Project Genie** | **Research prototype** | **No API.** Google AI **Ultra subscribers, US only**, 18+, from 29 Jan 2026. Worlds capped at **60 seconds**. ([Google blog](https://blog.google/innovation-and-ai/models-and-research/google-deepmind/project-genie/)) |

**Genie is the thing that looks like the demo reel.** It is not purchasable as an API and generates *plausible interactive worlds*, not measured reconstructions of a specific house. Rule it out.

**Note for the cost table:** `gemini-3.1-flash-image` at **$0.067 per 1K image** is now materially cheaper than the **3.9¢** the repo's `costs.py` carries for `restage_gemini` (Gemini 2.5 Flash Image). That is a ~42% cut sitting unclaimed. Separately, **Veo 3.1 Lite on fal is $0.03/s at 720p without audio** vs the 4.8¢/s the cost table assumes for Seedance hero clips — worth a re-benchmark, not just a price swap, since quality differs.

---

## 2. Photos → 3D model of a house: what genuinely works in Sept 2026

### 2.1 The category split that matters

There are **three different things** all marketed as "photo to 3D," and only one of them is relevant:

1. **Object generators** (Tripo, Hunyuan3D, Trellis, Meshy, Rodin) — take one image, hallucinate a *single furniture-scale object* as a mesh. **Wrong tool.** These are asset generators for games; the docs and comparison write-ups position them for "furniture with clean edges," "door handles, light fittings," "upholstered furniture." Feeding one a photo of a house yields a toy house, not the house. ([Visiomake comparison](https://visiomake.com/en/blog/photo-to-3d-model-ai-architects-interior-designers-trellis-hunyuan))
2. **Scene/world generators** (World Labs Marble, HunyuanWorld) — take images or video of a *space* and produce an explorable 3D scene as Gaussian splats. **This is the relevant category.**
3. **Classical photogrammetry / SfM** (Apple Object Capture, RealityCapture) — measured reconstruction from many overlapping photos. Accurate, but object-oriented and needs disciplined capture.

### 2.2 The real options, compared

| Option | Input | Output | Latency | Price/job | Verdict |
|---|---|---|---|---|---|
| **World Labs World API (Marble)** | 1 image, ≤8 images, 1 pano, or **video ≤30 s / ≤100 MB** | Gaussian splat **SPZ/PLY** (500K or 2M splats), collider GLB, HQ mesh GLB, 360 pano | **~5 min/world** | **$0.20** (`marble-1.0-draft`) → **$1.28** (`marble-1.1`) → **$1.20–$2.40** (`marble-1.1-plus`). Splat export **free**. HQ mesh **$2.80** + up to 1 hr | **The only credible callable path.** Caveats in §2.3 |
| **Niantic Spatial Platform** | Mobile capture, 360° video | Gaussian splats | Not published | **30 credits/sec of mobile capture**; Pro $50/mo for 105,000 credits ≈ 58 min → **~$2.57 per 3-min capture**. **Commercial rights require Pro or Enterprise** | Viable, but SDK is Unity/Swift/Kotlin AR-oriented; no documented REST "upload video → get splat" |
| **Scaniverse** (Niantic, consumer) | Phone walkthrough | SPZ, USDZ | **<90 s, fully on-device, offline** | **Free** | Proof that on-device splatting is real on an iPhone today. But it's **an app, not an SDK** — you cannot embed it |
| **Apple `PhotogrammetrySession`** | Directory/sequence of photos | **USDZ** + point cloud + 6DOF poses | Minutes, on-device | **$0** | **iOS 17.0+ / iPadOS 17.0+**, but gated on `isSupported`. See §2.4 |
| **Tripo / Hunyuan3D / Trellis** (fal) | 1 image | GLB/OBJ/FBX/USDZ mesh | Seconds–minutes | Tripo **$0.30** img→3D textured; `fal-ai/hunyuan-3d/v3.1/pro/image-to-3d` **$0.375**; `fal-ai/trellis-2` **$0.25/$0.30/$0.35** by resolution | **Wrong category.** Object generators |
| **`tripo3d/triposplat` (fal)** | 1 image | Gaussian splats | — | No public price on the model card | Single-image splat; same object bias. Untested |
| **`fal-ai/hunyuan_world/image-to-world` (fal)** | 1 image + foreground/class labels | "world file" (format undocumented) | — | **No price published** | Worth a bake-off against Marble draft, but undocumented output format is a red flag |
| **Luma AI** | — | — | — | — | **Gone.** Luma's own LLM-facing page lists only Uni-1.1 (image) and Ray3.2 (video). **No NeRF/splat capture API.** Dream Machine and Ray2 explicitly deprecated ([lumalabs.ai/llm-info](https://lumalabs.ai/llm-info)) |
| **Polycam** | Phone video | Splats, meshes | Real-time–minutes | $12–$60/month | **No documented developer API.** Consumer/prosumer app |
| **World Labs Atlas** | 2–100+ images | Splats, point clouds, depth, 1440p video up to 1 min | — | Not published | **Early access, select partners only.** Watch it; can't build on it |

### 2.3 The three caveats that decide the design (all from World Labs' own docs)

These are load-bearing. Read them before scoping anything.

**(a) One world = one space, not one house.** From the multi-image guide: *"Auto Layout works on standard flat images and reconstructs a single space... To build a larger multi-room space such as a whole house, generate a separate world from each panorama or image set (one per room or vantage point), then combine them with Studio Compose."*

**(b) There is no API for joining rooms.** Studio **Compose** is a GUI tool. Its own doc says: *"a whole house comes together by generating each room on its own and joining them here. **There is no floor plan input that auto-connects rooms**, so you place and connect them yourself."* You would have to hand-align rooms in a browser, per listing. **This kills "automatic whole-house 3D model" as a v1.** Studio **Record** (cinematic flythrough export) is likewise GUI-only, and its docs carry a data-loss warning: keyframes and enhanced video **do not persist** if you leave the page.

**(c) It invents what it didn't see — and says so.** *"Parts of the scene the cameras never see, such as behind closed doors, around solid walls, or up a staircase, are generated plausibly to keep the world explorable, so they won't match a real floor plan of those hidden areas."* Atlas frames the same trade-off: *"the more it sees, the less it imagines."*

**(c) is the compliance crux.** A generated 3D walkthrough of a real listing contains model-invented architecture wherever coverage was thin. That is precisely what NorthstarMLS prohibits and what AB 723 makes disclosable. It is also the argument for dense video capture over sparse photos — which Rendprop already has. See §4.

**Other hard limits worth knowing now:**
- Video input: **max 30 seconds, max 100 MB**, mp4/mov/webm. Images: 1024px long side recommended, ≤20 MB, png/jpg/webp.
- Rate limits: **~3 generation starts/min and 60/hr** by default; 30/min standard or 90/min draft for approved higher-throughput accounts.
- HQ mesh export: **rate-limited to 4/hr per user**, takes up to an hour, only on worlds you own.
- Splats export in **arbitrary units**; the world response carries `semantics_metadata.metric_scale_factor` and `ground_plane_offset` to convert to metres and ground-align. **Useful** — it's the hook for cross-checking a splat against the RoomPlan floor plan.
- **API billing is a separate account from the Marble app.** Marble app credits do not work on the API, and a Marble Free plan does not make API calls free.

### 2.4 Apple on-device: what you actually get (and what you don't)

`PhotogrammetrySession` is **available on iOS 17.0+ and iPadOS 17.0+** (per the availability annotations: `iOS: 17.0.0 -`, `iPadOS: 17.0.0 -`, `macOS: 12.0.0 -`). It's free, offline, and outputs **USDZ**. Three constraints:

1. **Hardware gate.** Docs: *"available on select iOS devices with LiDAR capabilities."* An Apple DTS engineer clarified the real reason: *"Although you don't technically need a LiDAR camera for photogrammetry you do need a powerful GPU and those happen to be in iOS devices that have a LiDAR camera."* Requirement is a GPU with **≥4 GB RAM and ray-tracing support** — in practice **iPhone Pro / Pro Max only**. Always gate on `PhotogrammetrySession.isSupported`.
2. **It is object-oriented, not room-oriented.** The API surface is built around objects: `isObjectMaskingEnabled`, turntable-style capture guidance, `detail: .full` model files. Nothing in the docs supports whole-interior reconstruction, and the capture guidance assumes you orbit a subject.
3. **RoomPlan's roadmap is opaque.** RoomPlan's last substantive update was **iOS 17 (2023)**. Developers publicly flagged that a recent WWDC made no mention of it; Apple's DTS response was to book a lab session rather than to point at anything shipped. **Treat RoomPlan as stable-but-static** — fine to keep depending on for floor plans, unwise to bet new capability on Apple extending it.

**Verdict on the free path:** Object Capture is genuinely free and genuinely on-device, but it is the wrong shape for "walk through a house," and it excludes every non-Pro iPhone. Use it for a *single hero object* if you ever want one. Do not use it for the tour.

### 2.5 Who Zillow SkyTour uses

**Not disclosed.** SkyTour uses Gaussian splatting on **drone imagery**, currently limited to **exteriors on Showcase listings**. Radiance Fields' analysis: *"Zillow has not disclosed whether it relies on an in-house reconstruction pipeline, but given the company's scale and performance demands, a proprietary workflow seems likely."* No vendor, capture spec, or photo count is public. ([Radiance Fields](https://radiancefields.com/zillow-adds-gaussian-splatting-support-with-skytour-unveiling), [Zillow](https://www.zillow.com/news/take-home-listings-to-new-heights-with-skytour/))

**Read the signal, not the vendor:** the largest portal in the category picked **splats over meshes**, and picked **exteriors first** — the easiest case, with the best coverage and the fewest occlusions. That is a strong prior for where quality actually holds up.

---

## 3. Blender headless as a service — the honest numbers

### 3.1 Is it sane?

`blender --background --python script.py` on a cloud GPU is a completely normal, well-trodden production pattern. Running it is not the problem. **The economics and the missing input are.**

### 3.2 What it costs

Render-farm guidance for architectural interiors: *"A single Cycles frame on a modern desktop GPU might take 5 to 15 minutes for an interior scene"*, and *"a Cycles interior scene at 2048 samples rendering in 8 minutes per frame on GPU costs approximately $0.30-0.80 per frame."* ([SuperRenders](https://superrendersfarm.com/article/blender-cloud-rendering-guide))

Cross-checked against raw serverless GPU pricing (Modal: A100-80GB **$0.000694/sec**, L40S **$0.000542/sec**, L4 **$0.000222/sec**; RunPod on-demand: A100-80GB **$1.39/hr**, L40S **$0.99/hr**, RTX 4090 **$0.74/hr**):

| Path | Per frame | **30 s @ 30 fps (900 frames)** |
|---|---|---|
| **Cycles**, 2048 spp, interior, A100-80GB @ 8 min/frame | $0.333 | **~$300** (farm quotes: **$270–$720**) |
| **Eevee**, 10 s/frame, L40S | $0.0054 | **~$5** |
| **Eevee**, 30 s/frame, L40S | $0.0163 | **~$15** |
| **Splat flythrough via headless WebGL** (see §3.4) | — | **~$0.03** |

**Conclusion: Cycles is disqualified per-listing.** Eevee is affordable compute — but Eevee on splats is where the ecosystem actually is: KIRI's **3DGS Render** Blender addon is **Apache 2.0, free**, and **Eevee-only**; its animation feature is explicitly *"still experimental, and performance isn't great yet."* No headless/CLI operation is documented for it.

### 3.3 The failure modes nobody budgets for

1. **You have no scene.** Blender renders a scene someone authored. Photos are not a scene. You'd still need §2 to produce geometry, and then a camera path, lighting, and materials — the expensive human part.
2. **Cold starts and image size.** A Blender + CUDA + addon container is multi-GB. On serverless GPU, cold start is a real per-job tax at Rendprop's likely low, bursty volume.
3. **Non-determinism at the tail.** Denoiser artifacts, fireflies, and out-of-VRAM on a heavy splat scene fail *late* — after you've paid for 800 frames.
4. **Splat rendering in Blender is second-class.** Eevee-only, experimental animation, addon-dependent. You'd be on the least-supported path of a tool chosen for a different job.
5. **Per-frame billing punishes retries.** One bad camera path = a full re-render at full cost. Compare to a video model, where a bad take costs $1.

### 3.4 What to do instead

**For a flythrough of a splat, you do not need Blender at all.** [Spark](https://github.com/sparkjsdev/spark) is World Labs' **MIT-licensed** (v2.1.0) Gaussian-splat renderer for THREE.js. It loads `.PLY`, `.SPZ`, `.SPLAT`, `.KSPLAT`, `.SOG`, and the streaming `.RAD` format, and Spark 2.0's LoD system keeps **500K–2.5M splats at a steady high frame rate on smartphones**, including Quest and Vision Pro. ([Spark 2.0](https://www.worldlabs.ai/blog/spark-2.0))

Two consequences:

- **You can render the flythrough live in the browser** — no render step, no render cost, and the user can *steer*. This maps directly onto the scroll-scrub player you already ship.
- If you ever *do* need an mp4, drive Spark in a headless browser on a small GPU and capture frames at roughly real time. ~2 min of L4 at $0.000222/s ≈ **$0.03**. Four orders of magnitude below Cycles.

**And for "polished promo video," you already have the better answer wired.** Current fal pricing:

| Model | Price | 30 s clip |
|---|---|---|
| `fal-ai/veo3.1/lite/image-to-video` | **$0.03/s** 720p no audio ($0.05 with audio) | **$0.90** |
| `fal-ai/bytedance/seedance/v1/pro/fast/image-to-video` (wired) | ~$0.243 / 5 s 1080p | **$1.46** |
| `bytedance/seedance-2.0/mini/image-to-video` | $0.0721/s 480p · $0.1547/s 720p | $2.16 / $4.64 |
| `fal-ai/kling-video/v3/turbo/standard/image-to-video` | $0.112/s | $3.36 |
| `topaz/upscale/video/precision` (Proteus) | $0.20 per 10 s @1080p | $0.60 |

A polished 30-second promo costs **$1–$5** from a video model. Blender-Cycles costs **$270–$720** plus scene authoring. There is no version of this comparison where Blender wins for a per-listing product.

> **Side finding — check this:** fal appears to have restructured the Topaz video endpoints. `providers/fal_client.py` calls `fal-ai/topaz/upscale/video` with `model: "Proteus"`; the catalogue now lists `topaz/upscale/video/precision` (Proteus among its models) at **$0.20 per 10 s @1080p = $0.02/s**, which matches the repo's `drone_render_1080p60_per_s` assumption only after the 60 fps doubling. Worth a live smoke test that the old path still resolves.

---

## 4. The legal question — do not build the Zillow ingestion

This section is deliberately blunt. The rest of the brief is a build plan; this part is a stop sign.

### 4.1 Zillow's Terms of Use ban it in terms

**§5, Prohibited Use** — you may not *"conduct automated queries (including screen and database scraping, spiders, robots, crawlers, bypassing 'captcha' or similar precautions, or any other automated activity with the purpose of obtaining information from the Services) on the Services."*

**§4(C), Use of Content** — you may copy information *"without the aid of any automated processes and only as necessary for your personal use or Pro Use to view, save, print, fax and/or e-mail such information."*

**§5** also bars *"create derivative works from... any portion of the Services."* ([Zillow ToU](https://www.zillow.com/corporate/terms-of-use/))

A feature that fetches a listing URL and pulls its photos is squarely the prohibited conduct, and a 3D reconstruction built from those photos is squarely a derivative work. (Note: the ToU contains **no** explicit AI/ML-training clause — that absence does not help, because the scraping and derivative-works clauses already cover it.)

### 4.2 There is no licensed back door

Zillow's official developer feed via Bridge offers **Public Records, Zestimates, and Econ Data**. **Listing photos and media are not among them.** Access is application-reviewed, capped at ~1,000 calls/day/dataset, and the terms bar local storage — *"You may use the API only to retrieve and display dynamic content"* — plus require attribution links back to Zillow. ([Bridge Interactive](https://www.bridgeinteractive.com/developers/zillow-group-data/))

**So: there is no compliant path to Zillow listing media at any price.** Not scraped, not licensed. That closes the question.

### 4.3 Who owns the photographs — not the agent, and not Zillow

Default rule, per NAR: **the photographer owns the copyright**, automatically, from the moment of creation, even after delivering to a broker or MLS. A listing broker owns it only if they or an employee shot it; otherwise they hold a **licence**. The MLS gets only what it negotiated. NAR's guidance to MLSs is that participants must represent *"the Participant has the right to authorize and is authorizing the MLS to publish the photograph."* ([NAR](https://www.nar.realtor/ae/manage-your-association/association-policy/copyright-considerations-for-mls-photographs))

And the licences are narrow: *"Paying a photographer for their services gives you a license to use the images. It does not transfer ownership."* Standard licences typically **expire at closing**; reusing a prior agent's photos on a relisting is infringement because you were never party to that agreement. ([NJ Broker Desk](https://www.njbrokerdesk.com/real-estate-photo-copyright-rules/))

The chain therefore is: **photographer → (narrow, listing-scoped, often term-limited licence) → listing broker → (publication permission) → MLS → (display permission) → portal.** A third-party app ingesting those images and producing a derivative 3D asset is outside every link of that chain.

### 4.4 VHT v. Zillow — what was actually held

Zillow ran photos it received through the MLS feed. The Ninth Circuit found no liability on the Listing Platform, **but** held that Zillow's use on **Digs** — adding searchable functionality — **was not fair use**.

The expensive part was the damages theory. Zillow argued the 2,700 infringed photos were one compilation because VHT stored them in a database. **The court rejected that**: the infringed works *"were not the database but instead were the 2,700 individual photographs."* Because VHT *"licensed the individual photos and not the compilation itself"* and each photo *"had independent economic value separate from the database,"* each photo earned its **own statutory award**.

Final judgment on remand: **$800/image × 2,312 images + $200/image × 388 innocently-infringed images = $1,927,200.** ([Ninth Circuit, 2023](https://law.justia.com/cases/federal/appellate-courts/ca9/22-35147/22-35147-2023-06-07.html), [Loeb & Loeb](https://www.loeb.com/en/insights/publications/2023/06/vht-inc-v-zillow-group-inc-et-al))

**Read this as the pricing sheet for the feature.** A single listing carries 30–50 photos. At $800/image that is **$24,000–$40,000 of exposure per listing**, per photographer, multiplied by every listing ingested. It also establishes that **repurposing listing photos into a new interactive product is the fact pattern courts already found not to be fair use.** Zillow — with vastly better counsel and an actual MLS feed licence — lost this. Rendprop would be in a materially worse position with no licence at all.

### 4.5 AB 723 and MLS AI rules applied to a generated 3D walkthrough

**AB 723** is now **Bus. & Prof. Code § 10140.8** (Ch. 497, signed 10 Oct 2025, **effective 1 Jan 2026**). Operative text:

> (a)(1) A real estate broker or salesperson, or person acting on their behalf, who includes a digitally altered image in an advertisement or other promotional material for the sale of real property **shall include... a statement disclosing that the image has been altered and a link to a publicly accessible internet website, URL, or QR code that includes, and clearly identifies, the original, unaltered image.** The statement shall be **reasonably conspicuous and located on or adjacent to the image**...
>
> (a)(2) If [the material] is posted on an internet website over which [they] have control, **they shall include the unaltered version of the images** from which the digitally altered images were created in the posting.
>
> (b)(1) "digitally altered image" means an image... **altered through the use of photo editing software or artificial intelligence to add, remove, or change elements in the image, including, but not limited to, fixtures, furniture, appliances, flooring, walls, paint color, hardscape, landscape, facade, floor plans, and elements outside of, or visible from, the property**...
>
> (b)(2) does **not** include lighting, sharpening, white balance, colour correction, angle, straightening, cropping, exposure, or other common adjustments that **do not change the representation of the real property**.

**How it applies here.** The statute says **"image,"** not "video" or "tour" — so a literal reading leaves generated video in a grey zone. **Do not rely on that grey zone**, for four reasons:

1. **"floor plans" is enumerated in (b)(1).** An AI-generated spatial representation of the property is expressly the kind of thing the legislature had in mind.
2. A splat walkthrough **is** rendered images, and each frame showing model-invented geometry is an image where AI "changed elements... including walls."
3. Per §2.3(c), Marble **explicitly invents unseen geometry** and warns it *"won't match a real floor plan of those hidden areas."* A generated hallway wall is not a "common photo editing adjustment."
4. The compliance posture Rendprop already chose (per `docs/research/COMPLIANCE-WEDGE-SPEC.md`) is disclose-everything-anyway. Keep it. The whole moat is that you over-disclose while competitors don't.

**NorthstarMLS** (guidance published **10 Jul 2026**) is the harder constraint and it is not ambiguous:
- Every virtually staged / AI-generated / AI-enhanced image must be identified **in the caption or filename visible in the listing viewer, or on the image itself**.
- **Every altered room needs at least one unaltered "before" photograph** in the listing.
- **Prohibited outright:** alterations that *"change or hide permanent or structural elements"* — walls, flooring, windows, doors, roofing, siding, ceilings, fireplaces, driveways, site grading — and fabricating features that don't exist. ([NorthstarMLS](https://northstarmls.com/insights/guidelines-for-virtual-staging-and-ai-enhanced-listing-photos/))

**This last bullet is the design constraint for the whole feature.** A splat that invents a wall behind a closed door is generating a structural element that doesn't exist as depicted. Three mitigations, all required:

- **Maximise coverage so the model imagines less** ("the more it sees, the less it imagines"). Dense walkthrough video beats sparse photos. This is Rendprop's structural advantage.
- **Constrain the camera path to seen space.** Don't let the flythrough fly through invented geometry. You have RoomPlan geometry to bound it — and Marble's `metric_scale_factor` / `ground_plane_offset` to align the two frames.
- **Disclose per-asset, with the source clip as the "original."** The existing `media_provenance` table and `/u/` disclosure block already model this; a splat is a new `kind` ('splat' or 'walkthrough_3d') with the source video as `original_key`.

**Two corrections to flag on existing internal docs:**
- `COMPLIANCE-WEDGE-SPEC.md` states AB 723 carries *"up to $2,500 per violation."* **I could not verify that figure.** § 10140.8 as enacted **contains no dollar amount**. It sits inside the Real Estate Law, where a willful violation is a misdemeanour and the practical enforcement is **DRE discipline plus MLS sanction**, with derivative exposure under California consumer-protection/advertising law. One practitioner note observes AB 723 *"itself sets no retention period"* either, though most CA MLSs require keeping unaltered originals ~5 years. **Recommend removing the $2,500 figure or sourcing it before it appears in any customer-facing claim.**
- AB 723's operative requirement is **stronger than a caption**: on a site you control, you must **include the unaltered version in the posting**, not merely link it. Confirm `/f/` and `/u/` do that, not just the "View original" link.

### 4.6 The safe version, and what it changes technically

**The safe version is the listing agent's own capture of their own listing, with the brokerage's authority.** That eliminates the Zillow ToU issue, the photographer-copyright issue, and the VHT exposure in one move. It is also, conveniently, the only version that produces a good result.

What changes technically — and it is significant:

| | Zillow-photo version | Agent-capture version |
|---|---|---|
| Input | 30–50 unposed marketing stills, wide-angle, staged, chosen for beauty not coverage | Continuous walkthrough video, dense, sequential, overlapping |
| Coverage | Sparse, deliberately non-overlapping (agents don't shoot redundant angles) | Near-continuous — the model imagines far less |
| Fidelity | Model invents most of the space between shots | Genuine reconstruction where the camera went |
| Marble input mode | Multi-image, capped at **8 images** — you can't even use 40 | **Video** (≤30 s per world) — matches the capture |
| Legal | Prohibited | Clean |
| Rendprop already has it? | No | **Yes** |

**New capture requirements to teach the agent** (drawn directly from World Labs' video guidance):
- **One continuous take per room**, no cuts.
- **Rotate to cover 180°–360°** of the space.
- **Lock focal length and exposure** — no zoom, no auto-exposure hunting. (Check what the iOS capture path currently does; AVFoundation auto-exposure drift will degrade every reconstruction.)
- **Steady, slow motion** — motion blur becomes smeared geometry.
- **Static scene** — no people or pets moving through.
- **≤30 s per room segment.**

Four of those six are already implicit in a good scroll-scrub capture. The exposure/focal lock is probably a genuine code change.

---

## 5. Recommendation

### Ranking: value to a listing agent ÷ (build cost + per-job cost + legal risk)

---

#### **#1 — "Step inside": per-room Gaussian splat from the existing walkthrough, rendered live in the player**

**Value: high · Build: moderate · Per-job: ~$1.28/room · Legal risk: low (with disclosure)**

The agent shoots the walkthrough they already shoot. Each **room chapter** becomes one Marble world. The player gains a "step inside this room" affordance: tap a chapter, the splat loads, and the same scroll gesture that scrubs the video now flies the camera through the room. Video for the tour narrative; splat for the rooms buyers want to linger in.

**Why this wins:**
- **The input already exists and is the best input available.** A continuous walkthrough is a dense multi-view capture — exactly what splatting wants, and strictly better than Zillow's stills.
- **The chapter model already exists.** `player.ts` carries `tour.chapters` with per-room labels and seek. Chapter boundaries map 1:1 onto Marble's ≤30 s video limit. This is not a new data model; it's a new field on an existing one.
- **No render step.** Spark is MIT and runs on phones. The cost of the "video" is zero because there is no video.
- **No hallucinated whole-house floor plan.** You never claim the house is one connected 3D model, so you never depend on Compose, and you never assert geometry you didn't capture. RoomPlan remains the authority on layout — which is also the asset buyers rate highest.
- **It degrades gracefully.** If a room's splat is poor, ship that chapter as video only. No all-or-nothing failure.

**Exact API — the request shape**

*Per room chapter, extract a ≤30 s / ≤100 MB clip from the walkthrough at the chapter boundaries.*

1 — Prepare upload:
```
POST https://api.worldlabs.ai/marble/v1/media-assets:prepare_upload
WLT-Api-Key: $WLT_API_KEY
Content-Type: application/json

{ "file_name": "living-room.mp4", "extension": "mp4", "kind": "video" }
```
Returns `media_asset.media_asset_id` and `upload_info.upload_url` + `required_headers`.

2 — Upload the clip:
```
PUT <upload_url>
Content-Type: video/mp4
<required_headers>
--upload-file living-room.mp4
```

3 — Generate the world:
```
POST https://api.worldlabs.ai/marble/v1/worlds:generate
WLT-Api-Key: $WLT_API_KEY
Content-Type: application/json

{
  "model": "marble-1.1",
  "display_name": "123 Main St — Living Room",
  "permission": { "public": false },
  "world_prompt": {
    "type": "video",
    "video_prompt": { "source": "media_asset", "media_asset_id": "<id>" }
  }
}
```
Returns `operation_id`. **Serialise the JSON with a real JSON library** — the single most common cause of a `400` is a stringified map, and the error body does not tell you why.

4 — Poll:
```
GET https://api.worldlabs.ai/marble/v1/operations/{operation_id}
```
`done: true` → `response` carries the World, including `semantics_metadata` (`metric_scale_factor`, `ground_plane_offset`) for metric alignment against RoomPlan. `cost` carries the settled credit charge — **write that into `cost_ledger`, don't estimate it**.

5 — Export the splat (free):
```
POST https://api.worldlabs.ai/marble/v1/worlds/<world_id>:export
{ "asset_type": "splats", "format": "ply", "resolution": "full_res" }
```
Prefer **SPZ** for delivery (Niantic's compressed format, ~5–10× smaller than PLY). Ship **500K splats to mobile, 2M to desktop** — Spark's LoD handles the switch.

**Price per job**

| Item | Unit | 8-room house |
|---|---|---|
| `marble-1.1` from video | **$1.28**/room (1,600 cr @ $1/1,250 cr) | **$10.24** |
| `marble-1.0-draft` (preview tier) | **$0.20**/room (250 cr) | **$1.60** |
| Splat export (SPZ/PLY) | **$0.00** | $0.00 |
| Storage/CDN | existing R2 | negligible |

`marble-1.1-plus` is $1.20–$2.40/room depending on world size. **HQ mesh export is $2.80 and up to an hour — skip it entirely**; you want splats, and RoomPlan already gives you the metric floor plan.

**Note against the budget gate:** `MAX_GEN_COST_PER_JOB_CENTS` is **2500** ($25). An 8-room `marble-1.1` pass at $10.24 consumes **41% of the per-job ceiling** on its own, before declutter/restage/hero. Either add splats as a separately-capped feature, raise the ceiling for tours that opt in, or route the standard tier through `marble-1.0-draft` at $1.60 and reserve `marble-1.1` for a paid upgrade. **Decide this before wiring, not after.**

**Expected latency**
- ~**5 minutes per world** (World Labs' own figure).
- Rate limit **~3 starts/min, 60/hr** default; approved accounts get 30/min standard, 90/min draft.
- 8 rooms: ~3 min to submit under the default start-rate, ~5 min for the last to finish → **~8–10 min wall clock**, fully async. Fits the existing job state machine; it does not fit a synchronous request.
- Request higher throughput from World Labs **before** launch — the 60/hr default caps you at ~7 houses/hour.

**Build checklist**
1. `provider/worldlabs.py` in `services/pipeline/providers/` — same shape as `fal_client.py` (submit → poll → download), plus the prepare-upload/PUT step.
2. `costs.py`: `splat_marble_11_per_room = 128.0`, `splat_marble_draft_per_room = 20.0`. **Reconcile against the `cost` field the operation returns** rather than trusting the estimate.
3. Router: new `splat()` path behind the budget gate; per-room, so `BudgetExceeded` degrades that room to video-only instead of failing the tour.
4. Per-chapter clip extraction (ffmpeg, ≤30 s, ≤100 MB) in the render pipeline.
5. Player: Spark + a splat viewer bound to the existing scroll/seek logic. Gate on WebGL2 capability; **always** fall back to the video chapter.
6. `media_provenance`: new `kind` for the splat, `original_key` = the source clip, disclosure line naming AI 3D reconstruction. Show it in the `/f/` and `/u/` disclosure blocks.
7. Camera path constrained to captured space (bound by RoomPlan extents via `metric_scale_factor`), so the flythrough never enters invented geometry.
8. Capture guidance in-app: continuous take, rotate wide, **lock exposure and focal length**, keep the room still.

**Test it cheaply first.** Shoot one room, run it through `marble-1.0-draft` for **$0.20**, and look at the splat before writing any of the above. A $5 credit purchase buys ~25 draft worlds — enough to answer "does this look good enough to put in front of a seller" in an afternoon.

---

#### **#2 — Splat-derived hero clip (a flythrough as an mp4)**

**Value: medium-high · Build: moderate-high · Per-job: ~$1.30/room + ~$0.03 render · Legal risk: low-medium**

Same splats as #1, but instead of interactive delivery, render a scripted camera path to mp4 in a headless browser with Spark and stitch a promo reel. Closest to what the owner actually pictured.

**Why it's second, not first:** it is #1 plus a render harness plus camera-path authoring, and the marginal value over the existing Seedance/Topaz hero clip is unproven. It also *increases* compliance surface — a polished cinematic implies more veracity than an explorable splat where the buyer can see the edges of what was captured. **Build it only after #1 shows real agent pull.** When you do, headless Spark (~$0.03/clip) not Blender (~$300/clip).

---

#### **#3 — Exterior splat from a phone orbit ("SkyTour without the drone")**

**Value: medium · Build: low · Per-job: ~$1.28 · Legal risk: low**

One extra 30-second capture: the agent walks the front of the house. One Marble world. Delivered as a hero element on the tour page.

**Why it's viable:** exteriors are the easiest splat case — open space, no occlusion, even lighting — which is exactly why **Zillow shipped SkyTour on exteriors first**. It is one API call, one clip, no chaptering, no player integration beyond a single viewer. **It is the cheapest possible proof of the whole thesis** and could ship in days.

**Why it's third:** it's a nice-to-have next to an interior walkthrough, and it is the thing Zillow gives Showcase sellers for free.

---

### Explicitly not recommended

| | Why |
|---|---|
| **Ingesting Zillow/MLS listing photos** | §4. Prohibited by ToU, third-party copyright, no licensed feed carries photos, and VHT priced the exact fact pattern at $1.9M. There is no version of this worth building. |
| **Whole-house connected 3D model** | No API for room joining; Compose is a GUI tool; *"There is no floor plan input that auto-connects rooms."* RoomPlan already gives you the layout, and buyers rate floor plans higher than tours anyway. |
| **Blender Cycles per listing** | $270–$720/clip of GPU before anyone authors a scene. |
| **Object generators (Tripo/Hunyuan3D/Trellis/Meshy) for the property** | Wrong category — furniture-scale asset generators. They'd produce a plausible-looking house that is not this house. |
| **Anything depending on OpenAI video** | API removed 24 Sep 2026, no replacement. |
| **Genie 3 / Project Genie** | No API. Ultra consumer subscription, US-only, 60 s worlds. |
| **World Labs Atlas** | Early access, select partners, no published pricing. Track it; don't plan on it. |

---

## Flagged: what I could not verify

- **Zillow SkyTour's vendor.** Not public. In-house is the informed guess, not a fact.
- **`tripo3d/triposplat` and `fal-ai/hunyuan_world/image-to-world` pricing.** Neither carries a published per-generation price on fal's catalogue; HunyuanWorld's output format is undocumented. Both need a live test to price.
- **World API latency at Rendprop's shape of input.** "~5 minutes" is World Labs' stated figure. I have not run a real 30 s room clip through it. **Measure before quoting an SLA.**
- **Actual splat quality on a typical agent phone walkthrough.** Everything in §5 assumes the reconstruction looks good. It might not — handheld, auto-exposure, mixed lighting, tight interiors are the hard case. **This is the single largest unknown and the reason to spend $5 on drafts before spending a sprint.**
- **The "$2,500 per violation" AB 723 figure** in `COMPLIANCE-WEDGE-SPEC.md`. § 10140.8 as enacted contains no dollar amount. Source it or drop it.
- **Whether AB 723 reaches video/3D.** The statute says "image" and enumerates "floor plans"; no case law or DRE guidance yet interprets it for generated walkthroughs. Recommendation is to over-disclose regardless.
- **Niantic Spatial's REST surface.** The published SDK is Unity/Swift/Kotlin AR tooling; I found no documented "POST a video, get a splat" endpoint. Pricing (30 credits/sec of mobile capture; commercial rights only on Pro/Enterprise) is confirmed; API-ness is not.
- **fal's Topaz endpoint rename.** The catalogue now shows `topaz/upscale/video/precision`; the repo calls `fal-ai/topaz/upscale/video`. Smoke-test the existing path.
- **Apple RoomPlan's roadmap.** No public signal either way. Treat as stable-but-static.

---

## Sources

**Astra / OpenAI / Google**
- [What is Project Astra? — Android Central](https://www.androidcentral.com/apps-software/ai/project-astra)
- [OpenAI API deprecations](https://developers.openai.com/api/docs/deprecations)
- [Sora (text-to-video model) — Wikipedia](https://en.wikipedia.org/wiki/Sora_(text-to-video_model))
- [Sora API: Pricing, Specs, and the September 24 Shutdown — Unifically](https://unifically.com/blogs/sora-api)
- [Gemini API pricing](https://ai.google.dev/gemini-api/docs/pricing)
- [Project Genie — Google blog](https://blog.google/innovation-and-ai/models-and-research/google-deepmind/project-genie/)
- [Genie 3 — Google DeepMind](https://deepmind.google/blog/genie-3-a-new-frontier-for-world-models/)

**3D / splatting**
- [World API pricing](https://docs.worldlabs.ai/api/pricing.md) · [models](https://docs.worldlabs.ai/api/models.md) · [rate limits](https://docs.worldlabs.ai/api/rate-limits.md) · [FAQ](https://docs.worldlabs.ai/api/faq.md) · [generate](https://docs.worldlabs.ai/api/reference/worlds/generate.md) · [prepare upload](https://docs.worldlabs.ai/api/reference/media-assets/prepare-upload.md) · [operations](https://docs.worldlabs.ai/api/reference/operations/get.md)
- [Marble multi-image guide](https://docs.worldlabs.ai/marble/create/prompt-guides/multi-image-prompt.md) · [video guide](https://docs.worldlabs.ai/marble/create/prompt-guides/video-prompt.md) · [prompt guidelines](https://docs.worldlabs.ai/marble/create/prompt-guides/index.md) · [export specs](https://docs.worldlabs.ai/marble/export/specs.md) · [Compose](https://docs.worldlabs.ai/marble/create/studio-tools/compose.md) · [Record](https://docs.worldlabs.ai/marble/create/studio-tools/record.md)
- [Announcing the World API — World Labs](https://www.worldlabs.ai/blog/announcing-the-world-api)
- [Atlas: A World Model for Spatial Intelligence — World Labs](https://www.worldlabs.ai/blog/atlas)
- [Streaming 3DGS worlds on the web (Spark 2.0) — World Labs](https://www.worldlabs.ai/blog/spark-2.0) · [Spark on GitHub (MIT)](https://github.com/sparkjsdev/spark)
- [World Labs platform overview — Radiance Fields](https://radiancefields.com/platforms/world-labs)
- [Scaniverse — Radiance Fields](https://radiancefields.com/platforms/scaniverse)
- [Niantic Spatial pricing](https://www.nianticspatial.com/pricing) · [Niantic Spatial SDK docs](https://www.nianticspatial.com/docs/nsdk/)
- [Zillow SkyTour + Gaussian splatting — Radiance Fields](https://radiancefields.com/zillow-adds-gaussian-splatting-support-with-skytour-unveiling) · [Zillow SkyTour announcement](https://www.zillow.com/news/take-home-listings-to-new-heights-with-skytour/)
- [Gaussian splatting services guide 2026 — Utsubo](https://www.utsubo.com/blog/gaussian-splatting-guide)
- [Luma official LLM info](https://lumalabs.ai/llm-info)
- [Photo-to-3D for architects/interior designers — Visiomake](https://visiomake.com/en/blog/photo-to-3d-model-ai-architects-interior-designers-trellis-hunyuan)

**Apple on-device**
- [PhotogrammetrySession — Apple Developer](https://developer.apple.com/documentation/realitykit/photogrammetrysession)
- [Creating 3D objects from photographs — Apple Developer](https://developer.apple.com/documentation/realitykit/creating-3d-objects-from-photographs)
- [Photogrammetry requiring lidar-capable phones — Apple Developer Forums](https://developer.apple.com/forums/thread/775564)
- [WWDC no mention of RoomPlan — Apple Developer Forums](https://developer.apple.com/forums/thread/787628)

**Blender / GPU**
- [Blender cloud rendering guide — SuperRenders](https://superrendersfarm.com/article/blender-cloud-rendering-guide) · [Eevee vs Cycles on a cloud farm](https://superrendersfarm.com/article/eevee-vs-cycles-cloud-render-farm-comparison-2026)
- [Modal pricing](https://modal.com/pricing) · [RunPod pricing](https://www.runpod.io/pricing)
- [3DGS Render 5.0 for Blender — CG Channel](https://www.cgchannel.com/2026/06/3dgs-render-5-0-lets-you-animate-gaussian-splats-inside-blender/) · [KIRI 3DGS Render (GitHub)](https://github.com/Kiri-Innovation/3dgs-render-blender-addon)

**Legal**
- [Zillow Terms of Use](https://www.zillow.com/corporate/terms-of-use/)
- [Zillow Group Data — Bridge Interactive](https://www.bridgeinteractive.com/developers/zillow-group-data/)
- [VHT, Inc. v. Zillow Group, No. 22-35147 (9th Cir. 2023) — Justia](https://law.justia.com/cases/federal/appellate-courts/ca9/22-35147/22-35147-2023-06-07.html) · [Loeb & Loeb analysis](https://www.loeb.com/en/insights/publications/2023/06/vht-inc-v-zillow-group-inc-et-al) · [Wilson Sonsini analysis](https://www.wsgr.com/en/insights/ninth-circuit-issues-important-mixed-decision-in-zillow-copyright-infringement-case.html)
- [Copyright Considerations for MLS Photographs — NAR](https://www.nar.realtor/ae/manage-your-association/association-policy/copyright-considerations-for-mls-photographs)
- [Real Estate Photo Copyright Rules 2026 — NJ Broker Desk](https://www.njbrokerdesk.com/real-estate-photo-copyright-rules/)
- [AB-723 bill text (Bus. & Prof. Code § 10140.8)](https://leginfo.legislature.ca.gov/faces/billNavClient.xhtml?bill_id=202520260AB723)
- [AB 723 practical guide — Pasadena-Foothills REALTORS](https://pfar.org/californias-new-altered-image-law-ab-723-what-real-estate-pros-need-to-know-starting-january-1st-2026/) · [SEAREI AB 723 compliance](https://searei.com/ab723)
- [Guidelines for Virtual Staging and AI-Enhanced Listing Photos — NorthstarMLS](https://northstarmls.com/insights/guidelines-for-virtual-staging-and-ai-enhanced-listing-photos/)

**fal pricing** — read live from `https://fal.ai/api/models` on 2026-09-04 (Veo 3.1 Lite, Seedance 1.0/2.0, Kling v3, Topaz video, Hunyuan3D Pro, Trellis 2, TripoSplat, HunyuanWorld) · [Tripo API pricing](https://developers.tripo3d.ai/en/pricing) · [fal 3D models](https://fal.ai/3d-models)
