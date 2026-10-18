import assert from 'node:assert/strict';
import {lstat,readFile,readdir} from 'node:fs/promises';
import {createHash} from 'node:crypto';
import path from 'node:path';

// Read-back proof of this exact local build. A successful upload log is not
// evidence that the custom domain serves the intended bytes or response policy.
// --local-only derives and prints the same inventory without any request.
const args=process.argv.slice(2);
assert.ok(args.length<=1&&args.every(arg=>arg==='--local-only'),'Only --local-only is supported');
const origin='https://studio.rendprop.com';
const root=path.resolve(import.meta.dirname,'../dist');
const sha=bytes=>createHash('sha256').update(bytes).digest('hex');

// The exact inventory comes from this build's own Vite manifest, never from a
// hand-kept count. Everything index.html can load (static and dynamic imports,
// their CSS and emitted assets) is read back, and dist/assets must hold exactly
// those regular files. Manifest keys are identifiers (a dependency key may begin
// with ../); only output paths are constrained. All of this runs before any GET.
const fixedFiles=['index.html','robots.txt','rendprop-mark.svg'];
const routeProbes=['/auth/callback?rendprop_route_probe=1','/?rendprop_route_probe=1','/workspace','/assets/__rendprop_verify_missing__.js'];
const assetPath=/^assets\/[A-Za-z0-9_.-]+\.(?:js|css)$/;
async function realEntry(relative,folder=false){
  const info=await lstat(path.join(root,relative));
  assert.ok(folder?info.isDirectory():info.isFile(),`${relative} must be a real ${folder?'folder':'file'}, not a link`);
}
for(const file of fixedFiles)await realEntry(file);
await realEntry('.vite',true);
await realEntry('.vite/manifest.json');
await realEntry('assets',true);
const manifestBytes=await readFile(path.join(root,'.vite/manifest.json'));
let manifest;
try{manifest=JSON.parse(manifestBytes.toString('utf8'));}catch{assert.fail('Build manifest is not valid JSON');}
assert.ok(manifest&&typeof manifest==='object'&&!Array.isArray(manifest),'Build manifest must be an object');
const names=(key,field)=>{
  const value=manifest[key][field]??[];
  assert.ok(Array.isArray(value)&&value.every(name=>typeof name==='string'),`Manifest ${key} ${field} must list names`);
  return value;
};
const outputs=key=>[manifest[key].file,...names(key,'css'),...names(key,'assets')];
for(const key of Object.keys(manifest)){
  assert.ok(manifest[key]&&typeof manifest[key]==='object'&&!Array.isArray(manifest[key]),`Manifest ${key} must be an object`);
  for(const file of outputs(key))assert.ok(typeof file==='string'&&assetPath.test(file),`Manifest ${key} names an unsafe or unsupported output file`);
  for(const dependency of [...names(key,'imports'),...names(key,'dynamicImports')])assert.ok(Object.hasOwn(manifest,dependency),`Manifest ${key} imports missing ${dependency}`);
}
assert.deepEqual(Object.keys(manifest).filter(key=>manifest[key].isEntry===true),['index.html'],'index.html must be the only build entry');
const loadable=new Set(),reached=new Set(),pending=['index.html'];
while(pending.length){
  const key=pending.pop();
  if(reached.has(key))continue;
  reached.add(key);
  for(const file of outputs(key))loadable.add(file);
  pending.push(...names(key,'imports'),...names(key,'dynamicImports'));
}
for(const key of Object.keys(manifest))for(const file of outputs(key))assert.ok(loadable.has(file),`Manifest ${key} emits ${file}, which index.html can never load`);
const present=(await readdir(path.join(root,'assets'),{withFileTypes:true})).map(item=>{
  assert.ok(item.isFile(),`assets/${item.name} must be a regular file, not a link or folder`);
  return `assets/${item.name}`;
});
const missingAssets=[...loadable].filter(file=>!present.includes(file)).sort();
const unmanifestedAssets=present.filter(file=>!loadable.has(file)).sort();
assert.ok(!missingAssets.length&&!unmanifestedAssets.length,`dist/assets differs from the manifest closure (missing: ${missingAssets.join(', ')||'none'}; unmanifested: ${unmanifestedAssets.join(', ')||'none'})`);
const files=[...fixedFiles,...[...loadable].sort()];
const local=new Map();
for(const file of files)local.set(file,await readFile(path.join(root,file)));
const htmlFiles=[...local.get('index.html').toString('utf8').matchAll(/(?:src|href)="\/([^"#]+)"/g)].map(match=>match[1]);
assert.ok(htmlFiles.includes(manifest['index.html'].file),'index.html must load the manifest entry');
for(const file of htmlFiles)assert.ok(files.includes(file),`index.html loads /${file}, which is outside the verified inventory`);
const budget=files.length+routeProbes.length;
const inventory={manifestSha256:sha(manifestBytes),manifestEntries:Object.keys(manifest).length,loadableEntries:reached.size,assets:loadable.size,files:files.length,routeProbes:routeProbes.length,GETBudget:budget,
  sha256:sha(JSON.stringify(files.map(file=>[file,sha(local.get(file))])))};
if(args.includes('--local-only'))console.log(JSON.stringify({gate:'studio-release-inventory',status:'passed',network:false,inventory,files:files.map(file=>({path:file,bytes:local.get(file).length,sha256:sha(local.get(file))}))},null,2));
else await readBack();

async function readBack(){
  let requests=0;
  const requested=[];
  const deadline=Date.now()+120_000;
  async function request(pathname){
    assert.ok(Date.now()<deadline,'Whole readback deadline');
    assert.ok(++requests<=budget,'Exact readback request budget');
    assert.ok(pathname.startsWith('/')&&!pathname.startsWith('//'),'Same-origin paths only');
    requested.push(pathname);
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
    const verified=local.get(file);
    const served=Buffer.from(await response.arrayBuffer());
    let transformation=null;
    if(file==='robots.txt'&&sha(served)!==sha(verified)){
      assert.ok(served.length>verified.length&&served.subarray(-verified.length).equals(verified),'Managed robots response must retain the exact origin file');
      const prefix=served.subarray(0,-verified.length);
      assert.equal(sha(prefix),managedRobotsPrefixSha,'Unrecognized managed robots policy change: inspect and resolve before updating the pin');
      transformation={kind:'known-cloudflare-managed-robots-prefix',prefixSha256:sha(prefix),originSha256:sha(verified)};
      warnings.push('Cloudflare managed robots prepends wildcard Allow, which can conflict with origin Disallow. Crawl blocking is NOT verified. X-Robots-Tag and HTML meta noindex remain enabled. No zone crawler setting was changed.');
    }else{
      assert.equal(sha(served),sha(verified),`Deployed ${pathname} differs from the verified build`);
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
  assert.equal(sha(Buffer.from(await entry.arrayBuffer())),sha(local.get('index.html')),'Callback destination must serve the same entry');
  assert.match(entry.headers.get('cache-control')??'',/no-store/);
  assert.match(entry.headers.get('x-robots-tag')??'',/noindex/);
  const missing=[];
  for(const pathname of ['/workspace','/assets/__rendprop_verify_missing__.js']){
    const response=await request(pathname);
    assert.equal(response.status,404,`${pathname} must retain the configured missing-route policy`);
    missing.push({path:pathname,status:response.status});
  }
  // Every inventory file exactly once, then exactly the four route probes.
  assert.equal(requests,budget);
  assert.deepEqual(requested,[...files.map(file=>file==='index.html'?'/':`/${file}`),...routeProbes],'Readback must request each inventory file once, then only the route probes');
  assert.ok(Date.now()<deadline,'Readback must finish before the whole deadline');
  console.log(JSON.stringify({gate:'studio-deployed-application-bytes-exact-routing',origin,readAt:new Date().toISOString(),status:'passed',inventory,files:results,spaFallback:false,oauthCallbackConfiguredRewrite:true,oauthCallbackCanonicalRedirect307:true,oauthCallbackQueryPreserved:true,unknownRoutes404:true,missing,GETRequests:requests,accountLoginVerified:false,robotsCrawlBlockingVerified:false,warnings},null,2));
}
