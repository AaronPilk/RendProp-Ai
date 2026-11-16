import { assert, assertEquals, assertThrows } from 'https://deno.land/std@0.224.0/assert/mod.ts';
import {
  AERIAL_PROFILE, aerialGenerationModel, exteriorAssessment, mayGenerate,
  pollSavedAerial, submitAerialOnce, type AerialProvider, type AerialStageStore,
} from './aerial-admission.ts';
import { aerialReply } from './aerial-public.ts';

const id = (n: number) => `f3000000-0000-4000-8000-${String(n).padStart(12, '0')}`;
const sha = 'a'.repeat(64);
const manifest = {
  schema: 1 as const, profile: AERIAL_PROFILE, operation_id: id(1), listing_id: id(2),
  expected_org_id: id(3), source: { photo_asset_id: id(4), photo_version_id: `asset:${id(4)}`,
    photo_provenance_id: null, sha256: sha, bytes: 100_000 },
  role: 'front_of_home' as const, aspect: '16:9' as const, seconds: 5 as const,
  reviewed_crop: { x: 0, y: 0, width: 1920, height: 1080, source_width: 1920, source_height: 1080 },
};
const prepared = {
  asset_id: id(5), original_asset_id: id(4), original_sha256: sha, original_bytes: 100_000,
  aspect: '16:9', reviewed_crop: manifest.reviewed_crop, sha256: 'b'.repeat(64),
  bytes: 50_000, width: 1920, height: 1080, etag: 'prepared-etag',
};
const inputURL = 'https://9c332c75b96cc642621dad5d86d4bf18.r2.cloudflarestorage.com/prepared.jpg';
const qualified = { exterior: true, uncertain: false, front_entrance_visible: true, reason: 'exterior' };

function dispatch(evidence: unknown) {
  const calls = { submitted: 0, receipts: 0, rejected: [] as Array<[number, string]>, ambiguous: 0 };
  const store: AerialStageStore = {
    claimGeneration: () => Promise.resolve({ claimed: true, token: id(6), manifest,
      eligibility: evidence as ReturnType<typeof exteriorAssessment>, prepared, inputURL }),
    receipt: () => { calls.receipts++; return Promise.resolve(); },
    ambiguous: () => { calls.ambiguous++; return Promise.resolve(); },
    rejected: (_job, _token, status, errorClass) => { calls.rejected.push([status, errorClass]); return Promise.resolve(); },
    pollAuthority: () => Promise.resolve(null),
  };
  const provider: AerialProvider = {
    submit: () => { calls.submitted++; return Promise.resolve({ provider: 'kie' as const, model: aerialGenerationModel(manifest.profile),
      id: 'accepted-task', submitted_at: '2026-10-27T00:00:00Z',
      poll_url: 'https://api.kie.ai/api/v1/jobs/recordInfo?taskId=accepted-task' }); },
    poll: () => Promise.resolve(null), rejection: () => null,
  };
  return { calls, run: () => submitAerialOnce(id(7), store, provider) };
}

Deno.test('front-exterior without a visible entrance is ineligible even if the vision model calls the exterior clear', async () => {
  const evidence = exteriorAssessment({ ...qualified, front_entrance_visible: false });
  assertEquals(evidence, { exterior: true, uncertain: true, front_entrance_visible: false, reason: 'uncertain' });
  assertEquals(mayGenerate(evidence), false);
  // Matches the SQL assessment transition: only true/false/exterior queues generation.
  assertEquals(evidence.exterior && !evidence.uncertain && evidence.reason === 'exterior', false);
  const d = dispatch(evidence);
  assertEquals(await d.run(), { dispatched: false, rejected: true });
  assertEquals(d.calls, { submitted: 0, receipts: 0, rejected: [[0, 'validation']], ambiguous: 0 });
});

Deno.test('old saved exterior evidence without an entrance field cannot reach KIE after a deploy', async () => {
  assertThrows(() => exteriorAssessment({ exterior: true, uncertain: false, reason: 'exterior' }));
  const d = dispatch({ exterior: true, uncertain: false, reason: 'exterior' });
  assertEquals(await d.run(), { dispatched: false, rejected: true });
  assertEquals(d.calls.submitted, 0);
  assertEquals(d.calls.rejected, [[0, 'validation']]);
});

Deno.test('one clearly visible entrance retains the existing manifest, provider submission and receipt path', async () => {
  const evidence = exteriorAssessment(qualified);
  assert(mayGenerate(evidence));
  const d = dispatch(evidence);
  assertEquals(await d.run(), { dispatched: true });
  assertEquals(d.calls, { submitted: 1, receipts: 1, rejected: [], ambiguous: 0 });
});

Deno.test('ineligible exterior replies explain the new-photo recovery without changing saved reply fields', async () => {
  const reply = await aerialReply({ id: id(7), operation_id: id(1), actor_id: id(8), org_id: id(3),
    library_org_id: id(3), listing_id: id(2), manifest_sha256: sha, manifest,
    state: 'ineligible', message: null, quote: {}, cancel_requested_at: null,
    eligibility: exteriorAssessment({ ...qualified, front_entrance_visible: false }) });
  assertEquals(reply.state, 'ineligible');
  assertEquals(reply.may_submit, false);
  assert(reply.message.includes('front entrance'));
  assert(reply.message.includes('No video was generated'));
  assertEquals(Object.hasOwn(reply, 'eligibility'), false);
});

Deno.test('lost KIE acceptance acknowledgement never sends a second paid POST', async () => {
  let claims = 0, posts = 0, receiptWrites = 0, unknowns = 0, polls = 0;
  const store: AerialStageStore = {
    claimGeneration: () => Promise.resolve({ claimed: ++claims === 1,
      token: id(6), manifest, eligibility: qualified, prepared, inputURL }),
    receipt: () => { receiptWrites++; return Promise.reject(Error('saved receipt ack lost')); },
    ambiguous: () => { unknowns++; return Promise.resolve(); },
    rejected: () => { throw Error('uncertain acceptance must not be marked rejected'); },
    pollAuthority: () => Promise.resolve(null),
  };
  const provider: AerialProvider = {
    submit: () => { posts++; return Promise.resolve({ provider: 'kie',
      model: aerialGenerationModel(manifest.profile), id: 'paid-once',
      submitted_at: '2026-10-27T00:00:00Z',
      poll_url: 'https://api.kie.ai/api/v1/jobs/recordInfo?taskId=paid-once' }); },
    poll: () => { polls++; return Promise.resolve({ status: 'done' }); },
    rejection: () => null,
  };
  assertEquals(await submitAerialOnce(id(7), store, provider),
    { dispatched: true, acceptance_unknown: true });
  assertEquals(await submitAerialOnce(id(7), store, provider), { dispatched: false });
  assertEquals(await pollSavedAerial(id(7), store, provider),
    { status: 'acceptance_unconfirmed' });
  assertEquals({ posts, receiptWrites, unknowns, polls },
    { posts: 1, receiptWrites: 1, unknowns: 1, polls: 0 });
});
