import { assertEquals, assertThrows } from 'https://deno.land/std@0.224.0/assert/mod.ts';
import { HttpError } from '../_shared/http.ts';
import { aerialCompositeValue, type AerialCompositeRPC } from './aerial-rpc.ts';

const id = (n: number) => `f3000000-0000-4000-8000-${String(n).padStart(12, '0')}`;
const row = () => ({
  id: id(1), actor_id: id(2), operation_id: id(3), org_id: id(4),
  library_org_id: id(5), listing_id: id(6), manifest_sha256: 'a'.repeat(64),
  state: 'queued', manifest: { operation_id: id(3), listing_id: id(6) }, consent: {},
});
const allNull = { id: null, actor_id: null, operation_id: null, org_id: null,
  library_org_id: null, listing_id: null, manifest_sha256: null, state: null,
  manifest: null, consent: null };

Deno.test('aerial worker probe treats an ordinary video ID as no aerial row', () => {
  for (const absent of [null, [], allNull]) {
    assertEquals(aerialCompositeValue('property_video_aerial_worker_read', absent, { p_id: id(9) }), null);
    assertEquals(aerialCompositeValue('property_video_aerial_operation', absent, { p_operation: id(9) }), null);
  }
});

Deno.test('required aerial RPCs reject an absent composite row', () => {
  const required: AerialCompositeRPC[] = [
    'property_video_aerial_scope', 'property_video_aerial_admit',
    'property_video_aerial_cancel', 'property_video_aerial_cpu_output',
  ];
  for (const name of required) for (const absent of [null, [], allNull]) {
    const error = assertThrows(() => aerialCompositeValue(name, absent, {}), HttpError);
    assertEquals(error.status, 503);
  }
});

Deno.test('aerial probe still validates a present row and its requested identity', () => {
  const saved = row();
  assertEquals(aerialCompositeValue('property_video_aerial_worker_read', [saved], { p_id: saved.id }), saved);
  assertEquals(assertThrows(() => aerialCompositeValue('property_video_aerial_worker_read', [saved], { p_id: id(9) }), HttpError).status, 409);
  assertEquals(assertThrows(() => aerialCompositeValue('property_video_aerial_worker_read', [saved, saved], { p_id: saved.id }), HttpError).status, 503);
  assertEquals(assertThrows(() => aerialCompositeValue('property_video_aerial_worker_read', { ...saved, manifest_sha256: 'bad' }, { p_id: saved.id }), HttpError).status, 503);
});
