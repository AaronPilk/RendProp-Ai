import {mkdtemp,writeFile,readFile,rm} from 'node:fs/promises';
import {tmpdir} from 'node:os';import {join,resolve} from 'node:path';import {spawnSync} from 'node:child_process';
const root=resolve(import.meta.dirname,'../../..'),temp=await mkdtemp(join(tmpdir(),'rendprop-creative-qc-')),port='55447';
function run(command,args){const result=spawnSync(command,args,{encoding:'utf8'});if(result.status!==0)throw new Error(`${command}: ${result.stderr||result.stdout}`);return result.stdout;}
let started=false;
try{
run('initdb',['-D',join(temp,'data'),'-A','trust','--no-locale']);run('pg_ctl',['-D',join(temp,'data'),'-l',join(temp,'server.log'),'-o',`-k ${temp} -p ${port} -c listen_addresses=''`,'start']);started=true;
const setup=`create role anon;create role authenticated;
create table capture_assets(id uuid primary key,listing_id uuid,storage_key text,uploaded boolean,kind text,bucket text);
create table media_provenance(id uuid primary key,org_id uuid,listing_id uuid,original_key text,altered_key text,qc jsonb);
create table studio_creative_results(id uuid primary key,org_id uuid,listing_id uuid,kind text,storage_key text,provenance_id uuid,metadata jsonb);
create table render_jobs(id uuid primary key,capture_asset_id uuid,listing_id uuid);
create table renders(id uuid primary key,job_id uuid,video_key text);
insert into capture_assets values
('10000000-0000-4000-8000-000000000001','30000000-0000-4000-8000-000000000001','recorded.mp4',true,'video','renders'),
('10000000-0000-4000-8000-000000000002','30000000-0000-4000-8000-000000000001','generated.mp4',true,'video','renders'),
('10000000-0000-4000-8000-000000000003','30000000-0000-4000-8000-000000000001','original.jpg',true,'photo','renders');
insert into media_provenance values('50000000-0000-4000-8000-000000000001','20000000-0000-4000-8000-000000000001','30000000-0000-4000-8000-000000000001','original.jpg','generated.mp4',null);
insert into studio_creative_results values('40000000-0000-4000-8000-000000000001','20000000-0000-4000-8000-000000000001','30000000-0000-4000-8000-000000000001','video','generated.mp4','50000000-0000-4000-8000-000000000001','{"video_kind":"reel","state":"completed","asset_id":"10000000-0000-4000-8000-000000000002","source_asset_id":"10000000-0000-4000-8000-000000000003","request_id":"generation-123"}');`;
const migration=await readFile(join(root,'services/supabase/migrations/20260914170849_studio_generated_quality_gate.sql'),'utf8');
const tests=`
create function must_hold(action text) returns void language plpgsql as $$begin begin execute action;raise exception 'expected quality hold';exception when raise_exception then if sqlerrm not like 'RP409:%' then raise;end if;end;end$$;
insert into render_jobs values('60000000-0000-4000-8000-000000000001','10000000-0000-4000-8000-000000000001','30000000-0000-4000-8000-000000000001');
insert into renders values('70000000-0000-4000-8000-000000000001','60000000-0000-4000-8000-000000000001','recorded.mp4');
select must_hold('insert into render_jobs values(gen_random_uuid(),''10000000-0000-4000-8000-000000000002'',''30000000-0000-4000-8000-000000000001'')');
update media_provenance set qc='{"verdict":"pass","publishable":true,"request_id":"wrong-job"}';
select must_hold('insert into render_jobs values(gen_random_uuid(),''10000000-0000-4000-8000-000000000002'',''30000000-0000-4000-8000-000000000001'')');
update media_provenance set qc='{"verdict":"pass","publishable":true,"request_id":"generation-123"}',original_key='different.jpg';
select must_hold('insert into render_jobs values(gen_random_uuid(),''10000000-0000-4000-8000-000000000002'',''30000000-0000-4000-8000-000000000001'')');
update media_provenance set original_key='original.jpg',altered_key='different.mp4';
select must_hold('insert into render_jobs values(gen_random_uuid(),''10000000-0000-4000-8000-000000000002'',''30000000-0000-4000-8000-000000000001'')');
update media_provenance set altered_key='generated.mp4';
insert into render_jobs values('60000000-0000-4000-8000-000000000002','10000000-0000-4000-8000-000000000002','30000000-0000-4000-8000-000000000001');
insert into renders values('70000000-0000-4000-8000-000000000002','60000000-0000-4000-8000-000000000002','generated.mp4');
update media_provenance set qc='{"verdict":"fail","publishable":false,"request_id":"generation-123"}';
select must_hold('insert into renders values(gen_random_uuid(),''60000000-0000-4000-8000-000000000002'',''generated.mp4'')');
select must_hold('update render_jobs set capture_asset_id=''10000000-0000-4000-8000-000000000002'' where id=''60000000-0000-4000-8000-000000000001''');
select must_hold('update renders set job_id=''60000000-0000-4000-8000-000000000002'' where id=''70000000-0000-4000-8000-000000000001''');
set role authenticated;do $$begin begin perform public.assert_studio_asset_quality('10000000-0000-4000-8000-000000000001');raise exception 'direct quality helper allowed';exception when insufficient_privilege then null;end;end$$;reset role;
`;
const path=join(temp,'test.sql');await writeFile(path,setup+'\n'+migration+'\n'+tests);run('psql',['-X','-h',temp,'-p',port,'-d','postgres','-v','ON_ERROR_STOP=1','-f',path]);console.log(JSON.stringify({status:'passed',checks:['ordinary recorded video unchanged','unchecked generation held','wrong generation verdict held','wrong source held','wrong output held','matching server verdict publishes','revoked verdict held at publication','source substitution held','render job substitution held','private helper not callable by client']},null,2));
}finally{if(started)run('pg_ctl',['-D',join(temp,'data'),'stop','-m','fast']);await rm(temp,{recursive:true,force:true});}
