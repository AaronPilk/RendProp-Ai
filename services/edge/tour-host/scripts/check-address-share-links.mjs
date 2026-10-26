import assert from 'node:assert/strict';
import {buildSrc} from './build-src.mjs';
const load = buildSrc('address-share-links-' + process.pid);
const {default: worker} = await load('index');
const {buildDemoTour} = await load('demo');
const {propertyAddressPath, propertyAddressSlug} = await load('property-seo');
const {unbrandedSelfCheck} = await load('player');
let assertions = 0;
const check = (value, message) => { assertions++; assert.ok(value, message); };
const slug = 'published_123-abc', address = '855 Central Ave #1120, Saint Petersburg, FL, United States';
const descriptor = '855-central-ave-1120-saint-petersburg-fl-united-states';
const tour = {...buildDemoTour(), slug, share_url:'https://rendprop.com/f/' + slug,
  listing:{...buildDemoTour().listing,address}};
const path = '/u/' + descriptor + '/' + slug;
check(propertyAddressPath(slug,address,'/u') === path, 'MLS path uses address and unchanged publication token');
for (const [raw,expected] of [['Élan / </script> & Suite #2','elan-script-suite-2'],['ＡＢＣ １２３','abc-123'],['Straße','stra-e'],['中文',''],['x'.repeat(500),'x'.repeat(120)]]) {
  check(propertyAddressSlug(raw) === expected, 'Shared native/server descriptor contract');
}
const env = {SUPABASE_FUNCTIONS_URL:'https://authority.fixture.invalid/functions/v1',SUPABASE_ANON_KEY:'inert-public'};
const ctx = {waitUntil(){},passThroughOnException(){}};
globalThis.caches = {default:{async match(){throw new Error('No cached customer authority');},async put(){throw new Error('No cached customer authority');}}};
let status = 200, calls = 0;
globalThis.fetch = async (url,init) => {
  calls++;
  assert.equal(url, env.SUPABASE_FUNCTIONS_URL + '/tours/' + slug);
  assert.equal(init.cache, 'no-store');
  return new Response(status === 200 ? JSON.stringify(tour) : 'not published',{status});
};
const get = (target,method='GET') => worker.fetch(new Request('https://rendprop.com' + target,{method}),env,ctx);
for (const target of ['/u/' + slug,path]) {
  const response = await get(target);
  const html = await response.text();
  check(response.status === 200, 'Existing and address-based MLS links serve the same current publication');
  check(unbrandedSelfCheck(html,tour).length === 0, 'Address alias retains the actual unbranded self-check');
  check(!html.includes('rel="canonical"') && !html.includes('id="leadform"'), 'No branded canonical or contact form on MLS alias');
  check(response.headers.get('x-robots-tag')?.includes('noindex'), 'MLS address alias remains excluded from indexing');
  check(response.headers.get('cache-control') === 'no-store', 'No customer page retained after revocation');
}
let response = await get('/u/old-address/' + slug + '?embed=1');
check(response.status === 308 && response.headers.get('location') === 'https://rendprop.com' + path + '?embed=1', 'Address edit preserves unbranded route, token and query');
check(response.headers.get('x-robots-tag')?.includes('noindex') && response.headers.get('cache-control') === 'no-store', 'MLS redirect retains unbranded privacy headers');
status = 404;
response = await get('/u/old-address/' + slug);
const withdrawn = await response.text();
check(response.status === 404 && !response.headers.has('location'), 'Withdrawn publication cannot reveal a current address');
check(!withdrawn.includes(address) && !withdrawn.includes(descriptor), 'Unpublished response has no address disclosure');
status = 200;
response = await get(path,'HEAD');
check(response.status === 200 && (await response.text()) === '', 'Address-based MLS HEAD retains bodyless behavior');
const before = calls;
for (const bad of ['/u/address/' + slug + '/other', '/u/address/%2Fbad', '/u/address/a.b', '/u/../' + slug]) {
  response = await get(bad);
  check(response.status === 404, 'Malformed or unrelated address alias refuses');
}
check(calls === before, 'Malformed aliases never reach publication authority');
console.log(`Address share links: ${assertions} actual Worker/renderer checks passed; no live calls or mutations.`);
