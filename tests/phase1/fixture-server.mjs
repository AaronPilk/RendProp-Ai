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
let identifiedExchanges = 0;
let reviewTokens = new Map();
const owner = '10000000-0000-4000-8000-000000000003';
const org = '10000000-0000-4000-8000-000000000005';
const refreshToken = 'local-fixture-refresh';
const reviewOwnerB = '10000000-0000-4000-8000-000000000006';
const reviewOrgB = '10000000-0000-4000-8000-000000000007';
const token = (seconds, subject = owner) => 'fixture.' + Buffer.from(JSON.stringify({
  sub:subject,is_anonymous:false,exp:Math.floor(Date.now()/1000)+seconds
})).toString('base64url') + '.fixture';
let refreshedToken;

http.createServer(async (req, res) => {
  const url = new URL(req.url, base);
  const path = url.pathname;
  const chunks = [];
  for await (const part of req) chunks.push(part);
  let body = {};
  try { body = JSON.parse(Buffer.concat(chunks).toString() || '{}'); } catch {}
  const json = (data, status = 200) => {
    res.writeHead(status, {'content-type':'application/json'}); res.end(JSON.stringify(data));
  };
  if (path === '/__control/reset') { blocked = true; requests={}; bodyByRoute={}; accepted=0; identifiedExchanges=0; refreshedToken=undefined; reviewTokens=new Map(); return json({ok:true}); }
  if (path === '/__control/unblock') { blocked=false; return json({ok:true}); }
  if (path === '/__control/state') return json({blocked, requests, accepted, identifiedExchanges});
  requests[path]=(requests[path]??0)+1;
  if (path === '/auth/v1/token') {
    const grant = url.searchParams.get('grant_type');
    const route = `${path}?grant_type=${grant}`;
    requests[route]=(requests[route]??0)+1;
    if (grant === 'id_token' && body.provider === 'apple' && body.id_token === 'rendprop-session-network-identified-fixture') {
      identifiedExchanges++;
      return json({access_token:token(30), refresh_token:refreshToken, expires_in:30});
    }
    // Synthetic .invalid accounts exist only on this loopback test server.
    if (grant === 'password' && body.email === 'review-a@example.invalid' && body.password === 'fixture-a-only') {
      identifiedExchanges++;
      const access = token(3600);
      reviewTokens.set(access, owner);
      return json({access_token:access, refresh_token:'review-fixture-a', expires_in:3600});
    }
    if (grant === 'password' && body.email === 'review-b@example.invalid' && body.password === 'fixture-b-only') {
      identifiedExchanges++;
      const access = token(3600, reviewOwnerB);
      reviewTokens.set(access, reviewOwnerB);
      return json({access_token:access, refresh_token:'review-fixture-b', expires_in:3600});
    }
    if (grant === 'refresh_token' && body.refresh_token === refreshToken) {
      // Actual TCP loss while refreshing an already identified account.
      if (blocked) return req.socket.destroy();
      accepted++;
      refreshedToken=token(3600);
      return json({access_token:refreshedToken, refresh_token:refreshToken, expires_in:3600});
    }
    return json({error:'Unknown local fixture credential',code:'unauthorized'},401);
  }
  bodyByRoute[path]=body;
  if (path === '/clip.mp4') { res.writeHead(200, {'content-type':'video/mp4'}); return res.end(clip); }
  if (path === '/auth/v1/signup') {
    return json({error:'Guest signup is not supported by this fixture',code:'forbidden'},403);
  }
  const reviewActor = reviewTokens.get(req.headers.authorization?.replace(/^Bearer /, ''));
  if (path.startsWith('/functions/v1/') && !reviewActor && (!refreshedToken || req.headers.authorization !== `Bearer ${refreshedToken}`)) {
    return json({error:'Identified token refresh required',code:'unauthorized'},401);
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
  if (path === '/functions/v1/me/workspaces') {
    const actor = reviewActor ?? owner;
    const library = actor === reviewOwnerB ? reviewOrgB : org;
    return json({actor_id:actor,own_org_id:library,billing_org_id:library,
      can_switch_agent_libraries:false,active_org_id:library,workspaces:[{id:library,name:'Network Test Workspace',role:'owner',
        access_mode:'own',library_owner_user_id:actor,billing_org_id:library,can_read:true,can_write:true,can_manage_subscription:true}]});
  }
  if (path === '/functions/v1/events') return json({ok:true});
  // Best-effort uploads fail immediately in these feature-gate tests. No real
  // storage, original image, credential, account, or external provider exists.
  if (path.startsWith('/functions/v1/uploads')) return json({error:'Local fixture has no storage',code:'upstream'},503);
  return json({error:'Unimplemented local fixture route',code:'not_found'},404);
}).listen(port,'127.0.0.1',()=>process.stdout.write(`Local fixture ready at ${base}\n`));
