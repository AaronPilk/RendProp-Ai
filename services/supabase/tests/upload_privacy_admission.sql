\set ON_ERROR_STOP on
begin;
do $$begin if current_database()not in('rendprop_privacy_audit','rendprop_privacy_audit_replay')or inet_server_addr()is not null then raise exception 'Use only owned privacy fixture';end if;end$$;
create temp table upload_checks(label text primary key,passed boolean not null);
create function pg_temp.ok(v boolean,label text)returns void language plpgsql as $$begin if v is distinct from true then raise exception 'UPLOAD FAIL: %',label;end if;insert into upload_checks values(label,true);end$$;
create function pg_temp.denied(command text,prefix text,label text)returns void language plpgsql as $$declare problem text;begin begin execute command;exception when others then problem:=sqlerrm;end;if problem is null or problem not like prefix||'%'then raise exception 'UPLOAD DENIAL: % expected %, got %',label,prefix,coalesce(problem,'no failure');end if;perform pg_temp.ok(true,label);end$$;
grant all on upload_checks to service_role,anon,authenticated;
create temp table fixture(a uuid,g uuid,o uuid,go uuid,l uuid,gl uuid,asset uuid);
do $$declare a uuid:=gen_random_uuid();g uuid:=gen_random_uuid();o uuid;go uuid;l uuid:=gen_random_uuid();gl uuid:=gen_random_uuid();begin
 insert into auth.users(id,email,is_anonymous)values(a,'named-upload@fixture.invalid',false),(g,'guest-upload@fixture.invalid',true);
 select org_id into o from memberships where user_id=a;select org_id into go from memberships where user_id=g;
 insert into listings(id,org_id,agent_id,address)values(l,o,a,'Named fixture'),(gl,go,g,'Guest fixture');
 update orgs set plan='starter',plan_source='manual',plan_expires_at=null where id=o;
 insert into fixture values(a,g,o,go,l,gl,gen_random_uuid());
