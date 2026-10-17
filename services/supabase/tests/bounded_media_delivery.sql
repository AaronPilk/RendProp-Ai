\set ON_ERROR_STOP on
begin;
do $$begin if current_database()<>'rendprop_bounded_media_audit'or inet_server_addr()is not null then raise exception 'Owned socket-only media test required';end if;end$$;
create temp table checks(label text primary key);
create function pg_temp.ok(v boolean,label text)returns void language plpgsql as $$begin if v is distinct from true then raise exception 'MEDIA FAIL: %',label;end if;insert into checks values(label);end$$;
create function pg_temp.denied(command text,prefix text,label text)returns void language plpgsql as $$declare e text;begin begin execute command;exception when others then e:=sqlerrm;end;if e is null or e not like prefix||'%'then raise exception 'MEDIA DENIAL: % expected %, got %',label,prefix,coalesce(e,'success');end if;perform pg_temp.ok(true,label);end$$;
grant all on checks to service_role,authenticated,anon;
create temp table fixture(a uuid,o uuid,l uuid,b uuid,other uuid,start timestamptz,finish timestamptz);
do $$declare a uuid:=gen_random_uuid();b uuid:=gen_random_uuid();o uuid;other uuid;l uuid:=gen_random_uuid();begin
 insert into auth.users(id,email)values(a,'media-owner@fixture.invalid'),(b,'media-peer@fixture.invalid');
 select org_id into o from memberships where user_id=a;select org_id into other from memberships where user_id=b;
 insert into listings(id,org_id,agent_id,address)values(l,o,a,'Synthetic media');update orgs set plan='pro',plan_source='manual',plan_expires_at=null where id=o;
 insert into fixture values(a,o,l,b,other,now()-interval '1 minute',now()+interval '1 day');end$$;
grant select on fixture to service_role,authenticated,anon;
create function pg_temp.tariff()returns jsonb language sql as $$select '{"r2_a_cents_per_million":450,"r2_b_cents_per_million":36,"worker_cents_per_million":30,"worker_cpu_cents_per_million_ms":2,"edge_cents_per_million":200,"db_cents":1,"logs_cents":1,"storage_cents_per_gb_month":1.5}'::jsonb$$;
create function pg_temp.reserves()returns jsonb language sql as $$select '{"delivery":3000,"compute":1500,"storage":50,"retention":50}'::jsonb$$;
select pg_temp.ok(not has_function_privilege(r,fn,'execute'),'private function denies '||r||' '||fn)from unnest(array['anon','authenticated'])r cross join unnest(array['public.media_delivery_admit(uuid,bigint,boolean)','public.media_upload_read_admit(uuid)','public.media_storage_reserve(uuid,text,text,bigint)','public.media_storage_deletion_ack(uuid,text,text,text)'])fn;
select pg_temp.ok(not has_function_privilege(r,p.oid,'execute'),'private provision denies '||r||' '||p.oid)from unnest(array['anon','authenticated'])r cross join pg_proc p where p.proname in('provision_media_delivery_budget','provision_media_account_reserve');
create function pg_temp.budget(o uuid,ref text,s timestamptz,e timestamptz,requests bigint,bytes bigint,storage bigint,tariff jsonb,reserves jsonb,evidence text)returns jsonb language plpgsql as $$declare v jsonb;begin
 if to_regprocedure('public.provision_media_account_reserve(text,text,text,text,timestamptz,timestamptz,bigint,jsonb,jsonb)')is not null then
  execute 'select public.provision_media_delivery_budget($1,$2,null,$3,$4,$5,$6,$7,$8,$9,$10,''synthetic-startup-account'')'into v using o,ref,s,e,requests,bytes,storage,tariff,reserves,evidence;
 else execute 'select public.provision_media_delivery_budget($1,$2,null,$3,$4,$5,$6,$7,$8,$9,$10)'into v using o,ref,s,e,requests,bytes,storage,tariff,reserves,evidence;end if;return v;end$$;
