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
import{temporalReport,temporalRequired,temporalRoute}from ${JSON.stringify(new URL('./temporal.ts', import.meta.url).href)};
const read=()=>globalThis.__videoQualityTest();
const assert=(ok,status,message)=>{if(!ok)throw Error(String(status)+': '+message)};
const bytesFrom=async()=>({bytes:new Uint8Array([1,2,3])});
const base64=()=> 'AQID';
const callAI=async(ctx,method,path,body)=>{read().calls.push({method,path,body});return read().response};
const rpc=async(name,args)=>{read().rpc.push({name,args});if(read().rpcError)throw Error('rpc unavailable');if(name==='property_video_job_temporal')return read().temporalResult??{...args.p_report,attempt_id:args.p_attempt,clip_sha256:args.p_clip_sha256,recorded_at:'2026-10-17T12:00:00Z'};return read().retryResult};
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

// ---- temporal motion gate (steady profiles) ---------------------------------
import { PROPERTY_VIDEO_STEADY_PROFILE } from '../ai-video/property-video-quality.ts';
import { KIE_PROPERTY_PROFILE } from '../_shared/property-video-kie.ts';
import { TEMPORAL_LIMITS_SHA256, TEMPORAL_LIMITS, TEMPORAL_QC_PROFILE, temporalLimitsCanonical, sha256Hex, temporalReport, temporalRoute } from './temporal.ts';
const steadyCtx = (profile: string, retried = false) => ({ ...ctx(retried), job: { id: 'job', listing_id: 'listing', quality_profile: profile, manifest: { aspect: '16:9' } } });
const metrics = { profile: 'temporal-motion-v2', fps: 24, steps: 120, frame: [1920, 1080], invalid_ratio: 0, bob_pp_px: .3, bob_rms_px: .1, sway_pp_px: .2, sway_rms_px: .1, cadence_acf: 0, cadence_hz: null, roll_wobble_pp_deg: .01, roll_drift_deg: .1, roll_span_deg: .1, zoom_pump_pp_pct: .02, zoom_pct: 8, zoom_excursion_pct: 8, pan_excursion_pct: 1, pan_x_pct: 1, pan_y_pct: 0, speed_px_per_frame: 1.2, speed_cv: .1, duplicate_ratio: 0, static_shot: false };
const report = (reasons: string[] = []) => ({ metrics, verdict: { profile: TEMPORAL_QC_PROFILE, pass: reasons.length === 0, reasons }, limits: { profile: TEMPORAL_QC_PROFILE, sha256: TEMPORAL_LIMITS_SHA256 } });
const temporalRpc = (r: unknown) => ({ name: 'property_video_job_temporal', args: { p_job: 'job', p_lease: 'lease', p_attempt: 'attempt', p_clip_sha256: 'clip', p_report: temporalReport(r) } });

