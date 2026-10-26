import assert from 'node:assert/strict';
import {buildSrc} from './build-src.mjs';

const load = buildSrc('dated-address-' + process.pid);
const {default: worker} = await load('index');
const {buildDemoTour} = await load('demo');
const {propertyAddressPath} = await load('property-seo');
const base = 'https://authority.fixture.invalid/functions/v1';
const address = '855 Central Ave #1120, Saint Petersburg, FL 33701';
const descriptor = '855-central-ave-1120-saint-petersburg-fl-33701';
const publishedAt = '2026-10-22T13:00:00Z';
const oldSlug = 'g2afbgmv32';
const aSlug = '3482b697c5f34c26a83b5d1b2b6f429a';
const bSlug = 'ab82b697c5f34c26a83b5d1b2b6f429b';
const futureSlug = 'cb82b697c5f34c26a83b5d1b2b6f429c';
const maxSlug = 'z'.repeat(64);
const futureAddress = '999 Pine St, Saint Petersburg, FL 33701';
const futureDescriptor = '999-pine-st-saint-petersburg-fl-33701';
const seed = buildDemoTour();
const make = (slug, agent, allowIndexing = false) => ({...seed, slug, published_at: publishedAt,
  share_url: 'https://rendprop.com/f/' + slug,
  listing: {...seed.listing, address, agent_id: agent,
    details: {...seed.listing.details, allow_indexing: allowIndexing}},
  agent_card: {...seed.agent_card, name: agent},
  listing_video: {url: `https://media.fixture.invalid/${slug}.mp4`, poster_url: 'https://media.fixture.invalid/poster.jpg',
    width: 1920, height: 1080, duration_s: 8, branding_policy: 'unbranded'}});
let old = make(oldSlug, 'Old Agent', true);
let a = make(aSlug, 'Agent A');
const b = make(bSlug, 'Agent B');
const future = {...make(futureSlug, 'Agent C', true), listing: {...seed.listing,
  address: futureAddress, details: {...seed.listing.details, allow_indexing: true}}};
const tours = new Map([[oldSlug, old], [aSlug, a], [bSlug, b], [futureSlug, future],
  [maxSlug, make(maxSlug, 'Agent D')]]);
const env = {SUPABASE_FUNCTIONS_URL: base, SUPABASE_ANON_KEY: 'fixture',
  ADDRESS_ONLY_CANONICAL: 'enabled', ADDRESS_LOOKUP_SECRET: 'b'.repeat(64), PROPERTY_DATE_SUFFIX: 'enabled'};
const ctx = {waitUntil(){throw Error('No customer cache');}, passThroughOnException(){}};
globalThis.caches = {default:{async match(){throw Error('No customer cache');}, async put(){throw Error('No customer cache');}}};
globalThis.fetch = async (url, init) => {
  assert.equal(init.cache, 'no-store');
  if (url === base + '/tours/address-lookup/' + descriptor) {
    assert.equal(new Headers(init.headers).get('X-Rendprop-Address-Lookup'), env.ADDRESS_LOOKUP_SECRET);
    return Response.json({status: 'unique', slug: oldSlug, claimed: true});
  }
  if (url === base + '/tours/address-lookup/855-central-avenue-unit-1120-saint-petersburg-fl-33701')
    return new Response('', {status: 404});
  if (url === base + '/tours/address-lookup/' + futureDescriptor)
    return Response.json({status: 'unique', slug: futureSlug});
  if (url.startsWith(base + '/tours/')) {
    assert.equal(new Headers(init.headers).get('X-Rendprop-Address-Lookup'), null);
    const tour = tours.get(url.slice((base + '/tours/').length));
    return tour ? Response.json(tour) : new Response('', {status: 404});
  }
  throw Error('Unexpected authority path: ' + url);
};
const get = (path, e = env) => worker.fetch(new Request('https://rendprop.com' + path), e, ctx);
const oldBare = '/property/' + descriptor;
const newA = propertyAddressPath(aSlug, address, '/property', publishedAt);
const newB = propertyAddressPath(bSlug, address, '/property', publishedAt);
let checks = 0;
const check = (ok, message) => { checks++; assert.ok(ok, message); };
check(newA === `${oldBare}/20261022.${aSlug}` && newB === `${oldBare}/20261022.${bSlug}` && newA !== newB,
  'Same-day, same-address agents receive distinct full-identity dated links');
const futurePath = propertyAddressPath(futureSlug, futureAddress, '/property', publishedAt);
const longPath = propertyAddressPath(maxSlug, address, '/property', publishedAt);
let result = await get(longPath);
check(result.status === 200 && (await result.text()).includes('Agent D'),
  'Maximum-length legacy slug survives its longer dated browser suffix');
