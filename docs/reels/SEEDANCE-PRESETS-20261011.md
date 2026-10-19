# Reel presets — version 1

Implementation: ai-video/motion.ts `buildSeedanceReelPreset`, requested with `preset_version: 1`. The model currently enabled for reels is FAL's **Seedance 1.0 Pro Fast image-to-video**. These are model-specific drafts with request and property-preservation tests, not a claim that generated output can never drift.

Four camera moves: Fly-through (default), Slow push-in, Side glide, Pull-back. Each photo makes one five-second shot. A fly-through is a short stabilized glide inside one photographed view; it does not reconstruct the property's connected layout or move into unseen rooms. Pull-back starts cropped and ends at the source framing, rather than extending the property's borders.

The app center-crops to the selected 9:16 or 16:9 format before submission, saves that exact reference in its scoped recovery record, and sends the chosen format to the model. Each resulting clip must pass the existing first/middle/last-frame drift judge before retention or composition. Failed or unavailable checks retain the accepted request and never automatically purchase another clip. A three-frame judge is a safeguard, not proof that every intervening frame is correct; the user must review the finished reel.

Prompts preserve architecture, geometry, permanent colors including garage doors and trim, furniture, landscaping, visible views and lighting. They request one restrained move with fixed lens, level horizon, stationary objects and no cuts, renovation, recoloring or invented surfaces. Free text no longer replaces the selected preset in this iPhone UI. Older clients retain their guarded prompt path, with the contradictory instruction to preserve camera perspective corrected to preserve property geometry.

Verified primary documentation (2026-10-11):

- [FAL Seedance 1.0 Pro Fast schema](https://fal.ai/models/fal-ai/bytedance/seedance/v1/pro/fast/image-to-video/api): one `image_url`, duration strings including 5, explicit aspect ratio, camera control; no `end_image_url` for this Fast endpoint.
- [BytePlus Seedance 1.0 / Pro Fast guide](https://docs.byteplus.com/en/docs/modelark/seedance-1-0-pro-pro-fast?redirect=1): grounded image-to-video and camera movement vocabulary.
- [FAL Hailuo 02 Standard schema](https://fal.ai/models/fal-ai/minimax/hailuo-02/standard/image-to-video/api): duration 6 or 10; prompt optimizer defaults on. Adapter now refuses a five-second request instead of secretly increasing duration and disables rewriting. This does not enable a lower-resolution fallback for 1080p reels.
- [FAL Veo 3.1 Fast I2V](https://fal.ai/models/fal-ai/veo3.1/fast/image-to-video/api): listed retirement October 22. It is an aerial fallback, not the active reel model. Replacement needs a separately priced and visually tested acceptance set before enabling; this change does not substitute a new paid model silently.

Remaining empirical acceptance: run the four moves on consenting interior/exterior fixtures, review all frames for geometry/color changes, and compare the actual provider receipts and costs. Offline tests and simulator checks cannot establish generative quality. Never describe prompts as “guaranteed” or claim a continuous whole-house route from unrelated still images.
