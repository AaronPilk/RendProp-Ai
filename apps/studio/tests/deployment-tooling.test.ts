import assert from "node:assert/strict";
import test from "node:test";
import { mkdtemp, mkdir, writeFile, readFile, rm, symlink } from "node:fs/promises";
import path from "node:path";
import { tmpdir } from "node:os";
import { spawnSync } from "node:child_process";
// @ts-ignore Release helpers are plain ESM, executed without tsx in production.
import { parseDeploymentArgs, selectedPolicy, verifyLivePolicy, verifyDeploymentBefore, NEW_FUNCTION_POLICIES, verifyModernServiceTransition, MODERN_SERVICE_FUNCTIONS, sourceImports, sourceClosure, stageDeployment, verifyStagedSnapshot, verifyDownloadedSources } from "../scripts/backend-deploy-lib.mjs";
// @ts-ignore Release helpers are plain ESM, executed without tsx in production.
import { connectedProductionConfig, verifyConnectedBundle, manifestClosure, releaseAssetGroups, PROXY_ENTRY } from "../scripts/dist-policy.mjs";
async function fixture(run: (root: string) => Promise<void>) {
  const root = await mkdtemp(path.join(tmpdir(), "rendprop-deploy-test-"));
  try { await run(root); } finally { await rm(root, { recursive: true, force: true }); }
}
async function file(root: string, name: string, text: string) { const target = path.join(root, name); await mkdir(path.dirname(target), { recursive: true }); await writeFile(target, text); }

