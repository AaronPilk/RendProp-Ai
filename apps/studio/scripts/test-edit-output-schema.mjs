import {mkdtemp,writeFile,readFile,rm} from 'node:fs/promises';
import {tmpdir} from 'node:os';import {join,resolve} from 'node:path';import {spawnSync} from 'node:child_process';
const root=resolve(import.meta.dirname,'../../..'),temp=await mkdtemp(join(tmpdir(),'rendprop-edit-proof-')),port='55448';
function run(command,args){const result=spawnSync(command,args,{encoding:'utf8'});if(result.status!==0)throw new Error(`${command}: ${result.stderr||result.stdout}`);return result.stdout;}
let started=false;
try{
run('initdb',['-D',join(temp,'data'),'-A','trust','--no-locale']);run('pg_ctl',['-D',join(temp,'data'),'-l',join(temp,'server.log'),'-o',`-k ${temp} -p ${port} -c listen_addresses=''`,'start']);started=true;
const setup=`create role anon;create role authenticated;create role service_role;
create table capture_assets(id uuid primary key,listing_id uuid,storage_key text,uploaded boolean,kind text,bucket text);
create table media_provenance(id uuid primary key,org_id uuid,listing_id uuid,original_key text,altered_key text,qc jsonb,kind text,disclosure text);
create table studio_creative_results(id uuid primary key,org_id uuid,listing_id uuid,kind text,storage_key text,provenance_id uuid,metadata jsonb);
create table render_jobs(id uuid primary key,capture_asset_id uuid,listing_id uuid);
create table renders(id uuid primary key,job_id uuid,video_key text,staged boolean default false);
insert into capture_assets values
('10000000-0000-4000-8000-000000000001','30000000-0000-4000-8000-000000000001','recorded.mp4',true,'video','renders'),
('10000000-0000-4000-8000-000000000002','30000000-0000-4000-8000-000000000001','generated.mp4',true,'video','renders'),
('10000000-0000-4000-8000-000000000003','30000000-0000-4000-8000-000000000001','original.jpg',true,'photo','renders'),
('10000000-0000-4000-8000-000000000004','30000000-0000-4000-8000-000000000001','ordinary-edit.mp4',true,'video','renders'),
('10000000-0000-4000-8000-000000000005','30000000-0000-4000-8000-000000000001','ai-edit.mp4',true,'video','renders'),
('10000000-0000-4000-8000-000000000006','30000000-0000-4000-8000-000000000001','nested-edit.mp4',true,'video','renders');
insert into media_provenance values
('50000000-0000-4000-8000-000000000001','20000000-0000-4000-8000-000000000001','30000000-0000-4000-8000-000000000001','original.jpg','generated.mp4','{"verdict":"pass","publishable":true,"request_id":"generation-123"}','reel','Generated motion.'),
('50000000-0000-4000-8000-000000000004','20000000-0000-4000-8000-000000000001','30000000-0000-4000-8000-000000000001',null,'ordinary-edit.mp4',null,'other','This video was edited.'),
('50000000-0000-4000-8000-000000000005','20000000-0000-4000-8000-000000000001','30000000-0000-4000-8000-000000000001',null,'ai-edit.mp4',null,'other','This video uses selected AI visuals.'),
('50000000-0000-4000-8000-000000000006','20000000-0000-4000-8000-000000000001','30000000-0000-4000-8000-000000000001',null,'nested-edit.mp4',null,'other','This video uses selected AI visuals.');
insert into studio_creative_results values
('40000000-0000-4000-8000-000000000002','20000000-0000-4000-8000-000000000001','30000000-0000-4000-8000-000000000001','video','generated.mp4','50000000-0000-4000-8000-000000000001','{"video_kind":"reel","state":"completed","asset_id":"10000000-0000-4000-8000-000000000002","source_asset_id":"10000000-0000-4000-8000-000000000003","request_id":"generation-123"}'),
('40000000-0000-4000-8000-000000000004','20000000-0000-4000-8000-000000000001','30000000-0000-4000-8000-000000000001','video','ordinary-edit.mp4','50000000-0000-4000-8000-000000000004','{"video_kind":"edit","state":"completed","asset_id":"10000000-0000-4000-8000-000000000004","source_asset_ids":["10000000-0000-4000-8000-000000000001"],"has_visual_ai":false,"disclosure":"This video was edited."}'),
('40000000-0000-4000-8000-000000000005','20000000-0000-4000-8000-000000000001','30000000-0000-4000-8000-000000000001','video','ai-edit.mp4','50000000-0000-4000-8000-000000000005','{"video_kind":"edit","state":"completed","asset_id":"10000000-0000-4000-8000-000000000005","source_asset_ids":["10000000-0000-4000-8000-000000000002"],"has_visual_ai":true,"disclosure":"This video uses selected AI visuals."}'),
('40000000-0000-4000-8000-000000000006','20000000-0000-4000-8000-000000000001','30000000-0000-4000-8000-000000000001','video','nested-edit.mp4','50000000-0000-4000-8000-000000000006','{"video_kind":"edit","state":"completed","asset_id":"10000000-0000-4000-8000-000000000006","source_asset_ids":["10000000-0000-4000-8000-000000000005"],"has_visual_ai":true,"disclosure":"This video uses selected AI visuals."}');`;
const migrations=await Promise.all(['20260914170849_studio_generated_quality_gate.sql','20260914173513_studio_edit_output_disclosure.sql'].map(name=>readFile(join(root,'services/supabase/migrations',name),'utf8')));
const nativeSchema=await readFile(join(root,'services/supabase/migrations/0012_provenance_and_unbranded.sql'),'utf8');
const nativePhotoResolver=nativeSchema.match(/create or replace function public\.provenance_asset_key\([\s\S]*?\$fn\$;/)?.[0];
if(!nativePhotoResolver)throw new Error('The native provenance resolver changed; review generated-video attachment against the actual schema.');
const tests=`
do $$begin begin perform public.provenance_asset_key('10000000-0000-4000-8000-000000000002','30000000-0000-4000-8000-000000000001');raise exception 'expected photo-only native resolver';exception when raise_exception then if sqlerrm not like 'RP400:%must be a photo%' then raise;end if;end;end$$;
create function must_hold(action text) returns void language plpgsql as $$begin begin execute action;raise exception 'expected quality hold';exception when raise_exception then if sqlerrm not like 'RP409:%' then raise;end if;end;end$$;
insert into render_jobs values('60000000-0000-4000-8000-000000000004','10000000-0000-4000-8000-000000000004','30000000-0000-4000-8000-000000000001');
insert into renders values('70000000-0000-4000-8000-000000000004','60000000-0000-4000-8000-000000000004','ordinary-edit.mp4',false);
do $$begin if (select staged from renders where id='70000000-0000-4000-8000-000000000004') then raise exception 'ordinary edit falsely staged';end if;end$$;
insert into render_jobs values('60000000-0000-4000-8000-000000000005','10000000-0000-4000-8000-000000000005','30000000-0000-4000-8000-000000000001');
insert into renders values('70000000-0000-4000-8000-000000000005','60000000-0000-4000-8000-000000000005','ai-edit.mp4',false);
do $$begin if not (select staged from renders where id='70000000-0000-4000-8000-000000000005') then raise exception 'AI edit lost staged flag';end if;end$$;
select public.assert_studio_edit_quality('10000000-0000-4000-8000-000000000006');
update media_provenance set qc='{"verdict":"fail","publishable":false,"request_id":"generation-123"}' where id='50000000-0000-4000-8000-000000000001';
select must_hold('insert into renders values(gen_random_uuid(),''60000000-0000-4000-8000-000000000005'',''ai-edit.mp4'',false)');
select must_hold('select public.assert_studio_edit_quality(''10000000-0000-4000-8000-000000000006'')');
update media_provenance set qc='{"verdict":"pass","publishable":true,"request_id":"generation-123"}' where id='50000000-0000-4000-8000-000000000001';
select must_hold('update media_provenance set altered_key=''elsewhere.mp4'' where id=''50000000-0000-4000-8000-000000000005''');
select must_hold('update media_provenance set original_key=''invented-original.mp4'' where id=''50000000-0000-4000-8000-000000000005''');
update studio_creative_results set metadata=jsonb_set(metadata,'{state}','"finalizing"') where id='40000000-0000-4000-8000-000000000005';
select must_hold('select public.assert_studio_edit_quality(''10000000-0000-4000-8000-000000000005'')');
update studio_creative_results set metadata=jsonb_set(metadata,'{state}','"completed"') where id='40000000-0000-4000-8000-000000000005';
update capture_assets set storage_key='changed.mp4' where id='10000000-0000-4000-8000-000000000005';
select must_hold('select public.assert_studio_edit_quality(''10000000-0000-4000-8000-000000000005'')');
update capture_assets set storage_key='ai-edit.mp4' where id='10000000-0000-4000-8000-000000000005';
update studio_creative_results set metadata=jsonb_set(metadata,'{source_asset_ids}','["10000000-0000-4000-8000-000000000006"]') where id='40000000-0000-4000-8000-000000000005';
select must_hold('select public.assert_studio_edit_quality(''10000000-0000-4000-8000-000000000006'')');
set role authenticated;do $$begin begin perform public.assert_studio_edit_quality('10000000-0000-4000-8000-000000000004');raise exception 'client helper allowed';exception when insufficient_privilege then null;end;end$$;reset role;
`;
const path=join(temp,'test.sql');await writeFile(path,setup+'\n'+nativePhotoResolver+'\n'+migrations.join('\n')+'\n'+tests);run('psql',['-X','-h',temp,'-p',port,'-d','postgres','-v','ON_ERROR_STOP=1','-f',path]);console.log(JSON.stringify({status:'passed',checks:['actual native provenance resolver rejects video and must not be used for generated-video attachment','ordinary edits remain unstaged','known AI edits retain disclosure flag','completed nested edit accepted','revoked source verdict held at publication','nested source revocation held','disclosure source reassignment held','invented single original held','unfinished finalization held','output substitution held','cyclic source declaration held','private helper not callable by client']},null,2));
}finally{if(started)run('pg_ctl',['-D',join(temp,'data'),'stop','-m','fast']);await rm(temp,{recursive:true,force:true});}