result = await get('/f/' + futureSlug + '/share-link');
check((await result.json()).url === 'https://rendprop.com' + futurePath,
  'New first-at-address publication receives a dated identity, not a new bare alias');
result = await get('/property/' + futureDescriptor);
check(result.status === 404, 'New bare address is not issued, preventing future reassignment');
result = await get(futurePath);
check(result.status === 200 && (await result.text()).includes(`rel="canonical" href="https://rendprop.com${futurePath}"`),
  'Future indexable site uses its stable dated canonical');
result = await get(oldBare);
let html = await result.text();
check(result.status === 200 && html.includes(`rel="canonical" href="https://rendprop.com${oldBare}"`)
  && html.includes('Old Agent') && !html.includes('Agent A'), 'Old sold bare URL keeps its original listing');
for (const [slug, path, agent] of [[aSlug, newA, 'Agent A'], [bSlug, newB, 'Agent B']]) {
  result = await get('/f/' + slug + '/share-link');
  const link = await result.json();
  check(result.status === 200 && link.url === 'https://rendprop.com' + path && link.address_only === false,
    'Each duplicate gets its own dated address share URL');
  result = await get(path + '?page=contact');
  html = await result.text();
  check(result.status === 200 && html.includes(agent) && html.includes('id="leadform"')
    && html.includes(`rel="canonical" href="https://rendprop.com${path}?page=contact"`),
    'Dated URL keeps exact publication contact and canonical under noindex');
  check(result.headers.get('X-Robots-Tag') === 'noindex, nofollow', 'Dated URL respects noindex');
  result = await get(propertyAddressPath(slug, address) + '?page=gallery');
  check(result.status === 308 && result.headers.get('Location') === 'https://rendprop.com' + path + '?page=gallery',
    'Legacy address-plus-token link redirects to its own dated identity');
}
result = await get(newA);
html = await result.text();
check(result.status === 200 && html.includes(`${aSlug}.mp4`), 'Current listing hero selects its own saved video');
a = {...a, listing_video: {...a.listing_video, url: 'https://media.fixture.invalid/republished.mp4'},
  listing: {...a.listing, status: 'sold', agent_id: 'Transferred Agent'}, agent_card: {...a.agent_card, name: 'Transferred Agent'}};
tours.set(aSlug, a);
result = await get('/f/' + aSlug + '/share-link');
check((await result.json()).url === 'https://rendprop.com' + newA,
  'Republish on preserved slug/date, sold status and agent transfer leave share URL stable');
result = await get(newA);
html = await result.text();
check(result.status === 200 && html.includes('republished.mp4') && html.includes('Transferred Agent'),
  'Stable URL serves the current media and agent contact');
const corrected = '855 Central Ave Unit 1120, Saint Petersburg, FL 33701';
a = {...a, listing: {...a.listing, address: corrected}};
tours.set(aSlug, a);
result = await get(newA);
check(result.status === 308 && result.headers.get('Location') === 'https://rendprop.com'
  + propertyAddressPath(aSlug, corrected, '/property', publishedAt),
  'Address correction leaves previously shared URL working through an identity-preserving redirect');
result = await get(newB);
check(result.status === 200, 'Other agent stays reachable after first agent corrects address');
result = await get(oldBare);
check(result.status === 200 && (await result.text()).includes('Old Agent'),
  'Old bare binding stays fixed after duplicate republish and address correction');
old = {...old, listing: {...old.listing, address: '855 Central Avenue Unit 1120, Saint Petersburg, FL 33701'}};
tours.set(oldSlug, old);
result = await get(oldBare);
html = await result.text();
check(result.status === 200 && html.includes('Old Agent') && !html.includes('Agent A')
  && html.includes(`rel="canonical" href="https://rendprop.com${propertyAddressPath(oldSlug, old.listing.address, '/property', publishedAt)}"`),
  'Previously shared bare URL still serves only its original listing after address correction');
tours.delete(aSlug);
result = await get(newA);
check(result.status === 404 && !result.headers.has('Location'),
  'Unpublishing revokes dated alias rather than leaking corrected address');
const disabled = {...env, PROPERTY_DATE_SUFFIX: undefined};
result = await get(newB, disabled);
check(result.status === 308 && result.headers.get('Location') === 'https://rendprop.com'
  + propertyAddressPath(bSlug, address), 'Feature rollback still resolves dated shares via old token');
console.log(`Dated property links: ${checks} closed Worker checks passed; no live calls or mutations.`);