select pg_temp.ok(not has_table_privilege(r,t,'insert,update,delete'),'journal is service-read-only '||r||' '||t)from unnest(array['anon','authenticated','service_role'])r cross join unnest(array['public.media_delivery_budgets','public.media_storage_receipts'])t;
select pg_temp.ok(prosecdef and proconfig=array['search_path=""']::text[],'exact definer search path '||proname)from pg_proc where proname in('provision_media_delivery_budget','media_delivery_admit','media_storage_reserve','media_storage_deletion_ack','media_storage_before_write');
set local role service_role;
do $$declare f record;v jsonb;begin select * into f from fixture;
 if to_regprocedure('public.provision_media_account_reserve(text,text,text,text,timestamptz,timestamptz,bigint,jsonb,jsonb)')is not null then
  execute 'select provision_media_account_reserve(''synthetic-startup-account'',''9c332c75b96cc642621dad5d86d4bf18'',''owner_paid_cash'',$1,$2,$3,100000,$4,$5)'into v using repeat('d',64),f.start,f.finish+interval '121 days',pg_temp.tariff(),'{"storage":0,"delivery":5000,"compute":5000,"email":0,"support":0,"retention":0,"uncertainty":0}'::jsonb;
  perform pg_temp.ok(v->>'reserved'='true','synthetic paid startup account boundary held once');
  perform pg_temp.ok(to_regprocedure('public.provision_media_delivery_budget(uuid,text,uuid,timestamptz,timestamptz,bigint,bigint,bigint,jsonb,jsonb,text)')is null,'pooled overlay removes old unbound provisioning signature');
 end if;
end$$;
do $$declare f record;r jsonb;key text;begin select * into f from fixture;key:='uploads/'||f.o||'/'||f.l||'/object.jpg';
 perform pg_temp.denied(format('select media_delivery_admit(%L,0,true)',f.o),'RP503:','public/private gateway cannot use unbudgeted legacy');
 r:=media_delivery_admit(f.o,0,false);perform pg_temp.ok(r->>'legacy_unbudgeted'='true','only never-funded internal legacy recovery compatible');
 perform pg_temp.denied(format('select pg_temp.budget(%L,''bad-floor'',%L,%L,20,100,100,%L,%L,%L)',f.o,f.start,f.finish,(pg_temp.tariff()-'r2_a_cents_per_million')::text,pg_temp.reserves()::text,repeat('a',64)),'RP400:','missing write tariff rejected');
 perform pg_temp.denied(format('select pg_temp.budget(%L,''bad-reserve'',%L,%L,20,100,100,%L,%L,%L)',f.o,f.start,f.finish,pg_temp.tariff()::text,'{"delivery":0,"compute":0,"storage":0,"retention":0}',repeat('a',64)),'RP402:','underfunded whole period rejected');
 r:=pg_temp.budget(f.o,'synthetic-media-budget',f.start,f.finish,20,100,100,pg_temp.tariff(),pg_temp.reserves(),repeat('a',64));
 perform pg_temp.ok(r->>'replay'='false','operator-attested never-funded budget admitted');
 r:=media_delivery_admit(f.o,90,true);perform pg_temp.ok(r->>'admitted'='true'and r->>'legacy_unbudgeted'='false','bytes spent before transport');
 perform pg_temp.denied(format('select media_delivery_admit(%L,11,true)',f.o),'RP429:','range/full body exceeds remaining bytes');
 r:=pg_temp.budget(f.o,'synthetic-media-budget',f.start,f.finish,20,100,100,pg_temp.tariff(),pg_temp.reserves(),repeat('a',64));
 perform pg_temp.ok(r->>'replay'='true'and(select used_bytes=90 and used_requests=1 from media_delivery_budgets where org_id=f.o),'budget replay does not renew allowances');
 perform pg_temp.denied(format('select pg_temp.budget(%L,''synthetic-media-budget'',%L,%L,21,100,100,%L,%L,%L)',f.o,f.start,f.finish,pg_temp.tariff()::text,pg_temp.reserves()::text,repeat('a',64)),'RP409:','budget identity immutable');
 perform pg_temp.denied(format('select pg_temp.budget(%L,''overlap-budget'',%L,%L,20,100,100,%L,%L,%L)',f.o,f.start,f.finish,pg_temp.tariff()::text,pg_temp.reserves()::text,repeat('a',64)),'RP409:','new reference cannot reset current budget');
 r:=media_storage_reserve(f.o,'uploads',key,60);perform pg_temp.ok(r->>'replay'='false','prewrite holds exact storage');
 r:=media_storage_reserve(f.o,'uploads',key,60);perform pg_temp.ok(r->>'replay'='true'and(select used_requests=3 from media_delivery_budgets where org_id=f.o),'replay spends write request without duplicated storage');
 perform pg_temp.denied(format('select media_storage_reserve(%L,''uploads'',%L,61)',f.o,key),'RP409:','size cannot grow after hold');
 perform pg_temp.denied(format('select media_storage_reserve(%L,''uploads'',%L,1)',f.other,key),'RP403:','other workspace cannot borrow namespace');
 perform pg_temp.denied(format('select media_storage_reserve(%L,''uploads'',%L,41)',f.o,key||'other'),'RP429:','storage liability enforces total bytes');
 perform pg_temp.denied(format('select media_storage_reserve(%L,''renders'',%L,1)',f.other,'renders/'||f.l||'/worker.mp4'),'RP403:','legacy worker key resolves actual listing owner');
 r:=media_storage_reserve(f.o,'renders','renders/'||f.l||'/worker.mp4',10);perform pg_temp.ok(r->>'reserved'='true','legacy worker namespace remains compatible');
 r:=media_storage_deletion_ack(f.o,'uploads',key,repeat('b',64));perform pg_temp.ok(r->>'acknowledged'='true','exact physical deletion evidence acknowledged');
 perform pg_temp.denied(format('select media_storage_deletion_ack(%L,''uploads'',%L,%L)',f.o,key,repeat('c',64)),'RP409:','ack evidence immutable');
 perform pg_temp.denied(format('select media_storage_reserve(%L,''uploads'',%L,60)',f.o,key),'RP409:','released key cannot silently be reused');
 r:=media_storage_reserve(f.o,'uploads',key||'new',60);perform pg_temp.ok(r->>'reserved'='true','only acknowledged deletion releases storage');
