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
const results=[];
const warnings=[];
// The zone already prepends its managed crawler policy to robots.txt. Pin the
// observed platform prefix, never strip arbitrary differences from app assets.
// This permits verification of the origin tail without pretending that the
// combined Allow/Disallow policy proves crawl blocking. Noindex is independent.
const managedRobotsPrefixSha='842b34303164ead41bccb7c05d1707422e98d108753b397b6dcc19683eb02101';
for(const file of files){
  const pathname=file==='index.html'?'/':`/${file}`;
  const response=await fetch(origin+pathname,{redirect:'error',cache:'no-store',signal:AbortSignal.timeout(15_000)});
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
const fallback=await fetch(origin+'/workspace',{redirect:'error',signal:AbortSignal.timeout(15_000)});
assert.equal(fallback.status,200);
assert.equal(sha(Buffer.from(await fallback.arrayBuffer())),sha(await readFile(path.join(root,'index.html'))),'SPA deep route must serve this same entry');
console.log(JSON.stringify({gate:'studio-deployed-application-bytes',origin,readAt:new Date().toISOString(),status:'passed',files:results,spaFallback:true,accountLoginVerified:false,robotsCrawlBlockingVerified:false,warnings},null,2));
