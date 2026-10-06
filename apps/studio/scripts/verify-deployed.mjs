import assert from 'node:assert/strict';
import {readFile,readdir} from 'node:fs/promises';
import {createHash} from 'node:crypto';
import path from 'node:path';

// Read-back proof of this exact local build. A successful upload log is not
// evidence that the custom domain serves the intended bytes or response policy.
const origin='https://studio.rendprop.com';
const root=path.resolve(import.meta.dirname,'../dist');
const sha=bytes=>createHash('sha256').update(bytes).digest('hex');
const files=['index.html','robots.txt','rendprop-mark.svg',...(await readdir(path.join(root,'assets'))).map(name=>`assets/${name}`)];
assert.equal(files.length,31,'Expected exact entry, robots, mark and 28 build assets');
let requests=0;
const deadline=Date.now()+120_000;
async function request(pathname){
  assert.ok(Date.now()<deadline,'Whole readback deadline');
  assert.ok(++requests<=35,'Exact readback request budget');
  assert.ok(pathname.startsWith('/')&&!pathname.startsWith('//'),'Same-origin paths only');
  return fetch(origin+pathname,{redirect:'manual',cache:'no-store',signal:AbortSignal.timeout(Math.min(15_000,deadline-Date.now()))});
}
const results=[];
const warnings=[];
// The zone already prepends its managed crawler policy to robots.txt. Pin the
// observed platform prefix, never strip arbitrary differences from app assets.
// This permits verification of the origin tail without pretending that the
// combined Allow/Disallow policy proves crawl blocking. Noindex is independent.
const managedRobotsPrefixSha='842b34303164ead41bccb7c05d1707422e98d108753b397b6dcc19683eb02101';
for(const file of files){
  const pathname=file==='index.html'?'/':`/${file}`;
  const response=await request(pathname);
  assert.equal(response.status,200,`${pathname} must serve successfully`);
  assert.match(response.headers.get('x-robots-tag')??'',/noindex/);
  assert.match(response.headers.get('cache-control')??'',/no-store/);
  assert.match(response.headers.get('cache-control')??'',/no-transform/);
  assert.equal(response.headers.get('x-content-type-options'),'nosniff');
  assert.equal(response.headers.get('referrer-policy'),'no-referrer');
  const csp=response.headers.get('content-security-policy')??'';
  assert.ok(csp.includes("script-src 'self'")&&csp.includes("frame-ancestors 'none'"),'Response CSP missing');
  const local=await readFile(path.join(root,file));
  const served=Buffer.from(await response.arrayBuffer());
  let transformation=null;
  if(file==='robots.txt'&&sha(served)!==sha(local)){
    assert.ok(served.length>local.length&&served.subarray(-local.length).equals(local),'Managed robots response must retain the exact origin file');
    const prefix=served.subarray(0,-local.length);
    assert.equal(sha(prefix),managedRobotsPrefixSha,'Unrecognized managed robots policy change: inspect and resolve before updating the pin');
    transformation={kind:'known-cloudflare-managed-robots-prefix',prefixSha256:sha(prefix),originSha256:sha(local)};
    warnings.push('Cloudflare managed robots prepends wildcard Allow, which can conflict with origin Disallow. Crawl blocking is NOT verified. X-Robots-Tag and HTML meta noindex remain enabled. No zone crawler setting was changed.');
  }else{
    assert.equal(sha(served),sha(local),`Deployed ${pathname} differs from the verified build`);
  }
  results.push({path:pathname,bytes:served.length,sha256:sha(served),status:response.status,transformation});
}
// Only this configured OAuth route is canonicalized. Never follow arbitrary
// redirects or treat missing routes/assets as the application entry.
const query='?rendprop_route_probe=1';
const callback=await request('/auth/callback'+query);
assert.equal(callback.status,307,'Configured callback must use the exact canonical redirect');
assert.equal(callback.headers.get('location'),'/'+query,'Callback must preserve the same-origin root and exact query');
assert.equal((await callback.arrayBuffer()).byteLength,0,'Canonical redirect must have no application body');
const entry=await request('/'+query);
assert.equal(entry.status,200,'Canonical callback destination must serve successfully');
assert.equal(sha(Buffer.from(await entry.arrayBuffer())),sha(await readFile(path.join(root,'index.html'))),'Callback destination must serve the same entry');
assert.match(entry.headers.get('cache-control')??'',/no-store/);
assert.match(entry.headers.get('x-robots-tag')??'',/noindex/);
const missing=[];
for(const pathname of ['/workspace','/assets/__rendprop_verify_missing__.js']){
  const response=await request(pathname);
  assert.equal(response.status,404,`${pathname} must retain the configured missing-route policy`);
  missing.push({path:pathname,status:response.status});
}
assert.equal(requests,35);
assert.ok(Date.now()<deadline,'Readback must finish before the whole deadline');
console.log(JSON.stringify({gate:'studio-deployed-application-bytes-exact-routing',origin,readAt:new Date().toISOString(),status:'passed',files:results,spaFallback:false,oauthCallbackConfiguredRewrite:true,oauthCallbackCanonicalRedirect307:true,oauthCallbackQueryPreserved:true,unknownRoutes404:true,missing,GETRequests:requests,accountLoginVerified:false,robotsCrawlBlockingVerified:false,warnings},null,2));
