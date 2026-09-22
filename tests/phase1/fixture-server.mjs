import http from 'node:http';
import { readFileSync } from 'node:fs';
import assert from 'node:assert/strict';

const port = Number(process.argv[2] ?? 18765);
const clip = readFileSync(process.argv[3]);
assert(Number.isInteger(port) && port > 1024 && port < 65536);
const base = `http://127.0.0.1:${port}`;
let blocked = true;
let requests = {};
let bodyByRoute = {};
let accepted = 0;
const token = 'fixture.' + Buffer.from(JSON.stringify({sub:'10000000-0000-4000-8000-000000000003',is_anonymous:true})).toString('base64url') + '.fixture';

http.createServer(async (req, res) => {
  const path = new URL(req.url, base).pathname;
  const chunks = [];
  for await (const part of req) chunks.push(part);
  let body = {};
  try { body = JSON.parse(Buffer.concat(chunks).toString() || '{}'); } catch {}
  const json = (data, status = 200) => {
    res.writeHead(status, {'content-type':'application/json'}); res.end(JSON.stringify(data));
  };
  if (path === '/__control/reset') { blocked = true; requests={}; bodyByRoute={}; accepted=0; return json({ok:true}); }
  if (path === '/__control/unblock') { blocked=false; return json({ok:true}); }
  if (path === '/__control/state') return json({blocked, requests, accepted});
  requests[path]=(requests[path]??0)+1;
  bodyByRoute[path]=body;
  if (path === '/clip.mp4') { res.writeHead(200, {'content-type':'video/mp4'}); return res.end(clip); }
  if (path === '/auth/v1/signup') {
    // Actual TCP connection loss, not a fake signed-out flag or mocked Bool.
    if (blocked) return req.socket.destroy();
    accepted++;
    return json({access_token:token, refresh_token:'local-fixture-refresh', expires_in:3600});
  }
  if (path === '/functions/v1/renders/publish-app') return json({
    id:'10000000-0000-4000-8000-000000000004',slug:'local-test',share_url:base+'/f/local-test',
    unbranded_url:base+'/u/local-test',video_url:base+'/clip.mp4',duration_s:1
  });
  if (path === '/functions/v1/ai-photo') return json({image_b64:body.image_b64,mime:'image/jpeg'});
  if (path === '/functions/v1/ai-video/aerial' || path === '/functions/v1/ai-video/reel-clip') return json({
    request_id:`fixture-${requests[path]}`,status_url:base+'/job/status',response_url:base+'/job/result',
    kind:path.endsWith('aerial')?'aerial':'reel',grounded:true,synthetic:true
  },202);
  if (path === '/functions/v1/ai-video/status') return json({status:'completed',video_url:base+'/clip.mp4'});
  if (path === '/functions/v1/ai-video/drift') return json({drift:{status:'pass',publishable:true,action:'publish',message:'Fixture passed'}});
  if (path === '/functions/v1/ai-copy/shotlist') return json({script:'Two test photos.',shots:(body.photos??[]).map((p,i)=>({photo_id:p.id,order:i+1,seconds:2,motion:'push_in'}))});
  if (path === '/functions/v1/me/compliance') return json({rows:[]});
  if (path === '/functions/v1/me') return json({plan:'team',plan_raw:'team',role:'owner',entitlement:{photo_edits_per_month:100,renders_per_month:100,reels_per_month:100,aerials_per_month:100,topaz_per_month:100}});
  if (path === '/functions/v1/events') return json({ok:true});
  // Best-effort uploads fail immediately in these feature-gate tests. No real
  // storage, original image, credential, account, or external provider exists.
  if (path.startsWith('/functions/v1/uploads')) return json({error:'Local fixture has no storage',code:'upstream'},503);
  return json({error:'Unimplemented local fixture route',code:'not_found'},404);
}).listen(port,'127.0.0.1',()=>process.stdout.write(`Local fixture ready at ${base}\n`));
