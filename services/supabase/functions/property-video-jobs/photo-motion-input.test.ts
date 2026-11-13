import { assertEquals, assertRejects } from 'https://deno.land/std@0.224.0/assert/mod.ts';
import { PHOTO_MOTION_MODE, PHOTO_MOTION_PROFILE_V2, photoMotionTimeline } from '../_shared/photo-motion.ts';
import { AERIAL_OPENING_PROFILE } from '../_shared/aerial-opening-contract.ts';
import { jobInput } from './input.ts';

const id = (n: number) => `f3000000-0000-4000-8000-${String(n).padStart(12, '0')}`;
const sources = [
  { photo_id: 'entrance', photo_asset_id: id(4), photo_version_id: `asset:${id(4)}`, photo_provenance_id: null, motion: 'push_in', visible_frames: 48, source_sha256: 'a'.repeat(64), source_bytes: 4096 },
  { photo_id: 'living', photo_asset_id: id(5), photo_version_id: `asset:${id(5)}`, photo_provenance_id: null, motion: 'slide_left', visible_frames: 72, source_sha256: 'b'.repeat(64), source_bytes: 4096 },
  { photo_id: 'kitchen', photo_asset_id: id(6), photo_version_id: `asset:${id(6)}`, photo_provenance_id: null, motion: 'pull_back', visible_frames: 72, source_sha256: 'c'.repeat(64), source_bytes: 4096 },
];
const request = () => ({ source_mode: PHOTO_MOTION_MODE, composition_profile: PHOTO_MOTION_PROFILE_V2, operation_id: id(1), listing_id: id(2), expected_org_id: id(3), purpose: 'listing', aspect: '16:9', sources: sources.map(s => ({ ...s })), allow_original_photo_fallback: false });

Deno.test('explicit photo motion keeps 2/3/3-second source timing and chosen directions', () => {
  const manifest = jobInput(request());
  assertEquals(manifest.sources.map(s => s.motion), ['push_in', 'slide_left', 'pull_back']);
  assertEquals(manifest.sources.map(s => s.visible_frames), [48, 72, 72]);
  assertEquals(manifest.allow_original_photo_fallback, false);
  assertEquals(photoMotionTimeline({ manifest, quality_profile: PHOTO_MOTION_PROFILE_V2 }), { source_frames: [48, 72, 72], total_frames: 192, fps: 24, source_motions: ['push_in', 'slide_left', 'pull_back'] });
});

Deno.test('explicit photo motion refuses an AI-motion override and fallback', async () => {
  await assertRejects(async () => jobInput({ ...request(), motion_override: 'push_in' }));
  await assertRejects(async () => jobInput({ ...request(), allow_original_photo_fallback: true }));
});

Deno.test('explicit photo motion refuses altered source timing or master identity', async () => {
  for (const change of [{ visible_frames: 47 }, { source_sha256: '0' }, { source_bytes: 0 }, { photo_version_id: `asset:${id(99)}` }]) {
    const value = request();
    value.sources[0] = { ...value.sources[0], ...change };
    await assertRejects(async () => jobInput(value));
  }
});

Deno.test('aerial composition requires one exact accepted opening reference', async () => {
  await assertRejects(async () => jobInput({ ...request(), composition_profile: AERIAL_OPENING_PROFILE }));
});

Deno.test('saved photo motion quality profile must match its frozen manifest', async () => {
  const manifest = jobInput(request());
  await assertRejects(async () => photoMotionTimeline({ manifest, quality_profile: 'legacy' }));
});
