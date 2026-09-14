// Deploy only the reviewed Studio handoff and public disclosure functions.
// Staging prevents an unrelated function/config in a checkout from being deployed.
import {cp,mkdir,mkdtemp,readFile,writeFile,readdir} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join,resolve,relative} from 'node:path';
import {createHash} from 'node:crypto';
import {spawn} from 'node:child_process';
const args=process.argv.slice(2);
if(!args.includes('--run')||args.some(arg=>arg!=='--run'&&arg!=='--only-studio'))throw new Error('Use --run [--only-studio] to deploy the reviewed backend.');
const project='ymgqpbnjpztwjsyvceld',root=resolve(import.meta.dirname,'../../..');
const stage=await mkdtemp(join(tmpdir(),'rendprop-studio-backend-'));
const functions=join(stage,'supabase/functions');
const deployedFunctions=args.includes('--only-studio')?['studio']:['studio','listings','tours','ai-voice'];
for(const name of [...deployedFunctions,'_shared'])await cp(join(root,'services/supabase/functions',name),join(functions,name),{recursive:true});
// Tours imports these two spatial helpers; no spatial entrypoint is staged/deployed.
if(deployedFunctions.includes('tours')){
 await mkdir(join(functions,'spatial'),{recursive:true});
 for(const name of ['chapters.ts','contract.ts'])await cp(join(root,'services/supabase/functions/spatial',name),join(functions,'spatial',name));
}
await writeFile(join(stage,'supabase/config.toml'),`project_id = "${project}"\n\n${deployedFunctions.map(name=>`[functions.${name}]\nverify_jwt = true\n`).join('\n')}`);
const hashes=[];
async function inspect(dir){for(const item of await readdir(dir,{withFileTypes:true})){const path=join(dir,item.name);if(item.isDirectory())await inspect(path);else hashes.push({path:relative(functions,path),sha256:createHash('sha256').update(await readFile(path)).digest('hex')});}}
await inspect(functions);
const token=(await readFile('/Users/pilksclaes/Rendprop AI/_bridge/.supabase-token','utf8')).trim();
const child=spawn('supabase',['functions','deploy',...deployedFunctions,'--project-ref',project,'--use-api','--workdir',stage],{env:{...process.env,SUPABASE_ACCESS_TOKEN:token},stdio:'inherit'});
const code=await new Promise((resolve,reject)=>{child.once('error',reject);child.once('exit',resolve);});
const receipt={status:code===0?'deployed':'failed',project,functions:deployedFunctions,verifyJwt:true,finishedAt:new Date().toISOString(),sources:hashes};
await writeFile(join(stage,'receipt.json'),JSON.stringify(receipt,null,2)+'\n');
console.log(JSON.stringify({status:receipt.status,receipt:join(stage,'receipt.json')}));
process.exitCode=code===0?0:1;
