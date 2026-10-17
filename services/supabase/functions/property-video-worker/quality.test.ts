import { assertEquals, assertRejects } from 'https://deno.land/std@0.224.0/assert/mod.ts';

// Compile the actual quality entry point with closed transport/RPC boundaries.
// A terminal paid verdict is synthesized here; the PostgreSQL suite separately
// proves receipt authority, one grant, stale callbacks and concurrent recovery.
const engine = await Deno.readTextFile(new URL('./engine.ts', import.meta.url));
const start = engine.indexOf('export async function quality(');
const end = engine.indexOf('\nasync function media(', start);
if (start < 0 || end < 0) throw Error('Actual quality entry point missing');
let state: any;
const prefix = `
const read=()=>globalThis.__videoQualityTest();
const assert=(ok,status,message)=>{if(!ok)throw Error(String(status)+': '+message)};
const bytesFrom=async()=>({bytes:new Uint8Array([1,2,3])});
const base64=()=> 'AQID';
const callAI=async(ctx,method,path,body)=>{read().calls.push({method,path,body});return read().response};
const rpc=async(name,args)=>{read().rpc.push({name,args});if(read().rpcError)throw Error('rpc unavailable');return read().retryResult};
const fail=async(ctx,code,ambiguous)=>read().fail.push({code,ambiguous});
`;
(globalThis as any).__videoQualityTest = () => state;
const { quality } = await import('data:application/typescript,' + encodeURIComponent(prefix + engine.slice(start, end)));
const ctx = (retried = false) => ({ job: { id: 'job', listing_id: 'listing' }, source: {
  attempt_id: 'attempt', lease_token: 'lease', clip: { sha256: 'clip' }, receipt: { request_id: 'paid-request' },
  source: {}, motion: 'push_in', asset_id: 'photo', generation_provenance_id: 'provenance', quality_retries: retried ? 1 : 0,
} });
const raw = { clip_sha256: 'clip', frames: [0,1,2].map(() => ({ image_b64: 'AQID', mime: 'image/jpeg' })) };
function reset(status: number, drift: unknown) {
  state = { response: { status, value: { drift } }, calls: [], rpc: [], fail: [], retryResult: { retry_scheduled: true } };
}

Deno.test('terminal paid retry schedules one authority RPC and never approves or substitutes', async () => {
  reset(200, { action: 'retry', publishable: false });
  await quality(ctx(), raw);
  assertEquals(state.rpc, [{ name: 'property_video_job_quality_retry', args: { p_job: 'job', p_lease: 'lease', p_attempt: 'attempt' } }]);
  assertEquals(state.fail, []);
  assertEquals(state.calls.length, 1);
  assertEquals(state.calls[0].body.attempt, 0);
  assertEquals(state.calls[0].body.provenance_id, 'provenance');
});
Deno.test('safe retry is explicitly judged as final even after the lineage rate window', async () => {
  reset(200, { action: 'refuse', publishable: false });
  await quality(ctx(true), raw);
  assertEquals(state.calls[0].body.attempt, 1);
  assertEquals(state.rpc, []);
  assertEquals(state.fail, [{ code: 'quality_check_refused', ambiguous: false }]);
});
Deno.test('only an explicit accepted publishable verdict advances the source', async () => {
  reset(200, { action: 'accept', publishable: true });
  await quality(ctx(), raw);
  assertEquals(state.rpc[0].name, 'property_video_job_qc');
  assertEquals(state.fail, []);
  for (const drift of [{ publishable: true }, { action: 'retry', publishable: true }, { action: 'accept', publishable: false }]) {
    reset(200, drift); await quality(ctx(), raw); assertEquals(state.rpc, []); assertEquals(state.fail.length, 1);
  }
});
Deno.test('hold, malformed and transport refusals cannot buy another generation', async () => {
  for (const [status, drift] of [[200, { action: 'hold', publishable: false }], [503, {}], [402, {}], [409, {}], [200, null]] as const) {
    reset(status, drift); await quality(ctx(), raw);
    assertEquals(state.rpc, []); assertEquals(state.calls.length, 1); assertEquals(state.fail.length, 1);
  }
});
Deno.test('lost or refused grant acknowledgement never becomes an approval or repeated judge call', async () => {
  reset(200, { action: 'retry', publishable: false }); state.rpcError = true;
  await assertRejects(() => quality(ctx(), raw));
  assertEquals(state.calls.length, 1); assertEquals(state.rpc.length, 1); assertEquals(state.fail, []);
  reset(200, { action: 'retry', publishable: false }); state.retryResult = { retry_scheduled: false };
  await assertRejects(() => quality(ctx(), raw));
  assertEquals(state.calls.length, 1); assertEquals(state.rpc.length, 1); assertEquals(state.fail, []);
});
Deno.test('changed clip or missing frames stop before the judge or any state mutation', async () => {
  reset(200, { action: 'retry', publishable: false });
  await assertRejects(() => quality(ctx(), { ...raw, clip_sha256: 'different' }));
  await assertRejects(() => quality(ctx(), { ...raw, frames: raw.frames.slice(1) }));
  assertEquals(state.calls, []); assertEquals(state.rpc, []); assertEquals(state.fail, []);
});