test("explicit safe selection only; no default all, prune, JWT override or duplicate names", () => {
  assert.deepEqual(parseDeploymentArgs(["--functions", "studio,portfolio"]), { functions: ["studio", "portfolio"], run: false });
  assert.deepEqual(parseDeploymentArgs(["--run", "--functions", "studio"]), { functions: ["studio"], run: true });
  for (const args of [[], ["--run"], ["--functions"], ["--functions", "../studio"], ["--functions", "studio,studio"], ["--functions", "studio", "--prune"], ["--functions", "studio", "--no-verify-jwt"]]) assert.throws(() => parseDeploymentArgs(args));
});
test("explicit modern service transition accepts only the five scoped policies and preserves other JWT guards", () => {
  const functions = [...MODERN_SERVICE_FUNCTIONS, "studio"];
  assert.equal(parseDeploymentArgs(["--functions", functions.join(","), "--modern-service-transport"]).modernServiceTransport, true);
  assert.throws(() => parseDeploymentArgs(["--functions", "studio", "--modern-service-transport"]));
  const policy = Object.fromEntries(functions.map((name) => [name, name === "studio"]));
  const inventory = functions.map((name) => ({ name, verify_jwt: true, status: "ACTIVE", import_map: false }));
  assert.equal(verifyModernServiceTransition(inventory, policy).me.verifyJwt, true);
  assert.equal(verifyModernServiceTransition(inventory.map((row) => ({ ...row, verify_jwt: policy[row.name] })), policy).me.verifyJwt, false);
  assert.throws(() => verifyModernServiceTransition(inventory.map((row) => row.name === "studio" ? { ...row, verify_jwt: false } : row), policy), /drift/);
  assert.throws(() => verifyModernServiceTransition(inventory, { ...policy, me: true }));
  assert.throws(() => verifyModernServiceTransition(inventory.filter((row) => row.name !== "uploads"), policy));
});
test("mixed JWT preserved; live drift, missing/duplicate functions and undeclared policy fail closed", () => {
  const policy = selectedPolicy({ studio: true, portfolio: false }, ["studio", "portfolio"]);
  const inventory = [{ name: "studio", verify_jwt: true, status: "ACTIVE", import_map: false }, { slug: "portfolio", verify_jwt: false, status: "ACTIVE", import_map: false }];
  assert.equal(verifyLivePolicy(inventory, policy).portfolio.verifyJwt, false);
  assert.throws(() => verifyLivePolicy([{ ...inventory[0], verify_jwt: false }, inventory[1]], policy), /drift/);
  assert.throws(() => verifyLivePolicy([inventory[0]], policy), /exactly one/);
  assert.throws(() => verifyLivePolicy([...inventory, inventory[0]], policy), /exactly one/);
  assert.throws(() => selectedPolicy({ studio: true }, ["new-function"]), /No declared/);
  assert.throws(() => selectedPolicy({ studio: "true" }, ["studio"]));
});
test("first deployment requires explicit reviewed endpoint names; policy mismatch or absent ordinary functions still refuse",()=>{
  assert.deepEqual(NEW_FUNCTION_POLICIES,{"property-sites":true,"property-video-plan":true,"property-video-jobs":true,"property-video-worker":false,"photo-quality-worker":false,"photo-quality-review":true,"ai-photo-v2":true,"photo-feedback":true});
  assert.deepEqual(verifyDeploymentBefore([],{"photo-feedback":true},["photo-feedback"]),{"photo-feedback":{create:true,verifyJwt:true}});
  assert.throws(()=>verifyDeploymentBefore([],{"photo-feedback":false},["photo-feedback"]),/reviewed JWT/);
  assert.deepEqual(verifyDeploymentBefore([],{"photo-quality-worker":false},["photo-quality-worker"]),{"photo-quality-worker":{create:true,verifyJwt:false}});
  assert.deepEqual(verifyDeploymentBefore([],{"photo-quality-review":true},["photo-quality-review"]),{"photo-quality-review":{create:true,verifyJwt:true}});
  assert.throws(()=>verifyDeploymentBefore([],{"photo-quality-review":false},["photo-quality-review"]),/reviewed JWT/);
  assert.deepEqual(verifyDeploymentBefore([],{"ai-photo-v2":true},["ai-photo-v2"]),{"ai-photo-v2":{create:true,verifyJwt:true}});
  assert.throws(()=>verifyDeploymentBefore([],{"ai-photo-v2":false},["ai-photo-v2"]),/reviewed JWT/);
  assert.throws(()=>verifyDeploymentBefore([],{"photo-quality-worker":true},["photo-quality-worker"]),/reviewed JWT/);
  assert.deepEqual(verifyDeploymentBefore([],{"property-video-worker":false},["property-video-worker"]),{"property-video-worker":{create:true,verifyJwt:false}});
  assert.throws(()=>verifyDeploymentBefore([],{"property-video-worker":true},["property-video-worker"]),/reviewed JWT/);
  assert.deepEqual(parseDeploymentArgs(["--functions","studio,property-sites,property-video-plan","--create-new","property-sites,property-video-plan"]),{functions:["studio","property-sites","property-video-plan"],run:false,createNew:["property-sites","property-video-plan"]});
  for(const args of [["--functions","studio","--create-new","studio"],["--functions","property-sites","--create-new","property-video-plan"],["--functions","property-sites","--create-new"],["--functions","property-sites","--create-new","property-sites,property-sites"],["--functions","property-sites","--create-new","unreviewed-function"]])assert.throws(()=>parseDeploymentArgs(args));
  const policy={studio:true,"property-sites":true,"property-video-plan":true},studio={name:"studio",verify_jwt:true,status:"ACTIVE",import_map:false};
  const before=verifyDeploymentBefore([studio],policy,["property-sites","property-video-plan"]);assert.deepEqual(before["property-sites"],{create:true,verifyJwt:true});
  assert.throws(()=>verifyDeploymentBefore([],policy,["property-sites","property-video-plan"]),/exactly one/);
  assert.throws(()=>verifyDeploymentBefore([studio],policy),/exactly one/);
  assert.throws(()=>verifyDeploymentBefore([studio],{...policy,"property-sites":false},["property-sites","property-video-plan"]),/reviewed JWT/);
  const live=[studio,{name:"property-sites",verify_jwt:true,status:"ACTIVE",import_map:false},{name:"property-video-plan",verify_jwt:true,status:"ACTIVE",import_map:false}];
  assert.equal(verifyDeploymentBefore(live,policy,["property-sites","property-video-plan"])["property-sites"].verifyJwt,true);
  for(const delta of [{verify_jwt:false},{status:"FAILED"},{import_map:true}])assert.throws(()=>verifyDeploymentBefore([studio,{...live[1],...delta},live[2]],policy,["property-sites","property-video-plan"]));
  assert.throws(()=>verifyDeploymentBefore([...live,live[1]],policy,["property-sites","property-video-plan"]),/exactly one/);
  assert.throws(()=>verifyLivePolicy([studio],policy),/exactly one/,"final verification never permits missing new endpoints");
});
test("AST sees side effects, reexports, dynamic literals and type imports, not prose", () => {
  const imports = sourceImports(`// import './comment.ts';
const s = "import('./not-code.ts')";
import './side.ts'; export {x} from '../other/export.ts';
export type {T} from './types.ts'; import {type U} from './types2.ts';
const load = () => import(\`./dynamic.ts\`); type V = import('./types3.ts').V;`, "index.ts");
  assert.deepEqual(imports, [{ specifier: "./side.ts", runtime: true }, { specifier: "../other/export.ts", runtime: true }, { specifier: "./types.ts", runtime: false }, { specifier: "./types2.ts", runtime: false }, { specifier: "./dynamic.ts", runtime: true }, { specifier: "./types3.ts", runtime: false }]);
  for (const text of ["import(target)", "import(`./${part}.ts`)", "require(target)", "import './bad.ts"]) assert.throws(() => sourceImports(text, "index.ts"));
});
test("transitive cross-function closure includes types, excludes tests, stages exact policy and detects tampering", async () => fixture(async (root) => {
  const functions = path.join(root, "functions");
  await file(functions, "studio/index.ts", "import '../shared/side.ts'; import type {T} from './types.ts'; export {x} from '../other/x.ts';");
  await file(functions, "shared/side.ts", "export const side = import('../other/dynamic.ts');");
  await file(functions, "other/x.ts", "import 'https://example.com/library.ts'; export const x=1;");
  await file(functions, "other/dynamic.ts", "export default 1;");
  await file(functions, "studio/types.ts", "export type T = string;");
  await file(functions, "studio/unrelated.test.ts", "throw new Error('never staged');");
  const closure = await sourceClosure(functions, ["studio"]);
  assert.equal(closure.files.size, 5); assert(!closure.runtimeByFunction.studio.includes("studio/types.ts"));
  const stage = path.join(root, "stage");
  const manifest = await stageDeployment(stage, closure, { studio: true, portfolio: false });
  const config = await readFile(path.join(stage, "supabase/config.toml"), "utf8");
  assert.match(config, /\[functions.studio\]\nverify_jwt = true/); assert.match(config, /\[functions.portfolio\]\nverify_jwt = false/);
  await verifyStagedSnapshot(stage, manifest);
  await file(stage, "supabase/functions/studio/unexpected.ts", "export {};");
  await assert.rejects(verifyStagedSnapshot(stage, manifest), /closure changed/);
}));
test("path and symlink escape, aliases, missing dependencies and implicit config fail before stage", async () => fixture(async (root) => {
  const functions = path.join(root, "functions"); await file(root, "outside.ts", "export const secret=1;");
  for (const source of ["import '../../outside.ts';", "import '/absolute.ts';", "import 'alias';", "import './missing.ts';", "import './%2e%2e/secret.ts';"]) {
    await file(functions, "studio/index.ts", source); await assert.rejects(sourceClosure(functions, ["studio"]));
  }
  await symlink(path.join(root, "outside.ts"), path.join(functions, "studio/link.ts"));
  await file(functions, "studio/index.ts", "import './link.ts';"); await assert.rejects(sourceClosure(functions, ["studio"]), /Symlink/);
  await file(functions, "studio/index.ts", "export {};"); await file(functions, "studio/deno.json", '{"imports":{}}');
  await assert.rejects(sourceClosure(functions, ["studio"]), /implicit dependency config/);
}));
test("readback verifies nested sources, rejects missing/mismatched/extra bytes and records type erasure", async () => fixture(async (root) => {
  const source = path.join(root, "source");
  await file(source, "studio/index.ts", "import '../other/nested.ts'; import type {T} from './types.ts';");
  await file(source, "other/nested.ts", "export const nested=1;"); await file(source, "studio/types.ts", "export type T=string;");
  const closure = await sourceClosure(source, ["studio"]); const manifest = await stageDeployment(path.join(root, "stage"), closure, { studio: true });
  const readback = path.join(root, "readback");
  for (const name of closure.runtimeByFunction.studio) await file(readback, `supabase/functions/${name}`, closure.files.get(name).toString());
  const result = await verifyDownloadedSources(readback, "studio", manifest);
  assert.equal(result.matchedSourceFiles, 2); assert.deepEqual(result.stagedTypeOnlyNotInRuntime, ["studio/types.ts"]);
  await file(readback, "supabase/functions/other/nested.ts", "export const nested=2;"); await assert.rejects(verifyDownloadedSources(readback, "studio", manifest), /mismatch/);
  await rm(path.join(readback, "supabase/functions/other/nested.ts")); await assert.rejects(verifyDownloadedSources(readback, "studio", manifest), /omitted runtime/);
}));
test("real Studio default dry run stages declared source with no CLI/network available", async () => fixture(async (root) => {
  const result = spawnSync(process.execPath, [path.resolve(import.meta.dirname, "../scripts/deploy-backend.mjs"), "--functions", "studio"], { encoding: "utf8", env: { ...process.env, PATH: root } });
  assert.equal(result.status, 0, result.stderr); const receipt = JSON.parse(result.stdout);
  try {
    assert.equal(receipt.mode, "dry-run"); assert.deepEqual(receipt.functions, ["studio"]); assert(receipt.stagedSourceFiles > 30);
    const stored = JSON.parse(await readFile(receipt.receipt, "utf8"));
    assert(!Object.keys(stored.manifest.hashes).some((name) => name.includes(".test."))); assert.equal(stored.before, undefined);
  } finally { await rm(receipt.stage, { recursive: true, force: true }); }
}));
const key = "sb_publishable_public_example_1234567890", url = "https://test-project.supabase.co";
const values = { VITE_SUPABASE_URL: url, VITE_SUPABASE_PUBLISHABLE_KEY: key };
test("connected release requires exact public values and forbids private or unexpected fields", () => {
  assert.deepEqual(connectedProductionConfig(`VITE_SUPABASE_URL=${url}\nVITE_SUPABASE_PUBLISHABLE_KEY=${key}\n`), values);
  assert.deepEqual(connectedProductionConfig("", values), values);
  assert.throws(() => connectedProductionConfig("", {}), /requires/);
  assert.throws(() => connectedProductionConfig("SERVER_SECRET=private", values), /only the two/);
  assert.throws(() => connectedProductionConfig("", { ...values, VITE_PRIVATE_KEY: "private" }), /Unexpected/);
  assert.throws(() => connectedProductionConfig("", { ...values, VITE_SUPABASE_PUBLISHABLE_KEY: "sb_secret_abcdefghijklmnopqrstuv" }), /forbidden/);
  verifyConnectedBundle([`const env=${JSON.stringify(values)}`], values);
  assert.throws(() => verifyConnectedBundle([`const env=${JSON.stringify({ ...values, VITE_SUPABASE_PUBLISHABLE_KEY: `${key}suffix` })}`], values), /differs from configured/);
  const jwt = `header.${Buffer.from(JSON.stringify({ role: "service_role" })).toString("base64url")}.signature`;
  assert.throws(() => verifyConnectedBundle([`const env=${JSON.stringify(values)},token=${JSON.stringify(jwt)}`], values), /service-role/);
});
test("workflow budgets follow static imports/CSS, reject missing entries and keep proxy on demand", () => {
  const manifest = {
    "index.html": { file: "assets/index.js", css: ["assets/index.css"], isEntry: true },
    "src/features/projects/Projects.tsx": { file: "assets/projects.js", imports: ["shared"], isDynamicEntry: true },
    "src/features/sync/PropertyReels.tsx": { file: "assets/reels.js", imports: ["shared"], isDynamicEntry: true },
    "src/features/sync/MakeVideo.tsx": { file: "assets/make-video.js", imports: ["shared"], isDynamicEntry: true },
    shared: { file: "assets/shared.js", css: ["assets/shared.css"], imports: ["index.html"] },
    [PROXY_ENTRY]: { file: "assets/proxy.js", imports: ["shared"], isDynamicEntry: true },
  };
  const groups = releaseAssetGroups(manifest);
  assert.deepEqual(groups.initial, ["assets/index.css", "assets/index.js"]); assert.equal(groups.create.length, 7); assert.equal(groups.withLargeVideo.length, 8);
  assert.throws(() => manifestClosure(manifest, ["renamed-or-missing"]), /Missing required/);
  const missingSimple = {...manifest}; delete missingSimple["src/features/sync/MakeVideo.tsx"];
  assert.throws(() => releaseAssetGroups(missingSimple), /Missing required/);
  assert.throws(() => releaseAssetGroups({ ...manifest, shared: { ...manifest.shared, imports: [PROXY_ENTRY] } }), /outside the Create/);
  assert.throws(() => manifestClosure({ bad: { file: "../secret.js" } }, ["bad"]), /Unsafe/);
});