end$$;
reset role;
do $$declare f record;r jsonb;fund public.serving_funding;budget_id uuid;old_cash bigint;statement text;begin select * into f from fixture;
 -- Legacy physical bytes remain owed when a later financial budget is issued.
 set local role service_role;
 perform media_storage_reserve(f.other,'uploads','uploads/'||f.other||'/prior-deleted',50);
 perform media_storage_reserve(f.other,'uploads','uploads/'||f.other||'/prior-retained',60);
 perform media_storage_deletion_ack(f.other,'uploads','uploads/'||f.other||'/prior-deleted',repeat('c',64));
 reset role;
 -- Synthetic current financial receipt. No production rate or cash claim.
 set local role service_role;
 r:=provision_serving_funding(f.other,'retail','synthetic-media-funded',null,24000,0,now(),now()+interval '1 month',1,'{"storage":50,"delivery":3000,"compute":1500,"email":0,"support":0,"retention":50,"uncertainty":0}',repeat('a',64));
 perform pg_temp.denied(format('select media_delivery_admit(%L,0,false)',f.other),'RP503:','funded missing media budget cannot use legacy exemption');
 perform pg_temp.denied(format('select media_storage_reserve(%L,''uploads'',%L,1)',f.other,'uploads/'||f.other||'/new'),'RP503:','funded storage missing budget refuses before PUT');
 select * into fund from serving_funding where org_id=f.other and collection_ref='synthetic-media-funded';
 statement:=format('select public.provision_media_delivery_budget(%L,''synthetic-retained-budget'',%L,%L,%L,20,100,%%s,%L,%L,%L',f.other,fund.id,fund.starts_at,fund.retention_ends_at,pg_temp.tariff()::text,pg_temp.reserves()::text,repeat('e',64));
 if to_regprocedure('public.provision_media_account_reserve(text,text,text,text,timestamptz,timestamptz,bigint,jsonb,jsonb)')is not null then
  statement:=statement||',''synthetic-startup-account'')';select allocated_org_cents into old_cash from media_account_reserves where receipt_ref='synthetic-startup-account';
 else statement:=statement||')';end if;
 perform pg_temp.denied(format(statement,59),'RP402: Media storage budget is below retained physical liability','read-only funding cannot underprice earlier physical custody');
 perform pg_temp.ok(not exists(select 1 from media_delivery_budgets where org_id=f.other)and(select count(*)=1 and sum(bytes)=60 from media_storage_receipts where org_id=f.other and deleted_at is null),'refused floor preserves every current physical receipt and creates no budget');
 if old_cash is not null then perform pg_temp.ok((select allocated_org_cents=old_cash from media_account_reserves where receipt_ref='synthetic-startup-account'),'refused physical floor allocates no startup cash');end if;
 execute format(statement,60)into r;
 perform pg_temp.ok(r->>'replay'='false','exact retained-byte floor permits fully funded read budget');
 execute format(statement,60)into r;
 perform pg_temp.ok(r->>'replay'='true','physical floor preserves exact immutable funding replay');
 r:=media_delivery_admit(f.other,1,true);perform pg_temp.ok(r->>'admitted'='true'and r->>'legacy_unbudgeted'='false','existing paid read remains funded only with complete physical floor');
 reset role;
