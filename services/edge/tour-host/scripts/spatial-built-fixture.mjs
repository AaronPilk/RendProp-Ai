// Shared evidence plumbing. Only local, reviewed build output reaches the VM;
// this VM supplies time limits, not an arbitrary-code security boundary.
import assert from 'node:assert/strict';
import vm from 'node:vm';
import { createHash, webcrypto } from 'node:crypto';
import { cpSync, mkdirSync, readFileSync, readdirSync, statSync, symlinkSync, writeFileSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { spawnSync } from 'node:child_process';

export const sha = bytes => createHash('sha256').update(bytes).digest('hex');
export function boundedFile(path, max = 8 * 1024 * 1024) {
  assert(statSync(path).isFile() && statSync(path).size <= max, 'Input file exceeds bound');
  const bytes = readFileSync(path);
  assert(bytes.length <= max, 'Input grew beyond bound');
  return bytes;
}
export function sourceSnapshot(root) {
  const inputs = [];
  function walk(path) {
    for (const entry of readdirSync(join(root, path), {withFileTypes:true})) {
      const relative = join(path, entry.name);
      if (entry.isDirectory()) walk(relative);
      else if (entry.isFile()) inputs.push(relative);
      else throw new Error('Source fixtures must not contain symlinks');
    }
  }
  walk('src'); walk('scripts'); walk('public');
  inputs.push('package.json', 'package-lock.json', 'wrangler.toml', 'tsconfig.json');
  return inputs.sort().map(path => ({path, sha256:sha(boundedFile(join(root,path),64*1024*1024))}));
}
export function copyFixture(root, destination) {
  mkdirSync(destination, {recursive:true});
  // Generated outputs and scripts belong to this copy. In particular, never
  // let a matrix build write through a src/ symlink into the reviewed tree.
  for (const folder of ['src','scripts','public']) cpSync(join(root,folder),join(destination,folder),{recursive:true});
  for (const file of ['package.json','package-lock.json','wrangler.toml','tsconfig.json'])
    cpSync(join(root,file),join(destination,file));
  symlinkSync(resolve(root,'node_modules'),join(destination,'node_modules'),'dir');
  return destination;
}
export const buildEnvironment = () => ({PATH:dirname(process.execPath)+':'+process.env.PATH, HOME:process.env.HOME,
  WRANGLER_SEND_METRICS:'false', CI:'true', NO_COLOR:'1'});
export function runBuildCommand(root, command, logPath) {
  const run = spawnSync(process.execPath,command,{cwd:root,encoding:'utf8',timeout:90000,
    maxBuffer:2*1024*1024,env:buildEnvironment()});
  writeFileSync(logPath,(run.stdout||'')+(run.stderr||''));
  return {command:[process.execPath,...command],exit:run.status,error:run.error?.message,log:logPath};
}
export function emitWorker(root, evidence) {
  mkdirSync(evidence,{recursive:true});
  const command=[join(root,'node_modules/wrangler/bin/wrangler.js'),'deploy','--dry-run',
    '--config',join(root,'wrangler.toml'),'--outdir',join(evidence,'bundle')];
  const result=runBuildCommand(root,command,join(evidence,'build.log'));
  assert(!result.error && result.exit===0,'Wrangler dry-run failed; inspect '+result.log);
  const path=join(evidence,'bundle/index.js'), bytes=boundedFile(path);
  const mapBytes=boundedFile(path+'.map',16*1024*1024), sourceMap=JSON.parse(mapBytes);
  assert(Array.isArray(sourceMap.sources)&&sourceMap.sources.length>0,'Emitted Worker source-map inventory missing');
  assert(sourceMap.sources.every(source=>!source.includes('node_modules')&&!/(^|[/\\])(miniflare|sharp|ws)([/\\]|$)/.test(source)),
    'Unexpected dependency in emitted Worker inventory');
  assert(sourceMap.sources.every(source=>source.includes('/src/')||source.startsWith('src/')||source.includes('wrangler/templates/')),
    'Unexpected non-host input in emitted Worker inventory');
  return {...result,path,sha256:sha(bytes),source_map_sha256:sha(mapBytes),source_map_inputs:sourceMap.sources};
}
export async function deadline(promise, milliseconds=1500) {
  let timer;
  try { return await Promise.race([promise,new Promise((_,reject)=>{
    timer=setTimeout(()=>reject(new Error('Fixture operation exceeded '+milliseconds+'ms')),milliseconds);
  })]); } finally { clearTimeout(timer); }
}
export async function linkModule(source,context,identifier) {
  assert.equal(typeof vm.SourceTextModule,'function','Run Node with --experimental-vm-modules');
  const module=new vm.SourceTextModule(source,{context,identifier});
  await module.link(()=>{throw new Error('Unexpected module import; no dependency/network fallback');});
  await deadline(module.evaluate({timeout:1000}));
  return module;
}
export async function loadEmittedWorker(path, fetchFixture=()=>{throw new Error('Unexpected Worker network');}) {
  const bytes=boundedFile(path);
  const context=vm.createContext({Request,Response,Headers,URL,URLSearchParams,TextEncoder,TextDecoder,
    // Fetch Response bodies above are host-realm typed arrays. Use that same
    // platform realm for instanceof checks; do not alter production guards.
    AbortController,AbortSignal,ReadableStream,TransformStream,Uint8Array,crypto:webcrypto,
    setTimeout,clearTimeout,console,fetch:fetchFixture});
  const module=await linkModule(bytes.toString(),context,'emitted-worker');
  context.worker=module.namespace.default;
  assert.equal(typeof context.worker?.fetch,'function','Emitted Worker exports fetch');
  return {sha256:sha(bytes),async fetch(request,env={}) {
    context.fixtureRequest=request;context.fixtureEnv=env;
    return await deadline(vm.runInContext('worker.fetch(fixtureRequest,fixtureEnv,{waitUntil(){throw new Error("Unexpected waitUntil")}})',
      context,{timeout:1000}),10000);
  }};
}
export async function browserAsset(worker) {
  const response=await worker.fetch(new Request('https://rendprop.com/spatial-viewer.js'));
  assert.equal(response.status,200,'Built Worker browser route returns 200');
  assert.match(response.headers.get('Content-Type')||'',/javascript/,'Built route emits JavaScript');
  assert.equal(response.headers.get('Cache-Control'),'no-store','Built browser module is no-store');
  const source=await response.text();assert(Buffer.byteLength(source)<=512000,'Built browser module bound');
  return {source,sha256:sha(source),status:response.status,headers:Object.fromEntries(response.headers)};
}
