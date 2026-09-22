// Gallery CAS and role behavior against the actual ordered migrations, with no network listener.
import {mkdtemp,writeFile,readdir} from 'node:fs/promises';
import {join,resolve} from 'node:path';import {spawnSync} from 'node:child_process';
const root=resolve(import.meta.dirname,'../../..'),temp=await mkdtemp('/tmp/rendprop-gallery-schema-'),port='55449';
const env={PATH:process.env.PATH,LC_ALL:'C',TZ:'UTC'};
function run(command,args){const r=spawnSync(command,args,{env,encoding:'utf8',maxBuffer:8*1024*1024});if(r.status!==0)throw Error(`${command}: ${r.stderr||r.stdout}`);return r.stdout;}
const psql=['-X','-h',temp,'-p',port,'-d','postgres','-v','ON_ERROR_STOP=1'];let started=false;
const receipt={status:'running',checks:[],migrations:[],externalRequests:false};
try{
 run('initdb',['-D',join(temp,'data'),'-A','trust','--no-locale','--encoding=UTF8']);
 run('pg_ctl',['-D',join(temp,'data'),'-l',join(temp,'server.log'),'-o',`-k ${temp} -p ${port} -c listen_addresses=''`,'start']);started=true;
 run('psql',[...psql,'-f',join(root,'services/supabase/tests/ci-bootstrap.sql')]);
 run('psql',[...psql,'-c','alter table auth.users add column is_anonymous boolean not null default false;']);
 for(const name of (await readdir(join(root,'services/supabase/migrations'))).filter(name=>name.endsWith('.sql')).sort()){
  run('psql',[...psql,'-f',join(root,'services/supabase/migrations',name)]);receipt.migrations.push(name);
 }
 const assertions=`begin;
 create temp table gallery_fixture(n int,actor uuid,org uuid,listing uuid,p1 uuid,p2 uuid,p3 uuid,extra uuid,old_order jsonb,new_order jsonb);
 do $$declare a uuid;o uuid;l uuid;first_id uuid;second_id uuid;third_id uuid;begin
 for n in 1..2 loop
 a:=gen_random_uuid();l:=gen_random_uuid();first_id:=gen_random_uuid();second_id:=gen_random_uuid();third_id:=gen_random_uuid();
 insert into auth.users(id,email,raw_user_meta_data)values(a,'gallery-'||n||'@fixture.invalid','{}');
 select org_id into strict o from memberships where user_id=a;
 insert into listings(id,org_id,agent_id,address)values(l,o,a,'Synthetic gallery fixture');
 insert into photos(id,listing_id,original_key,enhanced_key,is_main,is_staged,caption,sort)values
 (first_id,l,'renders/'||o||'/'||l||'/original-a.jpg',null,true,false,'Front exterior',0),
 (second_id,l,'renders/'||o||'/'||l||'/original-b.jpg','renders/'||o||'/'||l||'/enhanced-b.jpg',false,true,'AI staging disclosure remains attached',1),
 (third_id,l,'renders/'||o||'/'||l||'/original-c.jpg',null,false,false,'Patio',2);
 insert into gallery_fixture values(n,a,o,l,first_id,second_id,third_id,gen_random_uuid(),jsonb_build_array(first_id,second_id,third_id),jsonb_build_array(third_id,second_id,first_id));
 end loop;end$$;
 create temp table gallery_original as select p.* from photos p join gallery_fixture f on p.listing_id=f.listing;
 grant select on gallery_fixture,gallery_original to authenticated;
 create function pg_temp.gallery_state() returns jsonb language sql as $$select jsonb_build_object(
 'photos',(select jsonb_agg(to_jsonb(p)order by p.id)from photos p where p.listing_id in(select listing from gallery_fixture)),
 'listings',(select jsonb_agg(to_jsonb(l)order by l.id)from listings l where l.id in(select listing from gallery_fixture)))$$;
 create function pg_temp.must_refuse(statement text,prefix text) returns void language plpgsql as $$declare before_state jsonb;begin
 before_state:=pg_temp.gallery_state();
 begin execute statement;raise exception 'Expected gallery refusal was missing';exception when others then if sqlerrm not like prefix||'%' then raise;end if;end;
 if pg_temp.gallery_state() is distinct from before_state then raise exception 'Refused gallery action left a partial change';end if;
 end$$;
 select set_config('request.jwt.claim.sub',(select actor::text from gallery_fixture where n=1),true);
 set local role authenticated;
 -- A real invoker call changes the exact order and a repeated receipt is harmless.
 do $$declare f record;response jsonb;begin select * into f from gallery_fixture where n=1;
 response:=studio_gallery_update(f.org,f.listing,'reorder',null,f.old_order,f.new_order);
 if response->>'ok'<>'true' or response->'photo_ids'<>f.new_order then raise exception 'Reorder returned an incomplete receipt';end if;
 if (select jsonb_agg(id order by sort,id)from photos where listing_id=f.listing)<>f.new_order then raise exception 'Gallery order was not saved';end if;
 if (select array_agg(sort order by sort,id)from photos where listing_id=f.listing)<>array[0,1,2]::smallint[] then raise exception 'Gallery order is not contiguous';end if;
 if studio_gallery_update(f.org,f.listing,'reorder',null,f.old_order,f.new_order)<>response then raise exception 'Repeated reorder changed its receipt';end if;
 perform pg_temp.must_refuse(format('select studio_gallery_update(%L,%L,''reorder'',null,%L::jsonb,%L::jsonb)',f.org,f.listing,f.old_order,jsonb_build_array(f.p2,f.p1,f.p3)),'RP409:');
 perform pg_temp.must_refuse(format('select studio_gallery_update(%L,%L,''reorder'',null,%L::jsonb,%L::jsonb)',f.org,f.listing,f.new_order,jsonb_build_array(f.p1,f.p1,f.p3)),'RP400:');
 perform pg_temp.must_refuse(format('select studio_gallery_update(%L,%L,''reorder'',null,%L::jsonb,%L::jsonb)',f.org,f.listing,'[]','[]'),'RP400:');
 end$$;
 reset role;
 -- A phone adds a photo after the browser took its snapshot.
 insert into photos(id,listing_id,original_key,sort)select extra,listing,'renders/'||org||'/'||listing||'/extra.jpg',3 from gallery_fixture where n=1;
 set local role authenticated;
 select pg_temp.must_refuse(format('select studio_gallery_update(%L,%L,''reorder'',null,%L::jsonb,%L::jsonb)',org,listing,new_order,old_order),'RP409:')from gallery_fixture where n=1;
 reset role;
 delete from photos where id=(select extra from gallery_fixture where n=1);
 -- A phone removes a photo; no surviving row may be partially reordered.
 delete from photos where id=(select p2 from gallery_fixture where n=1);
 set local role authenticated;
 select pg_temp.must_refuse(format('select studio_gallery_update(%L,%L,''reorder'',null,%L::jsonb,%L::jsonb)',org,listing,new_order,old_order),'RP409:')from gallery_fixture where n=1;
 reset role;
 insert into photos select * from gallery_original where id=(select p2 from gallery_fixture where n=1);
 -- Same count, different actual photo ID is also a stale snapshot.
 delete from photos where id=(select p2 from gallery_fixture where n=1);
 insert into photos(id,listing_id,original_key,sort)select extra,listing,'renders/'||org||'/'||listing||'/replacement.jpg',1 from gallery_fixture where n=1;
 set local role authenticated;
 select pg_temp.must_refuse(format('select studio_gallery_update(%L,%L,''reorder'',null,%L::jsonb,%L::jsonb)',org,listing,new_order,old_order),'RP409:')from gallery_fixture where n=1;
 reset role;
 delete from photos where id=(select extra from gallery_fixture where n=1);
 insert into photos select * from gallery_original where id=(select p2 from gallery_fixture where n=1);
 set local role authenticated;
 -- PostgREST p_expected:null arrives as SQL NULL, and chooses the enhanced key.
 do $$declare f record;r jsonb;begin select * into f from gallery_fixture where n=1;
 r:=studio_gallery_update(f.org,f.listing,'cover',f.p2,null,null);
 if r->>'main_photo_key'<>'renders/'||f.org||'/'||f.listing||'/enhanced-b.jpg'
   or (select main_photo_key from listings where id=f.listing)<>r->>'main_photo_key'
   or (select count(*)from photos where listing_id=f.listing and is_main)<>1
   or not(select is_main from photos where id=f.p2) then raise exception 'Cover did not atomically set one canonical main photo';end if;
 if studio_gallery_update(f.org,f.listing,'cover',f.p2,null,null)<>r then raise exception 'Repeated cover change is not replay-safe';end if;
 perform pg_temp.must_refuse(format('select studio_gallery_update(%L,%L,''cover'',%L,null,null)',f.org,f.listing,f.p3),'RP409:');
 perform pg_temp.must_refuse(format('select studio_gallery_update(%L,%L,''cover'',%L,%L::jsonb,null)',f.org,f.listing,(select p1 from gallery_fixture where n=2),to_jsonb(r->>'main_photo_key')),'RP404:');
 perform pg_temp.must_refuse(format('select studio_gallery_update(%L,%L,''cover'',%L,null,null)',f.org,(select listing from gallery_fixture where n=2),f.p1),'RP404:');
 end$$;
 reset role;
 -- A role or account change after the page loaded must be checked at execution.
 update memberships set role='marketing' where user_id=(select actor from gallery_fixture where n=1)and org_id=(select org from gallery_fixture where n=1);
 set local role authenticated;
 select pg_temp.must_refuse(format('select studio_gallery_update(%L,%L,''reorder'',null,%L::jsonb,%L::jsonb)',org,listing,new_order,old_order),'RP403:')from gallery_fixture where n=1;
 reset role;
 update memberships set role='owner' where user_id=(select actor from gallery_fixture where n=1)and org_id=(select org from gallery_fixture where n=1);
 update auth.users set is_anonymous=true where id=(select actor from gallery_fixture where n=1);
 set local role authenticated;
 select pg_temp.must_refuse(format('select studio_gallery_update(%L,%L,''reorder'',null,%L::jsonb,%L::jsonb)',org,listing,new_order,old_order),'RP403:')from gallery_fixture where n=1;
 reset role;
 update auth.users set is_anonymous=false where id=(select actor from gallery_fixture where n=1);
 insert into deletion_requests(user_id,email,status,payload)select actor,'deleting-gallery@fixture.invalid','pending','{}'from gallery_fixture where n=1;
 set local role authenticated;
 select pg_temp.must_refuse(format('select studio_gallery_update(%L,%L,''reorder'',null,%L::jsonb,%L::jsonb)',org,listing,new_order,old_order),'RP403:')from gallery_fixture where n=1;
 reset role;
 update deletion_requests set status='processing'where user_id=(select actor from gallery_fixture where n=1);
 set local role authenticated;
 select pg_temp.must_refuse(format('select studio_gallery_update(%L,%L,''reorder'',null,%L::jsonb,%L::jsonb)',org,listing,new_order,old_order),'RP403:')from gallery_fixture where n=1;
 reset role;
 delete from deletion_requests where user_id=(select actor from gallery_fixture where n=1);
 -- Both legal disclosure fields and human captions retain their original values.
 do $$begin
 if exists(select 1 from photos p join gallery_original o using(id)where p.original_key is distinct from o.original_key or p.enhanced_key is distinct from o.enhanced_key
   or p.is_staged is distinct from o.is_staged or p.caption is distinct from o.caption)then raise exception 'Gallery controls changed a caption, original or AI disclosure';end if;
 if has_function_privilege('anon','public.studio_gallery_update(uuid,uuid,text,uuid,jsonb,jsonb)','execute')
   or has_function_privilege('anon','public.studio_named_account_active()','execute')
   or (select prosecdef from pg_proc where oid='public.studio_gallery_update(uuid,uuid,text,uuid,jsonb,jsonb)'::regprocedure)
   then raise exception 'Gallery RPC grants or invoker mode changed';end if;
 end$$;
 rollback;`;
 const file=join(temp,'assertions.sql');await writeFile(file,assertions);run('psql',[...psql,'-f',file]);
 receipt.status='passed';receipt.checks=['all ordered migrations apply','authenticated reorder commits exact contiguous order','repeat reorder is idempotent','stale order rejected without partial rows','added photo rejects stale snapshot','removed photo rejects stale snapshot','replacement with unchanged count rejects stale snapshot','duplicates and empty orders rejected','SQL-null expected cover selects canonical enhanced key and one main photo','repeat cover is idempotent and stale cover rejected','foreign property/photo rejected through caller scope','marketing role rejected after page load','anonymous account rejected','pending and processing deletion rejected','captions original keys enhanced keys and AI flags unchanged','public API role grants and SECURITY INVOKER preserved'];
}catch(error){receipt.status='failed';receipt.error=error.message;process.exitCode=1;}
finally{if(started)run('pg_ctl',['-D',join(temp,'data'),'stop','-m','fast']);await writeFile(join(temp,'receipt.json'),JSON.stringify(receipt,null,2));console.log(JSON.stringify({...receipt,receipt:join(temp,'receipt.json')},null,2));}