Deno.test('the worker and the renderer pin the same versioned temporal limit set', async () => {
  assertEquals(await sha256Hex(temporalLimitsCanonical()), TEMPORAL_LIMITS_SHA256);
  assertEquals(Object.keys(TEMPORAL_LIMITS).length, 11);
  assertEquals(temporalLimitsCanonical().split('\n')[0], 'bob_pp_px=1.2');
  assertEquals(temporalLimitsCanonical({ a: 1.0, b: .4 }), 'a=1\nb=0.4'); // %g parity with motion_qc.limits_canonical
});
Deno.test('a steady shot without a temporal report is HELD: no judge call, no state change, no purchase', async () => {
  for (const profile of [PROPERTY_VIDEO_STEADY_PROFILE, KIE_PROPERTY_PROFILE]) {
    reset(200, { action: 'accept', publishable: true });
    await assertRejects(() => quality(steadyCtx(profile), raw), Error, '409');
    assertEquals(state.calls, []); assertEquals(state.rpc, []); assertEquals(state.fail, []);
  }
});
Deno.test('malformed, foreign-limit or inconsistent temporal reports are held, never recorded', async () => {
  const good = report();
  for (const bad of [
    null, 42, 'pass', {}, { ...good, limits: { profile: 'temporal-motion-v2', sha256: 'f'.repeat(64) } }, { ...good, limits: { profile: 'temporal-motion-v1', sha256: TEMPORAL_LIMITS_SHA256 } },
    { ...good, limits: undefined }, { ...good, metrics: { ...metrics, profile: 'other' } }, { ...good, verdict: { profile: 'temporal-motion-v2', pass: true, reasons: ['vertical_bob'] } },
    { ...good, verdict: { profile: 'temporal-motion-v2', pass: false, reasons: [] } }, { ...good, verdict: { profile: 'temporal-motion-v2', pass: false, reasons: ['looks_fine_to_me'] } },
    { ...good, verdict: { profile: 'temporal-motion-v2', pass: 'true', reasons: [] } }, { ...good, metrics: { ...metrics, bob_pp_px: Infinity } }, { ...good, metrics: { ...metrics, note: 'x'.repeat(65) } },
  ]) {
    assertEquals(temporalReport(bad), null);
    reset(200, { action: 'accept', publishable: true });
    await assertRejects(() => quality(steadyCtx(PROPERTY_VIDEO_STEADY_PROFILE), { ...raw, temporal: bad }), Error, '409');
    assertEquals(state.calls, []); assertEquals(state.rpc, []); assertEquals(state.fail, []);
  }
});
Deno.test('a passing temporal report is recorded on the shot first, then the existing paid drift judge decides', async () => {
  for (const profile of [PROPERTY_VIDEO_STEADY_PROFILE, KIE_PROPERTY_PROFILE]) {
    reset(200, { action: 'accept', publishable: true });
    await quality(steadyCtx(profile), { ...raw, temporal: { ...report(), series: { dy: [1, 2, 3] } } });
    assertEquals(state.rpc.map((x: any) => x.name), ['property_video_job_temporal', 'property_video_job_qc']);
    assertEquals(state.rpc[0], temporalRpc(report()));
    assertEquals(Object.keys(state.rpc[0].args.p_report).sort(), ['limits', 'metrics', 'profile', 'verdict']); // series never persists
    assertEquals(state.calls.length, 1); assertEquals(state.calls[0].path, 'drift'); assertEquals(state.fail, []);
    reset(200, { action: 'retry', publishable: false });
    await quality(steadyCtx(profile), { ...raw, temporal: report() });
    assertEquals(state.rpc.map((x: any) => x.name), ['property_video_job_temporal', 'property_video_job_quality_retry']);
  }
});
Deno.test('the RECORDED verdict decides: an earlier stored verdict for this attempt outranks a fresh re-measurement', async () => {
  reset(200, { action: 'accept', publishable: true }); state.temporalResult = { ...report(['vertical_bob']), attempt_id: 'attempt', clip_sha256: 'clip', recorded_at: '2026-10-17T11:00:00Z' };
  await assertRejects(() => quality(steadyCtx(PROPERTY_VIDEO_STEADY_PROFILE), { ...raw, temporal: report() }), Error, '409');
  assertEquals(state.rpc.length, 1); assertEquals(state.calls, []); assertEquals(state.fail, []);
  reset(200, { action: 'accept', publishable: true }); state.temporalResult = { ...report(['walk_through_travel']), attempt_id: 'attempt', clip_sha256: 'clip', recorded_at: '2026-10-17T11:00:00Z' };
  await quality(steadyCtx(PROPERTY_VIDEO_STEADY_PROFILE), { ...raw, temporal: report() });
  assertEquals(state.fail, [{ code: 'quality_check_refused', ambiguous: false }]); assertEquals(state.calls, []);
  reset(200, { action: 'accept', publishable: true }); state.temporalResult = { not: 'a record' };
  await assertRejects(() => quality(steadyCtx(PROPERTY_VIDEO_STEADY_PROFILE), { ...raw, temporal: report() }), Error, '503');
  assertEquals(state.calls, []); assertEquals(state.fail, []);
});
Deno.test('a lost temporal record never reaches the paid judge', async () => {
  reset(200, { action: 'accept', publishable: true }); state.rpcError = true;
  await assertRejects(() => quality(steadyCtx(PROPERTY_VIDEO_STEADY_PROFILE), { ...raw, temporal: report() }));
  assertEquals(state.rpc.length, 1); assertEquals(state.calls, []); assertEquals(state.fail, []);
});
Deno.test('travel, horizon roll, repeated frames or an unmeasurable clip are recorded then refused without a judge call', async () => {
  for (const reasons of [['walk_through_travel'], ['horizon_roll'], ['duplicate_frames'], ['unmeasurable'], ['vertical_bob', 'walk_through_travel'], ['walking_cadence', 'duplicate_frames'], ['invalid_metrics']]) {
    assertEquals(temporalRoute(report(reasons).verdict), 'refuse');
    reset(200, { action: 'accept', publishable: true });
    await quality(steadyCtx(PROPERTY_VIDEO_STEADY_PROFILE), { ...raw, temporal: report(reasons) });
    assertEquals(state.rpc, [temporalRpc(report(reasons))]); assertEquals(state.calls, []);
    assertEquals(state.fail, [{ code: 'quality_check_refused', ambiguous: false }]);
  }
});
Deno.test('a bob, sway, cadence, wobble or pumping-only failure is recorded and HELD: no judge, no refusal, no purchase', async () => {
  for (const reasons of [['vertical_bob'], ['lateral_sway'], ['walking_cadence'], ['roll_wobble'], ['zoom_pumping'], ['vertical_bob', 'walking_cadence', 'zoom_pumping']]) {
    assertEquals(temporalRoute(report(reasons).verdict), 'retry');
    reset(200, { action: 'accept', publishable: true });
    await assertRejects(() => quality(steadyCtx(PROPERTY_VIDEO_STEADY_PROFILE), { ...raw, temporal: report(reasons) }), Error, '409');
    assertEquals(state.rpc, [temporalRpc(report(reasons))]); assertEquals(state.calls, []); assertEquals(state.fail, []);
  }
});
Deno.test.ignore('FOLLOW-UP V2 retry routing: a bob/cadence-only temporal failure routes into the one paid retry (needs a temporal grant in property_video_quality_retry_evidence; the SQL grant is drift-only today, so this fails by design)', async () => {
  reset(200, { action: 'accept', publishable: true });
  await quality(steadyCtx(PROPERTY_VIDEO_STEADY_PROFILE), { ...raw, temporal: report(['vertical_bob']) });
  assertEquals(state.rpc.map((x: any) => x.name), ['property_video_job_temporal', 'property_video_job_quality_retry']);
  assertEquals(state.calls, []); assertEquals(state.fail, []);
});
Deno.test('legacy and v1 jobs neither require nor record a temporal report, even when one arrives', async () => {
  for (const profile of [undefined, 'legacy', 'fal-kling3-4k-v1']) {
    reset(200, { action: 'accept', publishable: true });
    await quality({ ...ctx(), job: { id: 'job', listing_id: 'listing', quality_profile: profile } }, { ...raw, temporal: report(['walk_through_travel']) });
    assertEquals(state.rpc.map((x: any) => x.name), ['property_video_job_qc']); assertEquals(state.calls.length, 1); assertEquals(state.fail, []);
  }
});
Deno.test('deliberate defect control: without the profile check a legacy job starts demanding a report', async () => {
  const defect = prefix.replace('import{temporalReport,temporalRequired,temporalRoute}', 'import{temporalReport,temporalRoute}') + 'const temporalRequired=()=>true;\n';
  const { quality: broken } = await import('data:application/typescript,' + encodeURIComponent(defect + engine.slice(start, end) + '\n// defect control'));
  reset(200, { action: 'accept', publishable: true });
  await assertRejects(() => broken(ctx(), raw), Error, '409');
  assertEquals(state.calls, []); assertEquals(state.rpc, []);
  reset(200, { action: 'accept', publishable: true });
  await quality(ctx(), raw); assertEquals(state.rpc.map((x: any) => x.name), ['property_video_job_qc']);
});
