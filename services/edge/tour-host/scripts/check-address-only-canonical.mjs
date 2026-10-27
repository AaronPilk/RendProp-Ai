import assert from 'node:assert/strict';
import {buildSrc} from './build-src.mjs';

const load = buildSrc('address-only-' + process.pid);
const {default: worker} = await load('index');
const {buildDemoTour} = await load('demo');
const {propertyAddressOnlyPath, propertyAddressPath} = await load('property-seo');
const {propertySitemapXml} = await load('sitemap');
const slug = 'published_123-abc';
const address = '855 Central Ave #1120, Saint Petersburg, FL, United States';
const descriptor = '855-central-ave-1120-saint-petersburg-fl-united-states';
const longDescriptor = 'x'.repeat(70);
const path = '/property/' + descriptor;
const base = 'https://authority.fixture.invalid/functions/v1';
const seed = buildDemoTour();
let tour = {...seed, slug, share_url:'https://rendprop.com/f/' + slug,
  listing:{...seed.listing, address}};
let unique = true, claimed = true, withdrawn = false, aliasTour = null, resolverCalls = 0;
let resolverFailure = false, resolverMissing = false, malformedResolver = false;
let descriptorReads = 0, aliasFailureOnRead = null, aliasMalformedOnRead = null;
const addressSecret = 'b'.repeat(64);
const env = {SUPABASE_FUNCTIONS_URL:base, SUPABASE_ANON_KEY:'inert-public', ADDRESS_ONLY_CANONICAL:'enabled', ADDRESS_LOOKUP_SECRET:addressSecret};
const ctx = {waitUntil(){throw Error('Customer page cannot cache');}, passThroughOnException(){}};
globalThis.caches = {default:{async match(){throw Error('Customer page cannot cache');}, async put(){throw Error('Customer page cannot cache');}}};
globalThis.fetch = async (url,init) => {
  assert.equal(init.cache,'no-store');
  assert.equal(init.redirect,'manual');
  if (url === base + '/tours/address-lookup/' + descriptor || url === base + '/tours/address-lookup/123-other-st' || url === base + '/tours/address-lookup/' + longDescriptor) {
    resolverCalls++;
    assert.equal(new Headers(init.headers).get('X-Rendprop-Address-Lookup'),addressSecret,'private lookup credential reaches only the API');
    if (resolverFailure) return new Response('',{status:503});
    if (resolverMissing) return new Response('',{status:404});
    if (malformedResolver) return Response.json({status:'unique',slug,extra:'untrusted'});
    return Response.json(unique && claimed && url.endsWith(descriptor)
      ? {status:'unique',slug,claimed:true} : {status:'ambiguous'});
  }
  assert.equal(new Headers(init.headers).get('X-Rendprop-Address-Lookup'),null,'private lookup credential is never sent to ordinary tours');
  if (url === base + '/tours/' + slug) return withdrawn ? new Response('',{status:404}) : Response.json(tour);
  if (url === base + '/tours/unknown-token') return new Response('',{status:404});
  if (url === base + '/tours/' + descriptor) {
    descriptorReads++;
    if (descriptorReads === aliasFailureOnRead) return new Response('',{status:503});
    if (descriptorReads === aliasMalformedOnRead) return Response.json({unexpected:'malformed alias'});
    return aliasTour ? Response.json(aliasTour) : new Response('',{status:404});
  }
  throw Error('Unexpected authority path: ' + url);
};
const get = (target, environment = env) => worker.fetch(new Request('https://rendprop.com' + target),environment,ctx);
let checks = 0;
const check = (condition,message) => { checks++; assert.ok(condition,message); };

check(propertyAddressOnlyPath(address) === path,'Exact address-only path');
check(propertyAddressOnlyPath('中文') === null,'Empty ASCII descriptor refuses address-only path');
const oldPath = propertyAddressPath(slug,address);
let response = await get('/f/' + slug);
check(response.status === 200 && (await response.text()).includes(`rel="canonical" href="https://rendprop.com${path}"`),
  'Legacy /f publication stays open and names the address-only canonical');
response = await get('/f/' + slug + '/share-link');
let link = await response.json();
check(response.status === 200 && link.url === 'https://rendprop.com' + path && link.address_only === true,
  'Public slug lookup returns the same verified address-only canonical');
check(response.headers.get('Cache-Control') === 'no-store' && response.headers.get('X-Robots-Tag') === 'noindex, nofollow',
  'Share lookup is neither cached nor indexed');
response = await worker.fetch(new Request('https://rendprop.com/f/' + slug + '/share-link',{method:'HEAD'}),env,ctx);
check(response.status === 200 && (await response.text()) === '' && response.headers.get('Cache-Control') === 'no-store',
  'HEAD reports the same current share-link status without a body');
response = await get('/f/unknown-token/share-link');
check(response.status === 404 && !(await response.text()).includes(address),
  'A missing publication cannot expose an address');
response = await get('/f/' + slug + '/share-link?address=' + descriptor);
check(response.status === 404,'Share lookup never takes an address or query as authority');
const resolverBeforeBare = resolverCalls;
response = await get(path + '?page=gallery');
let html = await response.text();
check(response.status === 200 && html.includes(`rel="canonical" href="https://rendprop.com${path}?page=gallery"`),
  'Address-only gallery resolves a current unique publication');
