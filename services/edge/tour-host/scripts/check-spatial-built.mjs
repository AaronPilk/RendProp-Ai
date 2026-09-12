// Check the browser bytes emitted by Wrangler, not TypeScript's transpileModule.
// A function that is self-contained in TS can acquire a closure over esbuild's
// __name helper. Function.toString() then drops that enclosing helper at runtime.
import assert from 'node:assert/strict';
import vm from 'node:vm';
import { createHash } from 'node:crypto';
import { spawnSync } from 'node:child_process';
import { mkdtempSync, readFileSync, writeFileSync, statSync, symlinkSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const HERE = dirname(fileURLToPath(import.meta.url)), ROOT = resolve(HERE, '..');
const args = process.argv.slice(2);
const mode = args[0] || '--build';
assert(['--build', '--self-test', '--negative-control', '--asset-file', '--asset-url'].includes(mode), 'Unknown mode');
assert(args.length === (mode.startsWith('--asset-') ? 2 : (args.length ? 1 : 0)), 'Unexpected arguments');
assert.equal(typeof vm.SourceTextModule, 'function', 'Run Node with --experimental-vm-modules');
const evidence = mkdtempSync(join(tmpdir(), 'rendprop-spatial-built-'));
const receipt = { mode, observed_at: new Date().toISOString(), evidence, assertions: 0,
  scope: 'built browser decoder/SOG contract; synthetic envelope only; no WebGL, phone FPS, auth, media, or deployment proof' };
const sha = bytes => createHash('sha256').update(bytes).digest('hex');
const check = (condition, message) => { receipt.assertions++; assert.ok(condition, message); };
const boundedFile = (path, max) => {
  assert(statSync(path).size <= max, 'Input file exceeds bound');
  const data = readFileSync(path); assert(data.length <= max, 'Input grew beyond bound'); return data;
};
const persist = () => writeFileSync(join(evidence, 'receipt.json'), JSON.stringify(receipt, null, 2) + '\n');
async function deadline(promise) {
  let timer;
  try {
    return await Promise.race([promise,new Promise((_,reject)=>{
      timer=setTimeout(()=>reject(new Error('Module promise exceeded 1500ms')),1500);
    })]);
  } finally { clearTimeout(timer); }
}

function fixture() {
  return { schema_version:1, scene_id:'11111111-1111-4111-8111-111111111111',
    artifact_revision:'22222222-2222-4222-8222-222222222222', format:'sog', bytes:4,
    sha256:'a'.repeat(64), gaussian_count:2048, bounds:{min:[-5,-2,-5],max:[5,4,5]},
    floor_y:-1.6, eye_height:1.6, floor_source:'capture_estimate', navigation_bounds_source:'capture_estimate',
    initial_camera:{position:[0,0,3],target:[0,0,0]}, rooms:[{id:'kitchen',label:'Synthetic kitchen',position:[0,0,3],target:[0,0,0]}],
    provenance:'synthetic', privacy_reviewed:true };
}

// Envelope fixture only: these dimension-bearing bytes are NOT decodable room
// textures and must never be offered as a successful browser-render test.
function sogFixture() {
  const meta = {version:2,count:2048,means:{files:['means_l.webp','means_u.webp']},quats:{files:['quats.webp']},scales:{files:['scales.webp']},sh0:{files:['sh0.webp']}};
  const webp = Buffer.alloc(26); webp.write('RIFF'); webp.writeUInt32LE(18,4);
  webp.write('WEBPVP8L',8); webp.writeUInt32LE(5,16); webp[20]=0x2f; webp.writeUInt32LE(63|(31<<14),21);
  const files=[['meta.json',Buffer.from(JSON.stringify(meta))],...['means_l.webp','means_u.webp','quats.webp','scales.webp','sh0.webp'].map(n=>[n,webp])];
  const chunks=[], directory=[]; let offset=0;
  for (const [name,body] of files) {
    const n=Buffer.from(name), local=Buffer.alloc(30), central=Buffer.alloc(46);
    local.writeUInt32LE(0x04034b50); local.writeUInt32LE(body.length,18); local.writeUInt32LE(body.length,22); local.writeUInt16LE(n.length,26);
    central.writeUInt32LE(0x02014b50); central.writeUInt32LE(body.length,20); central.writeUInt32LE(body.length,24); central.writeUInt16LE(n.length,28); central.writeUInt32LE(offset,42);
    chunks.push(local,n,body); directory.push(central,n); offset+=30+n.length+body.length;
  }
  const index=Buffer.concat(directory), end=Buffer.alloc(22); end.writeUInt32LE(0x06054b50);
  end.writeUInt16LE(files.length,8); end.writeUInt16LE(files.length,10); end.writeUInt32LE(index.length,12); end.writeUInt32LE(offset,16);
  return Buffer.concat([...chunks,index,end]);
}

async function linkModule(source, context, identifier) {
  const module = new vm.SourceTextModule(source, {context, identifier});
  await module.link(() => { throw new Error('Unexpected module import; no dependency/network fallback'); });
  await deadline(module.evaluate({timeout:1000}));
  return module;
}

async function emittedAsset(broken = false) {
  const wrangler = join(ROOT,'node_modules/wrangler/bin/wrangler.js');
  let config=join(ROOT,'wrangler.toml');
  receipt.config_sha256=sha(readFileSync(config));
  receipt.lock_sha256=sha(readFileSync(join(ROOT,'package-lock.json')));
  receipt.wrangler_version=JSON.parse(readFileSync(resolve(wrangler,'../../package.json'),'utf8')).version;
  if (broken) {
    // Keep the actual config and sources, changing only the known regressing
    // esbuild option. The isolated copy must never modify the working config.
    const text=readFileSync(config,'utf8');
    const changed=/^keep_names\s*=/m.test(text) ? text.replace(/^keep_names\s*=.*$/m,'keep_names = true') : 'keep_names = true\n'+text;
    config=join(evidence,'wrangler.toml'); writeFileSync(config,changed);
    symlinkSync(join(ROOT,'src'),join(evidence,'src'),'dir');
    symlinkSync(join(ROOT,'public'),join(evidence,'public'),'dir');
    receipt.negative_config_sha256=sha(changed);
  }
  const out=join(evidence,'bundle');
  const command=[wrangler,'deploy','--dry-run','--config',config,'--outdir',out];
  receipt.build_command=[process.execPath,...command];
  const build=spawnSync(process.execPath,command,{cwd:ROOT,encoding:'utf8',timeout:90000,maxBuffer:2*1024*1024,
    env:{...process.env,WRANGLER_SEND_METRICS:'false'}});
  writeFileSync(join(evidence,'build.log'),(build.stdout||'')+(build.stderr||''));
  check(!build.error && build.status===0,'Wrangler dry-run failed; inspect build.log');
  const workerBytes=boundedFile(join(out,'index.js'),8*1024*1024);
  receipt.worker_sha256=sha(workerBytes);
  let network=0;
  const context=vm.createContext({Request,Response,Headers,URL,TextEncoder,TextDecoder,AbortController,
    setTimeout,clearTimeout,console,fetch:()=>{network++;throw new Error('Unexpected Worker network');}});
  const worker=await linkModule(workerBytes.toString(),context,'emitted-worker');
  context.worker=worker.namespace.default;
  context.request=new Request('https://rendprop.com/spatial-viewer.js');
  const response=await deadline(vm.runInContext('worker.fetch(request, {}, {waitUntil(){throw new Error("Unexpected waitUntil")}})',context,{timeout:1000}));
  check(response.status===200,'Built Worker browser route returns 200');
  check(/javascript/.test(response.headers.get('Content-Type')||''),'Built route emits JavaScript');
  check(response.headers.get('Cache-Control')==='no-store','Built browser module is no-store');
  check(network===0,'Built asset route has no backend dependency');
  const source=await response.text(); check(Buffer.byteLength(source)<=512000,'Built browser module bound');
  receipt.http_status=response.status;
  return source;
}

async function publicAsset(url) {
  // No generic remote evaluator, cookies, auth headers, redirects or room URLs.
  assert.equal(url,'https://rendprop.com/spatial-viewer.js','Only exact public viewer URL is supported');
  const response=await fetch(url,{redirect:'error',signal:AbortSignal.timeout(15000),headers:{'User-Agent':'Rendprop-Built-Viewer-Check/1.0'}});
  receipt.url=response.url; receipt.http_status=response.status;
  check(response.status===200,'Public asset HTTP status');
  check(/javascript/.test(response.headers.get('Content-Type')||''),'Public asset content type');
  const chunks=[];let size=0;
  for await (const chunk of response.body) { size+=chunk.length; assert(size<=512000,'Public asset exceeds bound'); chunks.push(chunk); }
  return Buffer.concat(chunks).toString();
}

async function verifyBrowser(source) {
  const before=receipt.assertions;
  receipt.browser_bytes=Buffer.byteLength(source); receipt.browser_sha256=sha(source);
  writeFileSync(join(evidence,'spatial-viewer.js'),source);
  // Export only references to the actual emitted lexical bindings. Never add
  // __name (or any bundler helper) here: isolation is the regression test.
  const context=vm.createContext({URL,TextDecoder,TextEncoder});
  const browser=await linkModule(source+'\nexport {decodeSpatialManifest,inspectSpatialSog};',context,'emitted-browser');
  check(typeof browser.namespace.mountSpatial==='function','Real mountSpatial export exists');
  context.decode=browser.namespace.decodeSpatialManifest;
  context.inspect=browser.namespace.inspectSpatialSog;
  const decode=value=>{context.input=value;return vm.runInContext('decode(input)',context,{timeout:1000});};
  const inspect=(bytes,count)=>{context.bytes=Array.from(bytes);context.count=count;return vm.runInContext('inspect(new Uint8Array(bytes),count)',context,{timeout:1000});};
  const good=fixture();
  check(decode(good).rooms[0].label==='Synthetic kitchen','Valid emitted manifest decoder executes');
  check(decode({...good,provenance:'captured',privacy_reviewed:false}).privacy_reviewed===false,'Private captured manifest preserved');
  check(!('output_key' in decode({...good,output_key:'synthetic-private-key'})),'Unknown private fields stripped');
  for (const mutate of [m=>m.bytes=-1,m=>m.bytes=NaN,m=>m.bytes=33554433,m=>m.gaussian_count=500001,
    m=>m.gaussian_count=1.5,m=>m.bounds.min=[0,0],m=>m.bounds.max=[Infinity,4,5],m=>m.floor_y=5,
    m=>m.eye_height=0,m=>m.initial_camera.position=[6,0,0],m=>m.rooms.push({...m.rooms[0]}),
    m=>m.scene_id='../a',m=>m.format='ply',m=>m.privacy_reviewed='true',m=>m.sha256='bad']) {
    const bad=structuredClone(good);mutate(bad);receipt.assertions++;
    assert.throws(()=>decode(bad),e=>e.name==='Error' && e.message==='Invalid spatial scene manifest');
  }
  const envelope=sogFixture();
  check(inspect(envelope,2048).texturePixels===10240,'Valid emitted SOG guard executes inner helpers');
  for (const [bytes,count] of [[envelope,0],[envelope,500001],[envelope,2049],[envelope.subarray(0,21),2048],
    [Buffer.from(envelope).fill(0,0,4),2048]]) {
    receipt.assertions++;
    assert.throws(()=>inspect(bytes,count),e=>e.name==='Error' && e.message==='Room package is not a supported bounded SOG');
  }
  check(receipt.assertions-before===25,'All expected browser contract assertions executed');
}

try {
  let source;
  if (mode.startsWith('--asset-')) {
    source=mode==='--asset-url' ? await publicAsset(args[1]) : boundedFile(resolve(args[1]),512000).toString();
    receipt.browser_bytes=Buffer.byteLength(source); receipt.browser_sha256=sha(source);
    // Node's VM is an execution timeout, NOT an isolation boundary. Never run
    // arbitrary downloaded/file-provided JS with this process's authority.
    // A deployment check must first match this reviewed source's actual build;
    // drift fails closed before any supplied code is evaluated.
    const expected=await emittedAsset();
    receipt.expected_browser_sha256=sha(expected);
    check(receipt.browser_sha256===receipt.expected_browser_sha256,
      'Unverified browser asset differs from this source build; supplied JavaScript was not executed');
  } else {
    source=await emittedAsset(mode==='--negative-control');
  }
  await verifyBrowser(source);
  if (mode==='--self-test') {
    const child=spawnSync(process.execPath,['--experimental-vm-modules',fileURLToPath(import.meta.url),'--negative-control'],
      {cwd:ROOT,encoding:'utf8',timeout:120000,maxBuffer:2*1024*1024});
    writeFileSync(join(evidence,'negative-control.log'),(child.stdout||'')+(child.stderr||''));
    check(!child.error && child.status===1,'Deliberately broken config must exit 1');
    const line=(child.stdout||'').trim().split('\n').findLast(line=>line.startsWith('{'));
    const negative=JSON.parse(line||'{}');
    check(negative.failure?.name==='ReferenceError' && negative.failure.message==='__name is not defined',
      'Negative control must fail at missing helper, not an unrelated build/environment error');
    receipt.negative_control=negative;
    const unmatched=join(evidence,'unmatched-browser.js');
    writeFileSync(unmatched,'throw new Error("UNMATCHED_SCRIPT_EXECUTED");\n');
    const mismatch=spawnSync(process.execPath,['--experimental-vm-modules',fileURLToPath(import.meta.url),'--asset-file',unmatched],
      {cwd:ROOT,encoding:'utf8',timeout:120000,maxBuffer:2*1024*1024});
    writeFileSync(join(evidence,'unmatched-control.log'),(mismatch.stdout||'')+(mismatch.stderr||''));
    check(!mismatch.error && mismatch.status===1,'Unmatched file must be rejected');
    const mismatchLine=(mismatch.stdout||'').trim().split('\n').findLast(line=>line.startsWith('{'));
    const rejected=JSON.parse(mismatchLine||'{}');
    check(rejected.failure?.name==='AssertionError' &&
      rejected.failure.message==='Unverified browser asset differs from this source build; supplied JavaScript was not executed',
      'Unmatched code must fail at byte identity, before its throwing body executes');
    receipt.unmatched_control=rejected;
  }
  receipt.status='passed'; persist(); console.log(JSON.stringify(receipt));
} catch(error) {
  receipt.status='failed'; receipt.failure={name:error.name,message:error.message}; persist();
  console.log(JSON.stringify(receipt)); process.exitCode=1;
}
