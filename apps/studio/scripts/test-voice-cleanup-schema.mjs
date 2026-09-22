// Actual ordered migrations in a fresh, socket-only PostgreSQL cluster.
import {mkdtemp,writeFile,readFile,readdir} from 'node:fs/promises';
import {join,resolve} from 'node:path';import {spawnSync} from 'node:child_process';
const root=resolve(import.meta.dirname,'../../..'),temp=await mkdtemp('/tmp/rendprop-voice-cleanup-'),port='55441';
const env={PATH:process.env.PATH,LC_ALL:'C',TZ:'UTC'};
function run(command,args){const r=spawnSync(command,args,{env,encoding:'utf8',maxBuffer:8*1024*1024});if(r.status!==0)throw Error(`${command}: ${r.stderr||r.stdout}`);return r.stdout;}
const psql=['-X','-h',temp,'-p',port,'-d','postgres','-v','ON_ERROR_STOP=1'];let started=false;
const receipt={status:'running',checks:[],migrations:[],externalDeletion:false};
try{
 run('initdb',['-D',join(temp,'data'),'-A','trust','--no-locale','--encoding=UTF8']);
 run('pg_ctl',['-D',join(temp,'data'),'-l',join(temp,'server.log'),'-o',`-k ${temp} -p ${port} -c listen_addresses=''`,'start']);started=true;
 run('psql',[...psql,'-f',join(root,'services/supabase/tests/ci-bootstrap.sql')]);
 for(const name of (await readdir(join(root,'services/supabase/migrations'))).filter(name=>name.endsWith('.sql')).sort()){
  run('psql',[...psql,'-f',join(root,'services/supabase/migrations',name)]);receipt.migrations.push(name);
 }
 const assertions=`begin;
 create temp table fixture(n int,actor uuid,org uuid,listing uuid,receipt jsonb);
 do $$declare a uuid; o uuid; l uuid; begin
 for n in 1..3 loop
 a:=gen_random_uuid();l:=gen_random_uuid();
 insert into auth.users(id,email,raw_user_meta_data) values(a,'voice-'||n||'@fixture.invalid','{}');
 select org_id into strict o from public.memberships where user_id=a;
 insert into public.listings(id,org_id,agent_id,address) values(l,o,a,'Synthetic voice fixture');
 insert into public.studio_creative_results(user_id,org_id,listing_id,kind,bucket,storage_key,request_key,metadata)
 values(a,o,l,'voice','uploads','ai-voice/'||o||'/'||gen_random_uuid()||'.mp3','voice-fixture','{"state":"completed"}');
 insert into fixture values(n,a,o,l,null);
 end loop;end$$;
 grant select,update on fixture to service_role;
 do $$declare teammate uuid; begin
 teammate:=gen_random_uuid();insert into auth.users(id,email,raw_user_meta_data)values(teammate,'voice-teammate@fixture.invalid','{}');
 insert into memberships(user_id,org_id,role)select teammate,org,'agent' from fixture where n=2;
 end$$;
 set local role service_role;
 update fixture set receipt=public.prepare_account_deletion(actor,'fixture-uploads','fixture-renders') where n in(1,2);
 reset role;
 do $$declare f record;begin
 select * into f from fixture where n=1;
 if jsonb_array_length(f.receipt->'payload'->'r2')<>1 or f.receipt->'payload'->'r2'->0->>'bucket'<>'fixture-uploads' or
 not starts_with(f.receipt->'payload'->'r2'->0->>'key','ai-voice/'||f.org||'/') then raise exception 'Owned voice missing from leased cleanup';end if;
 if exists(select 1 from studio_creative_results where org_id=f.org) then raise exception 'Private history was not purged';end if;
 select * into f from fixture where n=2;
 if jsonb_array_length(f.receipt->'payload'->'r2')<>0 or not exists(select 1 from studio_creative_results where org_id=f.org) then raise exception 'Shared voice media was destroyed';end if;
 if has_function_privilege('anon','public.studio_voice_deletion_targets(uuid[],text)','execute') or
 has_function_privilege('authenticated','public.studio_voice_deletion_targets(uuid[],text)','execute') or
 has_function_privilege('service_role','public.studio_voice_deletion_targets(uuid[],text)','execute') then raise exception 'Private helper exposed';end if;
 end$$;
 -- A malformed server history record must retain the account for repair.
 update studio_creative_results set storage_key='ai-voice/unverified.mp3' where org_id=(select org from fixture where n=3);
 set local role service_role;
 do $$begin
 begin perform public.prepare_account_deletion((select actor from fixture where n=3),'fixture-uploads','fixture-renders');
 raise exception 'invalid history accepted';exception when others then
 if sqlerrm not like 'RP409: unverified media ownership%' then raise;end if;end;
 end$$;
 reset role;
 do $$begin if not exists(select 1 from listings where id=(select listing from fixture where n=3)) then raise exception 'Failed cleanup did not roll back';end if;end$$;
 rollback;`;
 const file=join(temp,'assertions.sql');await writeFile(file,assertions);run('psql',[...psql,'-f',file]);
 run('psql',[...psql,'-f',join(root,'services/supabase/tests/voice_storage_reservations.sql')]);
 const drainCheck=`do $$begin
 if public.account_deletion_drain() is not null then raise exception 'Empty cleanup queue made a request';end if;
 if has_function_privilege('anon','public.account_deletion_drain()','execute') or has_function_privilege('authenticated','public.account_deletion_drain()','execute') then raise exception 'Cleanup drain is public';end if;
 end$$;`;
 run('psql',[...psql,'-c',drainCheck]);
 receipt.status='passed';receipt.checks=['all ordered migrations apply','solo voice exact key retained in leased cleanup','history removed only after inventory','shared team voice retained','helper inaccessible to API roles','invalid history rolls back deletion','empty cleanup queue does not request HTTP','cleanup drain unavailable to client roles','exact pre-dispatch reservation with optional listing','replay retains original fixed 15 minute deadline','expired reservations cannot renew','API roles cannot read or directly mutate reservations','reservation scope and key checks reject mismatches','deleted account/workspace/listing and read-only role rejected without writes','pending reservations inventoried before history exists','history and reservation cleanup targets deduplicated','cleanup waits original write deadline plus one hour','shared reservations survive creator Auth deletion','final shared owner retains ability to clean up its voice keys','invalid history rolls back reservation and parent purge'];
}catch(error){receipt.status='failed';receipt.error=error.message;process.exitCode=1;}
finally{if(started)run('pg_ctl',['-D',join(temp,'data'),'stop','-m','fast']);await writeFile(join(temp,'receipt.json'),JSON.stringify(receipt,null,2));console.log(JSON.stringify({...receipt,receipt:join(temp,'receipt.json')},null,2));}