test("mocked CLI roundtrip deploys only selection, preserves mixed JWT and verifies downloaded transitive sources", async () => fixture(async (root) => {
  const executable = path.join(root, "supabase"), log = path.join(root, "calls.jsonl"), stages = path.join(root, "stages.json");
  await writeFile(executable, `#!${process.execPath}
import fs from 'node:fs'; import path from 'node:path';
const args=process.argv.slice(2), action=args[1], name=args[2];
fs.appendFileSync(${JSON.stringify(log)},JSON.stringify(args)+'\\n');
if(action==='list') console.log(JSON.stringify(['studio','portfolio'].map(name=>({name,status:'ACTIVE',import_map:false,verify_jwt:name==='studio'&&!process.env.FAKE_DRIFT,version:12}))));
else if(action==='deploy') {
 const workdir=args[args.indexOf('--workdir')+1], config=fs.readFileSync(path.join(workdir,'supabase/config.toml'),'utf8');
 if(!config.includes('[functions.studio]\\nverify_jwt = true')||!config.includes('[functions.portfolio]\\nverify_jwt = false')) process.exit(8);
 const state=fs.existsSync(${JSON.stringify(stages)})?JSON.parse(fs.readFileSync(${JSON.stringify(stages)},'utf8')):{};
 state[name]=workdir;fs.writeFileSync(${JSON.stringify(stages)},JSON.stringify(state));
} else if(action==='download') {
 const source=JSON.parse(fs.readFileSync(${JSON.stringify(stages)},'utf8'))[name], target=args[args.indexOf('--workdir')+1];
 const manifest=JSON.parse(fs.readFileSync(path.join(source,'deployment-receipt.json'),'utf8')).manifest;
 for(const file of manifest.runtimeByFunction[name]) {const output=path.join(target,'supabase/functions',file);fs.mkdirSync(path.dirname(output),{recursive:true});fs.copyFileSync(path.join(source,'supabase/functions',file),output);}
 if(process.env.FAKE_TAMPER) fs.appendFileSync(path.join(target,'supabase/functions',name,'index.ts'),'\\n// unexpected live edit');
} else process.exit(9);
`, { mode: 0o755 });
  const script = path.resolve(import.meta.dirname, "../scripts/deploy-backend.mjs");
  for (const scenario of ["success", "drift", "tamper"]) {
    await writeFile(log, "");
    const result = spawnSync(process.execPath, [script, "--functions", "studio,portfolio", "--run"], { encoding: "utf8", env: { ...process.env, PATH: `${root}${path.delimiter}${path.dirname(process.execPath)}`, FAKE_DRIFT: scenario === "drift" ? "1" : "", FAKE_TAMPER: scenario === "tamper" ? "1" : "" } });
    const calls = (await readFile(log, "utf8")).trim().split("\n").map((line) => JSON.parse(line));
    const receiptPath = scenario === "success" ? JSON.parse(result.stdout).receipt : result.stderr.match(/Receipt retained at (.+deployment-receipt\.json)/)?.[1];
    assert(receiptPath, result.stderr);
    const receipt = JSON.parse(await readFile(receiptPath, "utf8"));
    try {
      if (scenario === "success") {
        assert.equal(result.status, 0, result.stderr); assert.equal(receipt.status, "verified");
        assert.deepEqual(calls.filter((call) => call[1] === "deploy").map((call) => call[2]), ["studio", "portfolio"]);
        assert.equal(receipt.after.portfolio.verifyJwt, false);
        assert(receipt.completed.studio.matchedSourceFiles > 30);
        assert(receipt.completed.studio.stagedTypeOnlyNotInRuntime.includes("studio/context.ts"));
      } else if (scenario === "drift") {
        assert.notEqual(result.status, 0); assert(!calls.some((call) => call[1] === "deploy")); assert.match(receipt.failure, /drift/);
      } else {
        assert.notEqual(result.status, 0); assert.equal(calls.filter((call) => call[1] === "deploy").length, 1); assert.match(receipt.failure, /mismatch/);
      }
      assert(!calls.some((call) => call.includes("--no-verify-jwt") || call.includes("--prune")));
    } finally {
      for (const call of calls.filter((call) => call[1] === "download")) await rm(call[call.indexOf("--workdir") + 1], { recursive: true, force: true });
      await rm(path.dirname(receiptPath), { recursive: true, force: true });
    }
  }
}));


