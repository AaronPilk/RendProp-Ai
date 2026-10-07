// Each mutation compiles the actual production TypeScript and must fail the
// unchanged real byte-boundary gate at its intended authorization assertion.
import assert from "node:assert/strict";
import {readFileSync,writeFileSync,mkdirSync,cpSync} from "node:fs";
import {join} from "node:path";
import {pathToFileURL} from "node:url";
import {spawnSync} from "node:child_process";
import ts from "typescript";
import {ROOT,buildSrc} from "./build-src.mjs";
buildSrc("media-delivery-check");const destination=join(ROOT,"node_modules/.cache/media-delivery-controls");mkdirSync(destination,{recursive:true});cpSync(join(ROOT,"node_modules/.cache/media-delivery-check/upstream.js"),join(destination,"upstream.js"));
const source=readFileSync(join(ROOT,"src/media-delivery.ts"),"utf8"),mutants=[
 ["unselected-key","if(encodedPath||!Object.hasOwn(delivery.objects,key))return unavailable();","if(encodedPath)return unavailable();"],
 ["revocation-after-head","const fresh=await revalidate();if(fresh!==200)return unavailable(fresh);","const fresh=200;if(fresh!==200)return unavailable(fresh);"],
 ["revocation-after-get","const final=await revalidate();if(final!==200){void object.body.cancel().catch(()=>{});return unavailable(final);}","const final=200;if(final!==200){void object.body.cancel().catch(()=>{});return unavailable(final);}"],
 ["stored-cache-metadata","for(const [name,value]of Object.entries(headers))h.set(name,value);","/* lost final no-store override */"],
];
const results=[];
for(const[name,needle,replacement]of mutants){
 assert.equal(source.split(needle).length,2,`Unique compiled mutation target ${name}`);
 const compiled=ts.transpileModule(source.replace(needle,replacement),{compilerOptions:{target:ts.ScriptTarget.ES2022,module:ts.ModuleKind.ESNext,isolatedModules:true}}).outputText.replace('from "./upstream"','from "./upstream.js"');
 const filename=join(destination,name+".mjs");writeFileSync(filename,compiled);
 const result=spawnSync(process.execPath,[join(ROOT,"scripts/check-media-delivery.mjs")],{encoding:"utf8",env:{...process.env,MEDIA_MUTATION_MODULE:pathToFileURL(filename).href}});
 assert.notEqual(result.status,0,`${name} must fail unchanged byte gate`);assert.match(result.stderr,/AssertionError/,`${name} must fail an assertion, not loading/compilation`);
 results.push({name,compiled:true,exit:result.status,assertionRejected:true});
}
console.log(JSON.stringify({success:true,controls:results,live:false}));