check(resolverCalls - resolverBeforeBare === 2,
  'Bare link uses the initial alias lookup and one fresh post-tour proof, not a redundant third resolver call');
check(html.includes(`href="${path}?page=contact"`),'Internal navigation retains the address-only path');
response = await get(oldPath + '?page=gallery');
check(response.status === 308 && response.headers.get('location') === 'https://rendprop.com' + path + '?page=gallery',
  'Old address-plus-ID link redirects after fresh unique proof');
const sitemap = propertySitemapXml('https://rendprop.com', {tours:[{slug,address,allow_indexing:true,published_at:'2026-10-26T12:00:00Z'}],next_cursor:null});
check(sitemap.includes(`https://rendprop.com${oldPath}`) && !sitemap.includes(`https://rendprop.com${path}</loc>`),
  'Sitemap keeps the safe token path until the index can give bulk uniqueness proof');
const venueSitemap = propertySitemapXml('https://rendprop.com', {tours:[{slug,address,space_type:'venue',allow_indexing:true,published_at:'2026-10-26T12:00:00Z'}],next_cursor:null});
check(venueSitemap.includes(`https://rendprop.com/f/${slug}</loc>`) && !venueSitemap.includes(oldPath),
  'Non-real-estate sitemap rows name the same /f canonical as their page');
response = await get('/property/' + slug);
check(response.status === 200 && (await response.text()).includes(`rel="canonical" href="https://rendprop.com${path}"`),
  'Opaque-only property alias stays open');
response = await get('/u/' + descriptor + '/' + slug);
check(response.status === 200 && !(await response.text()).includes('rel="canonical"'),
  'MLS route remains separate, unbranded and noncanonical');

unique = false;
response = await get('/f/' + slug);
check(response.status === 200 && (await response.text()).includes(`rel="canonical" href="https://rendprop.com${oldPath}"`),
  'Address collision retains the existing unambiguous address-plus-ID canonical');
response = await get('/f/' + slug + '/share-link');
link = await response.json();
check(response.status === 200 && link.url === 'https://rendprop.com' + oldPath && link.address_only === false,
  'Share lookup retains the stable token URL for a duplicate address');
response = await get(path);
check(response.status === 404,'Address-only collision cannot select one of two properties');
response = await get(oldPath);
check(response.status === 200,'Address-plus-ID remains available during collision');

unique = true; claimed = false;
response = await get('/f/' + slug + '/share-link');
link = await response.json();
check(response.status === 200 && link.url === 'https://rendprop.com' + oldPath && link.address_only === false,
  'A new unique publication stays on its suffix link before the dated Worker flag is enabled');
response = await get(path);
check(response.status === 404,'A new unique publication never acquires a temporary bare address');
claimed = true;

unique = true; withdrawn = true;
response = await get(path);
check(response.status === 404 && !response.headers.has('location'),'Withdrawn publication is not disclosed by a stale resolver');
response = await get('/f/' + slug + '/share-link');
check(response.status === 404,'Withdrawn publication yields no verified share URL');
withdrawn = false;
tour = {...tour, listing:{...tour.listing, address:'123 Other St'}};
response = await get(path);
check(response.status === 200 && (await response.text()).includes(`rel="canonical" href="https://rendprop.com${propertyAddressPath(slug,'123 Other St')}"`),
  'A reserved old bare link keeps its original publication after an address correction');
tour = {...tour, listing:{...tour.listing, address}};

aliasTour = {...tour, slug:descriptor, listing:{...tour.listing,address:'123 Other St'}};
response = await get('/f/' + slug);
check(response.status === 200 && (await response.text()).includes(`rel="canonical" href="https://rendprop.com${oldPath}"`),
  'A published legacy slug equal to the descriptor prevents address-only canonical collision');
response = await get(path);
check(response.status === 200 && (await response.text()).includes('123 Other St'),
  'Existing one-segment publication slug keeps its prior identity');
aliasTour = null;

resolverFailure = true;
response = await get(path);
check(response.status === 503 && response.headers.get('Cache-Control') === 'no-store',
  'Direct address resolver outage is a retryable 503, not a false 404');
response = await get('/property/' + longDescriptor);
check(response.status === 503 && response.headers.get('Cache-Control') === 'no-store',
  'Long address descriptor takes the same retryable outage path');
response = await get('/f/' + slug);
check(response.status === 200 && (await response.text()).includes(`rel="canonical" href="https://rendprop.com${oldPath}"`),
  'Opaque slug keeps its existing canonical during resolver outage');
response = await get('/f/' + slug + '/share-link');
link = await response.json();
check(response.status === 200 && link.url === 'https://rendprop.com' + oldPath && link.address_only === false,
  'Share lookup keeps the stable token URL during resolver outage');