end$$;
-- Real writer trigger behavior, not only a seven-name inventory.
do $$declare a uuid:=gen_random_uuid();o uuid;project uuid:=gen_random_uuid();voice uuid:=gen_random_uuid();logo uuid:=gen_random_uuid();output uuid:=gen_random_uuid();begin
 insert into auth.users(id,email)values(a,'project-media@fixture.invalid');select org_id into o from memberships where user_id=a;
 insert into studio_project_media(id,actor_id,org_id,sha256,bytes,mime,filename,modified)values(project,a,o,repeat('e',64),8388609,'image/jpeg','synthetic.jpg',0);
 perform pg_temp.ok((select count(*)=2 and sum(bytes)=8388609 from media_storage_receipts where org_id=o and object_key like 'studio-project/'||o||'/'||a||'/'||project||'/%'),'project prewrite reserves both exact chunk liabilities');
 perform pg_temp.denied(format('update studio_project_media set bytes=8388610 where id=%L',project),'RP409:','project metadata cannot expand physical authority');
 insert into voice_storage_reservations(id,actor_id,org_id,storage_key,created_at,write_deadline)values(voice,a,o,'ai-voice/'||o||'/'||voice||'.mp3',now(),now()+interval '15 minutes');
 perform pg_temp.ok((select bytes=20971520 from media_storage_receipts where object_key='ai-voice/'||o||'/'||voice||'.mp3'),'voice predispatch caps physical liability');
 insert into private_ai_outputs(id,org_id,user_id,bucket,storage_key,bytes)values(output,o,a,'renders','ai-router/'||o||'/fixture.jpg',5);
 perform pg_temp.ok((select bytes=5 from media_storage_receipts where object_key='ai-router/'||o||'/fixture.jpg'),'private output journals before write');
 delete from private_ai_outputs where id=output;
 perform pg_temp.ok((select bytes=5 and deleted_at is null from media_storage_receipts where object_key='ai-router/'||o||'/fixture.jpg'),'metadata deletion cannot acknowledge physical deletion');
 insert into org_brand_assets(id,org_id,actor_id,object_key,public_url,bytes,content_type,sha256)values(logo,o,a,'renders/'||o||'/brand/fixture.jpg','https://fixture.invalid/logo',20,'image/jpeg',repeat('f',64));
 perform pg_temp.ok((select bytes=20 from media_storage_receipts where object_key='renders/'||o||'/brand/fixture.jpg'),'logo journals exact known bytes');
 perform pg_temp.denied(format('update org_brand_assets set bytes=21 where id=%L',logo),'RP409:','logo cannot grow after journal');
end$$;
select pg_temp.ok((select count(*)=7 from pg_trigger where tgname in('media_storage_private_output','media_storage_upload','media_storage_project','media_storage_voice','media_storage_erase','media_storage_presenter','media_storage_logo')),'all seven physical writer journals covered');
select count(*)from checks;
select 'PASS: bounded media assertions; all synthetic fixtures rolled back';
rollback;
