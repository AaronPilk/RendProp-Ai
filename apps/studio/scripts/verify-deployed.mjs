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
  assert.equal(sha(served),sha(local),`Deployed ${pathname} differs from the verified build`);
  results.push({path:pathname,bytes:served.length,sha256:sha(served),status:response.status});
}
const fallback=await fetch(origin+'/workspace',{redirect:'error',signal:AbortSignal.timeout(15_000)});
assert.equal(fallback.status,200);
assert.equal(sha(Buffer.from(await fallback.arrayBuffer())),sha(await readFile(path.join(root,'index.html'))),'SPA deep route must serve this same entry');
console.log(JSON.stringify({gate:'studio-deployed-bytes',origin,readAt:new Date().toISOString(),status:'passed',files:results,spaFallback:true,accountLoginVerified:false},null,2));
