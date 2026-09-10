# Spatial tour: actual deployed state and required product completion

Read-only inventory checked 2026-09-10, approximately 18:50 Eastern. This is an
implementation gap, not a request for the owner to operate a development tool.
The required customer journey is **capture → processing → private 3D preview →
review → publish**, inside the app. Exporting a folder is not that journey.

## Independently observed

- The connected RendProp Supabase project reports ACTIVE_HEALTHY. Its complete
  function inventory has 21 active functions: listings, uploads, renders, me,
  ai-enhance, tours, leads, beacon, portfolio, ai-photo, ai-video, admin, ai-voice,
  ai-chapters, events, apple-subscriptions, coach, ai-copy, property, adopt, team.
  There is no spatial function in that inventory. Listing functions does not
  attest their deployed source matches this checkout, or prove an existing
  function cannot proxy another service; no such spatial proxy was found in
  the repository's service implementation search either.
- Connected Cloudflare account lists `rendprop-tour-host`, last modified
  2026-09-08T19:31:06Z. Its Containers application inventory and Queues inventory
  are empty. Other unrelated Workers were not inspected. This does not inventory
  unconnected AWS/Modal/RunPod/GCP accounts or prove no other host exists.
- Build18's visible screen explicitly states that it saves local room photos
  and poses and generates no upload/model. The owner's successful capture
  confirms that stage worked on their iPhone; it does not prove reconstruction.
- The provided capture has passed the local adapter: 256 images, 57,894 feature
  observations, 14,654 usable initialization seeds. A private training dataset
  exists. Original files were not modified or committed; no room imagery was
  uploaded. No trained real-room PLY/SOG exists yet.
- The repository does contain an enabled `3d.world` / `marble-1.1` route seed
  (`services/supabase/migrations/0018_ai_routes.sql:455–459`). That is not a
  implemented spatial backend: the seed notes the missing adapter;
  `functions/admin/index.ts:493–509` describes a CLI bridge rather than app
  wiring, and `functions/admin/probe.ts:509–528` is a credits probe. Do not
  confuse a provider row or a successful credits check with reconstruction.

The inventory calls were read-only. No service was created, enabled, deployed,
charged or deleted. No Apple submission/TestFlight change occurred.

## What to implement after the real-room proof

The standing brief's exact order is in `docs/GPT-AGENT-BRIEF.md:392`: first prove
one captured room trains and is navigable in a browser; PhaseB follows owner
review. The manual transfer in that experiment is an engineering validation,
**not** the eventual customer workflow. The owner clarified that the deliverable
must be the live deployed app, not a local utility.

1. **Private scan upload:** app uploads a resumable room package through existing
   identity/storage boundaries, preserving session/calibration/image bindings.
   Never send the camera roll, unrelated files or raw logs. Existing upload
   completion fencing must be repaired before reusing it as immutable input.
2. **Durable reconstruction job:** database records capture revision, owner/org,
   immutable dataset hash, attempt token, state, deadline, reserved budget,
   progress, output artifacts and failure classification. Retries must not
   duplicate spend or let stale attempts publish. Existing video-worker
   publication is not a safe copy-and-paste template; see WH-03.
3. **Actual GPU executor:** a deployed compute service fetches only that private
   dataset, validates it, runs the pinned posed-image trainer, converts output
   to the viewer format, and reports hash-bound artifacts. An edge function
   enqueues/polls; it does not synchronously hold a multi-minute optimization.
   Provider selection, customer-media handling and a real cost/shutdown ceiling
   need an explicit deployment choice; none has been inferred from credentials.
4. **In-app status/recovery:** show queued/processing/retryable failure/ready;
   reopening the app resumes the job, not a fresh charge. Preserve partial
   captures and completed scans. A retry button requires a server idempotency
   contract, not a new unbound request. Ready must mean validated output exists.
5. **Navigable private viewer:** same web renderer inside iOS and the browser;
   actual touch navigation, loading/error states, device capability/quality
   fallback and memory limits. Validate the real room, not a synthetic sphere.
   A point initialization cloud is not a reconstructed surface or finished tour.
6. **Review and publication:** exclude rooms and redact private content before
   public access. Keep reconstructed revisions immutable; publication points
   to an approved revision. Chapter spatial anchors remain optional so adding
   a scan to an existing flythrough does not re-render that video.

Acceptance is one owner capture completing this entire flow on the iPhone15Pro,
plus supported-device fallback, interrupted upload/job recovery, tenant isolation,
duplicate-request and stale-worker tests, removal/revocation and bounded spend.
The measured evidence must include frames, GPU/time/cost, artifact bytes/hash and
physical-phone frame rate. Simulator camera attempts do not establish any of it.

## Current executable handoff

See `docs/spatial-spike/LOCAL-CAPTURE-TO-VIEWER-20260910.md` for the exact existing
adapter, pinned trainer, conversion and private viewer commands, including what
has actually run. The capture wrapper was independently reviewed and repaired
before integration. This note does not claim the job service, GPU deployment,
in-app processing flow or public spatial tours have been built.
