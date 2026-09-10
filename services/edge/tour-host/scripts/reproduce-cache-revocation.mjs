// Diagnostic: exits 1 while WH-05 is present. No real network requests.
import assert from 'node:assert/strict';
import {buildSrc} from './build-src.mjs';
const load = buildSrc('audit-cache-proof');
const worker = (await load('index')).default;
const tour = (await load('demo')).buildDemoTour();
tour.slug = 'synthetic-revocation';
const cache = new Map(), pending = [];
globalThis.caches = { default: {
  match: async request => cache.get(request.url)?.clone(),
  put: async (request, response) => {cache.set(request.url, response.clone());},
}};
let revoked = false, calls = 0;
globalThis.fetch = async () => {
  calls++;
  return revoked ? new Response('{}', {status:404}) : Response.json(tour);
};
const env = {SUPABASE_FUNCTIONS_URL:'https://synthetic.invalid',SUPABASE_ANON_KEY:'synthetic',TOUR_CACHE_TTL:'60'};
const ctx = {waitUntil: p => pending.push(p)};
const request = new Request('https://rendprop.com/f/synthetic-revocation');
assert.equal((await worker.fetch(request,env,ctx)).status,200);
await Promise.all(pending);
revoked = true;
const after = await worker.fetch(request,env,ctx);
console.log(JSON.stringify({upstreamRevoked:revoked,secondStatus:after.status,upstreamCalls:calls,
                           cacheControl:after.headers.get('cache-control')}));
assert.equal(after.status,404,'revoked tour should stop being served');