test("connected AST gate accepts minifier backticks/escapes only on exact public config properties", () => {
  const encodedUrl = url.replace("https", "\\u0068ttps");
  const bundle = "const env={VITE_SUPABASE_URL:`" + encodedUrl + "`,VITE_SUPABASE_PUBLISHABLE_KEY:'" + key + "'};";
  verifyConnectedBundle([bundle], values);
  assert.throws(() => verifyConnectedBundle(["const unrelated=`" + url + "`;const other=`" + key + "`;"], values), /missing the exact configured/);
  assert.throws(() => verifyConnectedBundle(["const env={VITE_SUPABASE_URL:`" + url + "${suffix}`,VITE_SUPABASE_PUBLISHABLE_KEY:`" + key + "`};"], values), /missing the exact configured/);
  const secret = "sb_secret_abcdefghijklmnopqrstuv";
  assert.throws(() => verifyConnectedBundle([bundle + "const hidden=`" + secret + "`;"], values), /secret key pattern/);
  assert.throws(() => verifyConnectedBundle([bundle + "const hidden=`" + secret + "${suffix}`;"], values), /secret key pattern/);
  const jwt = `header.${Buffer.from(JSON.stringify({role:"service_role"})).toString("base64url")}.signature`;
  assert.throws(() => verifyConnectedBundle([bundle + "const token=`" + jwt + "`;"], values), /service-role/);
  assert.throws(() => verifyConnectedBundle([bundle + "const token='prefix " + jwt + " suffix';"], values), /service-role/);
});

