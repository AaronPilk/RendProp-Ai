// Runtime copy of property-video-kie-identity.json (the canonical file the
// disposable-Postgres proof compares with SQL property_video_quality_identity).
// A plain TS module keeps JSON-module imports out of every deployed function
// graph; property-video-kie_test.ts asserts this object equals the JSON file.
export const KIE_PROPERTY_IDENTITY_SOURCE = {
  "profile": "kie-kling3-4k-steady-v1",
  "provider": "kie",
  "model": "kling-3.0/video",
  "route_id": "7f2c9a3e-4b1d-4e8a-9c55-1d6e0b7a4f21",
  "task": "video.property_reel_clip_kie",
  "mode": "4K",
  "sound": false,
  "multi_shots": false,
  "seconds": 5,
  "unit": "second",
  "unit_cents": 33.5,
  "attempt_cents": 167.5,
  "credits_per_second": 67,
  "usd_per_credit": 0.005,
  "price_source": "https://kie.ai/kling-3-0",
  "price_checked": "2026-10-16",
  "bonus_credits_excluded": true,
  "max_paid_attempts_per_source": 2,
  "prompt_profile": "steady-property-v1",
  "prompt_template_token": "{scene_noun}",
  "prompt_scene_nouns": [
    "home",
    "event venue",
    "restaurant",
    "store",
    "fitness studio",
    "space"
  ],
  "prompt_template_sha256": {
    "fly_through": "5a27f080e3affd92fc1f455f09d29df3b9d82c3bb07de6a4fae644ddba95a785",
    "push_in": "275836a1c183898de223d1f576eba246ca4aa635611a0afd410743a264d472f7",
    "side_glide": "cad745c420ac54cd4339a73fde9ad33322949dbbb6764f596c2d1da24d0848a3",
    "pull_back": "e80e5a784366935080e5ab43d2e8ea395859a6993c6c146bfc96c86b138b8aa9"
  },
  "composition_profile": "steady-v2-cfr24",
  "output_fps": 24,
  "output_frames": [
    120,
    121
  ],
  "min_short_side_px": 2160,
  "min_pixels": 8000000,
  "aspect_ratio_wire": "omitted_source_auto",
  "privacy_tier": "trains_by_default",
  "content_license_ack": "kie-terms-2025-08-01-section-3-owner-accepted"
};
