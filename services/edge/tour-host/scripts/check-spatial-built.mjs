// Execute the exact self-contained browser ESM returned by a Wrangler build.
// Neither source transpilation nor injecting missing names is release evidence.
import assert from 'node:assert/strict';
import vm from 'node:vm';
import { mkdtempSync, readFileSync, writeFileSync, renameSync, symlinkSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { spawnSync } from 'node:child_process';
import { buildSpatialBrowser, checkSpatialBrowser, GENERATED_JSON, GENERATED_TS } from './build-spatial-browser.mjs';
import { sha, boundedFile, sourceSnapshot, copyFixture, buildEnvironment, runBuildCommand,
  emitWorker, loadEmittedWorker, browserAsset, linkModule } from './spatial-built-fixture.mjs';

const ROOT=resolve(dirname(fileURLToPath(import.meta.url)),'..');
const args=process.argv.slice(2), mode=args[0]||'--build';
assert(['--build','--self-test','--negative-control','--asset-file','--asset-url'].includes(mode),'Unknown mode');
assert.equal(args.length,mode.startsWith('--asset-')?2:(args.length?1:0),'Unexpected arguments');
const evidence=mkdtempSync(join(tmpdir(),'rendprop-spatial-built-'));
const receipt={mode,observed_at:new Date().toISOString(),evidence,assertions:0,cases:[],
  scope:'Actual emitted browser decoder/SOG contracts. Synthetic envelope only; no WebGL, phone, room quality or deployment proof.'};
const check=(value,message)=>{receipt.assertions++;assert.ok(value,message);};
const persist=()=>writeFileSync(join(evidence,'receipt.json'),JSON.stringify(receipt,null,2)+'\n');

function fixture() {
  return {schema_version:1,scene_id:'11111111-1111-4111-8111-111111111111',artifact_revision:'22222222-2222-4222-8222-222222222222',
    format:'sog',bytes:4,sha256:'a'.repeat(64),gaussian_count:2048,bounds:{min:[-5,-2,-5],max:[5,4,5]},
    floor_y:-1.6,eye_height:1.6,floor_source:'capture_estimate',navigation_bounds_source:'capture_estimate',
    initial_camera:{position:[0,0,3],target:[0,0,0]},rooms:[{id:'kitchen',label:'Synthetic kitchen',position:[0,0,3],target:[0,0,0]}],
    provenance:'synthetic',privacy_reviewed:true};
}
// Envelope only, not a renderable room. Chromium uses a separately converted SOG.
function sogFixture() {
  const meta={version:2,count:2048,means:{files:['means_l.webp','means_u.webp']},quats:{files:['quats.webp']},scales:{files:['scales.webp']},sh0:{files:['sh0.webp']}};
  const webp=Buffer.alloc(26);webp.write('RIFF');webp.writeUInt32LE(18,4);webp.write('WEBPVP8L',8);
  webp.writeUInt32LE(5,16);webp[20]=0x2f;webp.writeUInt32LE(63|(31<<14),21);
  const files=[['meta.json',Buffer.from(JSON.stringify(meta))],...['means_l.webp','means_u.webp','quats.webp','scales.webp','sh0.webp'].map(n=>[n,webp])];
  const chunks=[],directory=[];let offset=0;
  for(const [name,body] of files){const n=Buffer.from(name),local=Buffer.alloc(30),central=Buffer.alloc(46);
    local.writeUInt32LE(0x04034b50);local.writeUInt32LE(body.length,18);local.writeUInt32LE(body.length,22);local.writeUInt16LE(n.length,26);
    central.writeUInt32LE(0x02014b50);central.writeUInt32LE(body.length,20);central.writeUInt32LE(body.length,24);central.writeUInt16LE(n.length,28);central.writeUInt32LE(offset,42);
    chunks.push(local,n,body);directory.push(central,n);offset+=30+n.length+body.length;}
  const index=Buffer.concat(directory),end=Buffer.alloc(22);end.writeUInt32LE(0x06054b50);end.writeUInt16LE(files.length,8);
  end.writeUInt16LE(files.length,10);end.writeUInt32LE(index.length,12);end.writeUInt32LE(offset,16);
  return Buffer.concat([...chunks,index,end]);
}
async function verifyBrowser(source,name) {
  const before=receipt.assertions, context=vm.createContext({URL,TextDecoder,TextEncoder});
  // Public exports survive identifier minification. Appending lexical exports
  // would alter the shipped bytes and fail on correctly renamed local symbols.
  const browser=await linkModule(source,context,name);
  check(typeof browser.namespace.mountSpatial==='function','Real mountSpatial export exists');
  context.decode=browser.namespace.decodeSpatialManifest;context.inspect=browser.namespace.inspectSpatialSog;
  const decode=input=>{context.input=input;return vm.runInContext('decode(input)',context,{timeout:1000});};
  const inspect=(input,count)=>{context.bytes=Array.from(input);context.count=count;return vm.runInContext('inspect(new Uint8Array(bytes),count)',context,{timeout:1000});};
  const good=fixture();
  check(decode(good).rooms[0].label==='Synthetic kitchen','Valid emitted manifest decoder executes');
  check(decode({...good,provenance:'captured',privacy_reviewed:false}).privacy_reviewed===false,'Private captured manifest preserved');
  check(!('output_key' in decode({...good,output_key:'synthetic-private-key'})),'Unknown private fields stripped');
  for(const mutate of [m=>m.bytes=-1,m=>m.bytes=NaN,m=>m.bytes=33554433,m=>m.gaussian_count=500001,
    m=>m.gaussian_count=1.5,m=>m.bounds.min=[0,0],m=>m.bounds.max=[Infinity,4,5],m=>m.floor_y=5,
    m=>m.eye_height=0,m=>m.initial_camera.position=[6,0,0],m=>m.rooms.push({...m.rooms[0]}),
    m=>m.scene_id='../a',m=>m.format='ply',m=>m.privacy_reviewed='true',m=>m.sha256='bad']){
    const bad=structuredClone(good);mutate(bad);receipt.assertions++;
    assert.throws(()=>decode(bad),e=>e.name==='Error'&&e.message==='Invalid spatial scene manifest');}
  const envelope=sogFixture();
  check(inspect(envelope,2048).texturePixels===10240,'Valid emitted SOG guard executes inner helpers');
  for(const [bytes,count] of [[envelope,0],[envelope,500001],[envelope,2049],[envelope.subarray(0,21),2048],[Buffer.from(envelope).fill(0,0,4),2048]]){
    receipt.assertions++;assert.throws(()=>inspect(bytes,count),e=>e.name==='Error'&&e.message==='Room package is not a supported bounded SOG');}
  check(receipt.assertions-before===25,'All 25 expected browser contract assertions executed');
  receipt.cases.push({name,assertions:26,contract_assertions:25,count_control_assertions:1,browser_bytes:Buffer.byteLength(source),browser_sha256:sha(source)});
}
function setOptions(root,keepNames,minify) {
  const file=join(root,'wrangler.toml');let config=readFileSync(file,'utf8');
  for(const [name,value] of [['keep_names',keepNames],['minify',minify]]){
    const pattern=new RegExp('^'+name+'\\s*=.*$','m');config=pattern.test(config)?config.replace(pattern,name+' = '+value):name+' = '+value+'\n'+config;}
  writeFileSync(file,config);
}
async function emittedAsset(root,name) {
  const run=emitWorker(root,join(evidence,name)), worker=await loadEmittedWorker(run.path), asset=await browserAsset(worker);
  receipt.cases.push({name:'build-'+name,...run,config_sha256:sha(readFileSync(join(root,'wrangler.toml'))),browser_sha256:asset.sha256});
  return asset.source;
}
async function detachedHelper() {
  const root=copyFixture(ROOT,join(evidence,'detached-helper-source'));
  setOptions(root,false,false);
  const entry=join(root,'src/browser/spatial-viewer.js'),original=readFileSync(entry,'utf8');
  const needle='export { decodeSpatialManifest, inspectSpatialSog };';
  assert.equal(original.split(needle).length,2,'Missing-helper mutant must match actual entrypoint once');
  // Reintroduce the old serialization mistake. The imported validator compiles,
  // but its detached function cannot resolve its real imported numeric helper.
  const changed=original.replace(needle,'const detachedManifest = (0, eval)("(" + decodeSpatialManifest.toString() + ")");\nexport { detachedManifest as decodeSpatialManifest, inspectSpatialSog };');
  writeFileSync(entry,changed);
  const generation=runBuildCommand(root,[join(root,'scripts/build-spatial-browser.mjs'),'--write'],join(evidence,'detached-generation.log'));
  assert.equal(generation.exit,0,'Missing-helper fixture must generate successfully');
  receipt.cases.push({name:'detached-generation',...generation});
  await verifyBrowser(await emittedAsset(root,'detached-helper-build'),'detached-helper');
}
async function verifyCliEntrypoint(canonical) {
  const root=copyFixture(ROOT,join(evidence,'cli-source'));
  const alias=join(evidence,'cli-source-alias');symlinkSync(root,alias,'dir');
  // Neither exit 0 nor an existing generated file proves the command ran.
  // Remove only this owned fixture's outputs, then invoke via a path whose
  // argv spelling differs from Node's canonical import.meta.url on every OS.
  for(const path of [GENERATED_TS,GENERATED_JSON])renameSync(join(root,path),join(root,path+'.held'));
  const generation=runBuildCommand(root,[join(alias,'scripts/build-spatial-browser.mjs'),'--write'],join(evidence,'cli-alias-write.log'));
  check(generation.exit===0&&!generation.error,'Builder --write through symlink exits successfully');
  const written=JSON.parse(readFileSync(generation.log,'utf8'));
  check(written.status==='passed'&&written.mode==='--write'&&written.browser_sha256===canonical.metadata.browser_sha256,'Builder entrypoint actually reported generation');
  const generated=await checkSpatialBrowser({root});
  check(generated.generatedTypeScript===canonical.generatedTypeScript&&generated.generatedMetadata===canonical.generatedMetadata,'Previously missing fixture outputs were actually recreated exactly');
  const checked=runBuildCommand(root,[join(alias,'scripts/build-spatial-browser.mjs'),'--check'],join(evidence,'cli-alias-check.log'));
  const report=JSON.parse(readFileSync(checked.log,'utf8'));
  check(checked.exit===0&&!checked.error&&report.status==='passed'&&report.mode==='--check','Builder --check through symlink actually executed');
  receipt.cases.push({name:'cli-source-alias',...generation,check:checked,generated_browser_sha256:generated.metadata.browser_sha256});
}
async function rejectedGeneration(kind) {
  const root=copyFixture(ROOT,join(evidence,kind+'-source')),file=join(root,kind==='missing-generated-ts'?GENERATED_TS:GENERATED_JSON);
  if(kind.startsWith('missing-generated')) renameSync(file,file+'.held');
  else if(kind==='stale-helper'||kind==='stale-builder'){
    const target=join(root,kind==='stale-helper'?'src/spatial-values.ts':'scripts/build-spatial-browser.mjs');
    writeFileSync(target,readFileSync(target,'utf8')+'\n// Deliberate source freshness control; generated bytes were not refreshed.\n');
  }else if(kind==='stale-lock'){
    const path=join(root,'package-lock.json'),lock=JSON.parse(readFileSync(path,'utf8'));
    lock.synthetic_gate_control='changed-without-regeneration';writeFileSync(path,JSON.stringify(lock,null,2)+'\n');
  }else {const metadata=JSON.parse(readFileSync(file,'utf8'));metadata.browser_sha256='0'.repeat(64);writeFileSync(file,JSON.stringify(metadata)+'\n');}
  const marker=kind.startsWith('missing-generated')?'Missing generated browser artifact':'Stale generated browser artifact';
  const checkRun=runBuildCommand(root,[join(root,'scripts/build-spatial-browser.mjs'),'--check'],join(evidence,kind+'-check.log'));
  check(checkRun.exit===1&&!checkRun.error,'Generated '+kind+' check fails');
  check(readFileSync(checkRun.log,'utf8').includes(marker),'Generated failure is specifically '+marker);
  let failure;try{emitWorker(root,join(evidence,kind+'-dry-run'));}catch(error){failure=error;}
  check(failure?.name==='AssertionError'&&failure.message.startsWith('Wrangler dry-run failed;'),'Actual dry-run refuses '+kind);
  check(readFileSync(join(evidence,kind+'-dry-run/build.log'),'utf8').includes(marker),'Dry-run fails at generated check, not unrelated environment');
  receipt.cases.push({name:kind,...checkRun,dry_run_rejected:true});
}
async function unmatchedControl() {
  const file=join(evidence,'unmatched-browser.js');writeFileSync(file,'throw new Error("UNMATCHED_SCRIPT_EXECUTED");\n');
  const run=spawnSync(process.execPath,['--experimental-vm-modules',fileURLToPath(import.meta.url),'--asset-file',file],
    {cwd:ROOT,encoding:'utf8',timeout:120000,maxBuffer:2*1024*1024,env:buildEnvironment()});
  writeFileSync(join(evidence,'unmatched-control.log'),(run.stdout||'')+(run.stderr||''));
  check(!run.error&&run.status===1,'Unmatched code must fail');
  const line=(run.stdout||'').trim().split('\n').findLast(line=>line.startsWith('{'));
  const rejected=JSON.parse(line||'{}');
  check(rejected.failure?.name==='AssertionError'&&rejected.failure.message===
    'Unverified browser asset differs from this source build; supplied JavaScript was not executed','Unmatched code fails before execution');
  receipt.unmatched_control=rejected;
}
async function publicAsset(url) {
  assert.equal(url,'https://rendprop.com/spatial-viewer.js','Only exact public viewer URL is supported');
  const response=await fetch(url,{redirect:'error',signal:AbortSignal.timeout(15000),headers:{'User-Agent':'Rendprop-Built-Viewer-Check/2.0'}});
  check(response.status===200,'Public asset HTTP status');check(/javascript/.test(response.headers.get('Content-Type')||''),'Public asset content type');
  const chunks=[];let length=0;for await(const bytes of response.body){length+=bytes.length;assert(length<=512000,'Public asset exceeds bound');chunks.push(bytes);}
  receipt.url=response.url;receipt.http_status=response.status;return Buffer.concat(chunks).toString();
}
try {
  receipt.inputs=sourceSnapshot(ROOT);
  const canonical=await checkSpatialBrowser({root:ROOT});receipt.canonical_metadata=canonical.metadata;
  if(mode==='--negative-control') await detachedHelper();
  else {
    const expected=await emittedAsset(ROOT,'canonical');
    check(sha(expected)===canonical.metadata.browser_sha256,'Actual Worker route exactly matches canonical browser build');
    let source=expected;
    if(mode.startsWith('--asset-')){
      source=mode==='--asset-url'?await publicAsset(args[1]):boundedFile(resolve(args[1]),512000).toString();
      receipt.browser_sha256=sha(source);receipt.expected_browser_sha256=sha(expected);
      // VM deadlines are not isolation. Refuse unreviewed file/remote JavaScript
      // before evaluation, even if a caller supplies a seemingly safe URL.
      check(sha(source)===sha(expected),'Unverified browser asset differs from this source build; supplied JavaScript was not executed');
    }
    writeFileSync(join(evidence,'spatial-viewer.js'),source);await verifyBrowser(source,'canonical-browser');
    if(mode==='--self-test'){
      for(const keepNames of [false,true])for(const minify of [false,true]){
        const name='worker-names-'+keepNames+'-minify-'+minify;
        const root=copyFixture(ROOT,join(evidence,name+'-source'));setOptions(root,keepNames,minify);
        const asset=await emittedAsset(root,name);check(sha(asset)===sha(expected),'Worker options cannot change browser bytes: '+name);
        await verifyBrowser(asset,name);
        const built=await buildSpatialBrowser({root:ROOT,keepNames,minify});
        check(built.metadata.inputs.some(input=>input.path==='src/spatial-values.ts'),'Real shared helper included in browser dependency graph');
        await verifyBrowser(built.source,'browser-names-'+keepNames+'-minify-'+minify);receipt.cases.at(-1).metadata=built.metadata;
      }
      await verifyCliEntrypoint(canonical);
      let failure;try{await detachedHelper();}catch(error){failure=error;}
      receipt.detached_failure=failure?{name:failure.name,message:failure.message}:null;
      check(failure?.name==='ReferenceError'&&failure.message==='isBoundedSpatialNumber is not defined',
        'Detached actual decoder must fail specifically at its imported helper');
      const negatives=['missing-generated-json','missing-generated-ts','stale-generated','stale-helper','stale-builder','stale-lock'];
      for(const name of negatives)await rejectedGeneration(name);
      await unmatchedControl();
      const expectedCases=['canonical-browser',...['worker','browser'].flatMap(target=>[false,true].flatMap(names=>[false,true].map(minify=>target+'-names-'+names+'-minify-'+minify)))];
      check(JSON.stringify(receipt.cases.filter(entry=>entry.contract_assertions===25).map(entry=>entry.name).sort())===JSON.stringify(expectedCases.sort()),
        'Exactly nine complete browser contract suites ran');
      check(JSON.stringify(receipt.cases.filter(entry=>entry.dry_run_rejected).map(entry=>entry.name).sort())===JSON.stringify(negatives.sort()),
        'All six generated/source freshness controls ran against actual dry-run');
      check(!!receipt.detached_failure&&receipt.unmatched_control?.status==='failed'&&receipt.cases.some(entry=>entry.name==='cli-source-alias'),'Runtime helper, unmatched-byte and real CLI execution controls ran');
    }
  }
  check(JSON.stringify(sourceSnapshot(ROOT))===JSON.stringify(receipt.inputs),'Reviewed source hashes unchanged throughout gate');
  receipt.status='passed';persist();console.log(JSON.stringify(receipt));
}catch(error){receipt.status='failed';receipt.failure={name:error.name,message:error.message};persist();console.log(JSON.stringify(receipt));process.exitCode=1;}