test("mocked first deployment creates only declared JWT-protected endpoints and requires exact final policy/source readback",async()=>fixture(async(root)=>{
 const executable=path.join(root,"supabase"),log=path.join(root,"calls.jsonl"),statefile=path.join(root,"stages.json");
 await writeFile(executable,`#!${process.execPath}
import fs from 'node:fs';import path from 'node:path';
const args=process.argv.slice(2),action=args[1],name=args[2],state=fs.existsSync(${JSON.stringify(statefile)})?JSON.parse(fs.readFileSync(${JSON.stringify(statefile)},'utf8')):{};
fs.appendFileSync(${JSON.stringify(log)},JSON.stringify(args)+'\\n');
if(action==='list')console.log(JSON.stringify(['studio',...Object.keys(state).filter(n=>n!=='studio')].map(name=>({name,status:'ACTIVE',import_map:false,verify_jwt:!(process.env.FAKE_DRIFT==='before'&&name==='studio'||process.env.FAKE_DRIFT==='after'&&Object.keys(state).length===3&&name==='property-video-plan'),version:1}))));
else if(action==='deploy'){
 const source=args[args.indexOf('--workdir')+1],config=fs.readFileSync(path.join(source,'supabase/config.toml'),'utf8');
 if(!['studio','property-sites','property-video-plan'].includes(name)||!config.includes('[functions.'+name+']\\nverify_jwt = true'))process.exit(8);
 state[name]=source;fs.writeFileSync(${JSON.stringify(statefile)},JSON.stringify(state));
}else if(action==='download'){
 const source=state[name],target=args[args.indexOf('--workdir')+1],manifest=JSON.parse(fs.readFileSync(path.join(source,'deployment-receipt.json'),'utf8')).manifest;
 for(const file of manifest.runtimeByFunction[name]){const output=path.join(target,'supabase/functions',file);fs.mkdirSync(path.dirname(output),{recursive:true});fs.copyFileSync(path.join(source,'supabase/functions',file),output);}
}else process.exit(9);
`,{mode:0o755});
 const script=path.resolve(import.meta.dirname,"../scripts/deploy-backend.mjs");
 for(const scenario of ['success','missing-flag','before','after']){
  await writeFile(log,'');await rm(statefile,{force:true});
  const args=[script,'--functions','studio,property-sites,property-video-plan','--run',...(scenario==='missing-flag'?[]:['--create-new','property-sites,property-video-plan'])];
  const result=spawnSync(process.execPath,args,{encoding:'utf8',env:{...process.env,PATH:`${root}${path.delimiter}${path.dirname(process.execPath)}`,FAKE_DRIFT:scenario}});
  const calls=(await readFile(log,'utf8')).trim().split('\n').filter(Boolean).map(line=>JSON.parse(line)),receiptPath=scenario==='success'?JSON.parse(result.stdout).receipt:result.stderr.match(/Receipt retained at (.+deployment-receipt\.json)/)?.[1];assert(receiptPath,result.stderr);
  const receipt=JSON.parse(await readFile(receiptPath,'utf8'));
  try{
   if(scenario==='success'){
    assert.equal(result.status,0,result.stderr);assert.equal(receipt.status,'verified');assert.deepEqual(receipt.requestedNewFunctions,['property-sites','property-video-plan']);assert.equal(receipt.before['property-sites'].create,true);assert.equal(receipt.after['property-sites'].verifyJwt,true);assert(receipt.completed['property-video-plan'].matchedSourceFiles>10);
    assert.deepEqual(calls.filter(c=>c[1]==='deploy').map(c=>c[2]),['studio','property-sites','property-video-plan']);
   }else{assert.notEqual(result.status,0);assert.equal(receipt.status,'failed');if(scenario==='after'){assert.equal(calls.filter(c=>c[1]==='deploy').length,3);assert.match(receipt.failure,/drift/);}else{assert(!calls.some(c=>c[1]==='deploy'));assert.match(receipt.failure,scenario==='before'?/drift/:/exactly one/);}}
   assert(!calls.some(c=>c.includes('--no-verify-jwt')||c.includes('--prune')));
  }finally{for(const c of calls.filter(c=>c[1]==='download'))await rm(c[c.indexOf('--workdir')+1],{recursive:true,force:true});await rm(path.dirname(receiptPath),{recursive:true,force:true});}
 }
}));