resolverFailure = false;
resolverMissing = true;
response = await get(path);
check(response.status === 404,'Truly missing resolver address remains 404');
resolverMissing = false;
malformedResolver = true;
response = await get(path);
check(response.status === 503 && response.headers.get('Cache-Control') === 'no-store',
  'Malformed resolver proof is an unavailable authority, not a missing address');
malformedResolver = false;

descriptorReads = 0; aliasFailureOnRead = 2;
response = await get(path);
check(response.status === 503 && response.headers.get('Cache-Control') === 'no-store',
  'Direct address alias-check outage is a retryable 503');
descriptorReads = 0; aliasFailureOnRead = 1;
response = await get('/f/' + slug);
check(response.status === 200 && (await response.text()).includes(`rel="canonical" href="https://rendprop.com${oldPath}"`),
  'Opaque slug retains old canonical during alias-check outage');
aliasFailureOnRead = null;
descriptorReads = 0; aliasMalformedOnRead = 2;
response = await get(path);
check(response.status === 503 && response.headers.get('Cache-Control') === 'no-store',
  'Malformed alias proof is unavailable, not a verified collision');
aliasMalformedOnRead = null;

const missingSecret = {...env,ADDRESS_LOOKUP_SECRET:undefined};
response = await get(path,missingSecret);
check(response.status === 503 && response.headers.get('Cache-Control') === 'no-store',
  'Enabled address route with missing private credential fails closed as unavailable');
response = await get('/f/' + slug,missingSecret);
check(response.status === 200 && (await response.text()).includes(`rel="canonical" href="https://rendprop.com${oldPath}"`),
  'Opaque route keeps its old canonical when private lookup credential is absent');

const disabled = {...env, ADDRESS_ONLY_CANONICAL:undefined};
const before = resolverCalls;
response = await get('/f/' + slug,disabled);
check(response.status === 200 && (await response.text()).includes(`rel="canonical" href="https://rendprop.com${oldPath}"`),
  'Disabled feature preserves deployed canonical');
check(resolverCalls === before,'Disabled feature makes no address resolver call');
response = await get('/f/' + slug + '/share-link',disabled);
link = await response.json();
check(response.status === 200 && link.url === 'https://rendprop.com' + oldPath && link.address_only === false,
  'Disabled feature returns the existing token URL');
check(resolverCalls === before,'Disabled share lookup makes no address resolver call');

tour = {...tour, space_type:'venue'};
response = await get('/f/' + slug + '/share-link',env);
link = await response.json();
check(response.status === 200 && link.url === 'https://rendprop.com/f/' + slug && link.address_only === false,
  'Non-real-estate tours keep their published /f link');
tour = {...tour, space_type:'real_estate'};

tour = {...tour, listing:{...tour.listing, details:{...tour.listing.details,allow_indexing:false}}};
claimed = false;
response = await get('/f/' + slug,env);
check(response.status === 200 && response.headers.get('X-Robots-Tag') === 'noindex, nofollow'
  && (await response.text()).includes(`rel="canonical" href="https://rendprop.com${oldPath}"`),
  'Noindex property keeps its token canonical even when its address is unique');
response = await get(path,env);
check(response.status === 404,'A guessed address cannot enumerate a noindex property without its slug');
response = await get('/f/' + slug + '/share-link',env);
link = await response.json();
check(response.status === 200 && link.url === 'https://rendprop.com' + oldPath && link.address_only === false,
  'Share lookup for a noindex property returns only its already-public token path');
claimed = true;
response = await get(path,env);
check(response.status === 200 && response.headers.get('X-Robots-Tag') === 'noindex, nofollow'
  && (await response.text()).includes(`rel="canonical" href="https://rendprop.com${path}"`),
  'An existing reservation keeps its exact noindex property at the old bare URL without indexing it');
response = await get('/f/' + slug + '/share-link',env);
link = await response.json();
check(response.status === 200 && link.url === 'https://rendprop.com' + path && link.address_only === true,
  'Reserved noindex publication keeps the owner\'s existing bare share link');
response = await get(oldPath,env);
check(response.status === 308 && response.headers.get('location') === 'https://rendprop.com' + path,
  'Reserved publication legacy token path redirects only after current proof');
const soldSlug = 'sold_archive_123';
const soldTour = {...tour,slug:soldSlug,listing:{...tour.listing,details:{...tour.listing.details,allow_indexing:false}}};
const oldFetch = globalThis.fetch;
globalThis.fetch = async (url,init) => url === base + '/tours/' + soldSlug
  ? Response.json(soldTour) : oldFetch(url,init);
response = await get('/f/' + soldSlug,env);
check(response.status === 200 && response.headers.get('X-Robots-Tag') === 'noindex, nofollow'
  && (await response.text()).includes(`rel="canonical" href="https://rendprop.com${propertyAddressPath(soldSlug,address)}"`),
  'Older sold publication retains its own token URL and noindex archive identity');
response = await get(propertyAddressPath(soldSlug,address),env);
check(response.status === 200 && (await response.text()).includes(soldSlug),
  'Older sold address-plus-token URL never serves the claimed publication');
globalThis.fetch = oldFetch;
claimed = false;
console.log(`Address-only canonical: ${checks} closed Worker/renderer checks passed; resolver is staged, no live calls.`);