end$$;
grant select on fixture to service_role,anon,authenticated;
create function pg_temp.ticket(o uuid,l uuid,id uuid,idem text)returns jsonb language sql as $$select jsonb_build_array(jsonb_build_object('id',id,'listing_id',l,'kind','photo','bucket','uploads','storage_key','uploads/'||o||'/'||l||'/'||id||'.jpg','bytes',10,'content_type','image/jpeg','content_type_declared',true,'idem_key',idem));$$;
select pg_temp.ok(not has_function_privilege(r,fn,'execute'),'upload private helper denies '||r||' '||fn)from unnest(array['anon','authenticated'])r cross join unnest(array['public.upload_new_admission(uuid,uuid,bigint)','public.media_privacy_drain(text)'])fn;
select pg_temp.ok(prosecdef and proconfig=array['search_path=""']::text[],'upload helper pins definer path')from pg_proc where oid='public.upload_new_admission(uuid,uuid,bigint)'::regprocedure;
set local role service_role;
do $$declare f record;r jsonb;begin select * into f from fixture;
 r:=reserve_upload_assets(f.a,pg_temp.ticket(f.o,f.l,f.asset,'named-fixture-idem'));
 perform pg_temp.ok(r#>>'{0,replayed}'='false'and(select held_bytes=20 from upload_reservations where asset_id=f.asset),'named account admits actual bounded transport hold');
 perform pg_temp.denied(format('select reserve_upload_assets(%L,%L::jsonb)',f.g,pg_temp.ticket(f.go,f.gl,gen_random_uuid(),'guest-fixture-idem')),'RP403:','unpaid anonymous cannot reserve upload');
 perform pg_temp.ok(not exists(select 1 from upload_reservations where org_id=f.go),'denied guest admission leaves no upload reservation');
end$$;
reset role;
update orgs set plan='starter',plan_source='apple',plan_expires_at=now()+interval '1 day'where id=(select go from fixture);
insert into apple_subscriptions(original_transaction_id,org_id,user_id,plan,environment,status,expires_at)select 'fixture-paid-guest',go,g,'starter','Sandbox','active',now()+interval '1 day'from fixture;
set local role service_role;
do $$declare f record;begin select * into f from fixture;perform pg_temp.denied(format('select reserve_upload_assets(%L,%L::jsonb)',f.g,pg_temp.ticket(f.go,f.gl,gen_random_uuid(),'sandbox-guest-idem')),'RP403:','Sandbox receipt cannot fund anonymous upload');end$$;
reset role;
update apple_subscriptions set environment='Production'where original_transaction_id='fixture-paid-guest';
-- The positive paid-guest case needs current serving authority as well as the
-- Apple receipt. These finite dollars and seven zero reserves are SYNTHETIC
-- fixture values, not a production price or cost attestation. Keep Sandbox and
-- buyer checks on the actual upload path; no manual authority bypass is used.
do $$declare f record;funding jsonb;begin
 select * into f from fixture;
 set local role service_role;
 funding:=provision_serving_funding(f.go,'retail','synthetic-upload-privacy-collection',null,400,0,
  now(),now()+interval '1 month',1,
  '{"storage":0,"delivery":0,"compute":0,"email":0,"support":0,"retention":0,"uncertainty":0}',repeat('a',64));
 reset role;
 update serving_funding set apple_original_transaction_id='fixture-paid-guest'
  where id=(funding->>'funding_id')::uuid and org_id=f.go and collection_ref='synthetic-upload-privacy-collection';
end$$;
set local role service_role;
do $$declare f record;r jsonb;begin select * into f from fixture;r:=reserve_upload_assets(f.g,pg_temp.ticket(f.go,f.gl,gen_random_uuid(),'production-guest-idem'));perform pg_temp.ok(r#>>'{0,replayed}'='false','server-bound Production paid guest can upload');end$$;
reset role;
update apple_subscriptions set user_id=(select a from fixture)where original_transaction_id='fixture-paid-guest';
set local role service_role;
do $$declare f record;begin select * into f from fixture;perform pg_temp.denied(format('select reserve_upload_assets(%L,%L::jsonb)',f.g,pg_temp.ticket(f.go,f.gl,gen_random_uuid(),'foreign-receipt-idem')),'RP403:','guest cannot borrow another account paid receipt');end$$;
reset role;
-- Synthetic historical windows are actual ledger rows, not a mock cap helper.
-- Spread over distinct days to stay under the unchanged 200 GiB/day wall.
insert into upload_reservations(asset_id,org_id,listing_id,actor_id,day,spec,held_bytes,spent_bytes,state,settled_at)
 select gen_random_uuid(),f.o,f.l,f.a,(date_trunc('month',now())+interval '1 day')::date,'{}',0,
  e.renders_per_month::bigint*12884901888+e.photo_edits_per_month::bigint*104857600-20,'completed',now()
 from fixture f cross join lateral public.org_entitlement(f.o)e;
set local role service_role;
do $$declare f record;r jsonb;begin select * into f from fixture;
 perform pg_temp.denied(format('select reserve_upload_assets(%L,%L::jsonb)',f.a,pg_temp.ticket(f.o,f.l,gen_random_uuid(),'over-month-idem')),'RP429:','monthly physical bytes include historical spent plus current held');
 r:=reserve_upload_assets(f.a,pg_temp.ticket(f.o,f.l,gen_random_uuid(),'named-fixture-idem'));
 perform pg_temp.ok(r#>>'{0,id}'=f.asset::text and r#>>'{0,replayed}'='true','already-admitted upload replays after monthly ceiling');
 perform pg_temp.denied('select media_privacy_drain(''arbitrary-path'')','RP400:','scheduler cannot choose arbitrary HTTP endpoint');
 perform pg_temp.denied('select media_privacy_drain(''uploads'')','RP503:','missing scheduler infrastructure remains actual failure');
end$$;
reset role;
select pg_temp.ok((select count(*)=2 and bool_and(held_bytes=20)from upload_reservations where state='open'),'failed admissions preserve exact admitted reservations');
select pg_temp.ok(not exists(select 1 from pg_proc where oid='public.reserve_upload_assets(uuid,jsonb)'::regprocedure and prosecdef),'reserve function preserves invoker authority');
select pg_temp.ok(position('perform 1 from public.orgs'in pg_get_functiondef('public.reserve_upload_assets(uuid,jsonb)'::regprocedure))<position('select * into l from listings'in pg_get_functiondef('public.reserve_upload_assets(uuid,jsonb)'::regprocedure)),'monthly admission locks org before listing');
select pg_temp.ok(position('continue;'in pg_get_functiondef('public.reserve_upload_assets(uuid,jsonb)'::regprocedure))<position('perform public.upload_new_admission'in pg_get_functiondef('public.reserve_upload_assets(uuid,jsonb)'::regprocedure)),'existing replay precedes new identity and monthly admission');
select count(*)from upload_checks;
select 'PASS: upload privacy assertions; fixtures rolled back.';
rollback;