test("photo review first-deploy dry run stages only its closure with JWT on and no generation entrypoint",async()=>fixture(async(root)=>{
 const result=spawnSync(process.execPath,[path.resolve(import.meta.dirname,"../scripts/deploy-backend.mjs"),"--functions","photo-quality-review","--create-new","photo-quality-review"],{encoding:"utf8",env:{...process.env,PATH:root}});
 assert.equal(result.status,0,result.stderr);const receipt=JSON.parse(result.stdout);
 try{
  const stored=JSON.parse(await readFile(receipt.receipt,"utf8"));assert.equal(stored.mode,"dry-run");assert.deepEqual(stored.jwtPolicy,{"photo-quality-review":true});assert.deepEqual(stored.requestedNewFunctions,["photo-quality-review"]);assert.equal(stored.before,undefined);
  const files=Object.keys(stored.manifest.hashes);assert(files.includes("photo-quality-review/index.ts"));assert(files.includes("ai-photo/photo-qc-calibration.ts"));assert(!files.includes("ai-photo/index.ts"));assert(!files.some(name=>name.includes(".test.")));
 }finally{await rm(receipt.stage,{recursive:true,force:true});}
}));

test("versioned photo first-deploy stages strict shared handler with JWT on without selecting canonical deployment",async()=>fixture(async(root)=>{
 const result=spawnSync(process.execPath,[path.resolve(import.meta.dirname,"../scripts/deploy-backend.mjs"),"--functions","ai-photo-v2","--create-new","ai-photo-v2"],{encoding:"utf8",env:{...process.env,PATH:root}});
 assert.equal(result.status,0,result.stderr);const receipt=JSON.parse(result.stdout);
 try{
  const stored=JSON.parse(await readFile(receipt.receipt,"utf8"));assert.deepEqual(stored.functions,["ai-photo-v2"]);assert.deepEqual(stored.jwtPolicy,{"ai-photo-v2":true});
  assert(Object.keys(stored.manifest.hashes).includes("ai-photo/index.ts"));assert(Object.keys(stored.manifest.hashes).includes("ai-photo/protocol.ts"));assert.equal(stored.before,undefined);
 }finally{await rm(receipt.stage,{recursive:true,force:true});}
}));
