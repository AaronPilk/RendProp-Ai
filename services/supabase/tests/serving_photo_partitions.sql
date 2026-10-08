\set ON_ERROR_STOP on
begin;
-- Funded-model regression: pin funded serving mode for this transaction. The
-- live default since 2026-10-08 is ceiling mode (migration 20261008201736);
-- ceiling-mode admission is covered by launch_blockers.sql.
update public.app_config set value=value||'{"mode":"funded"}'::jsonb where key='serving_mode';
create temporary table package_assertions(n integer not null default 0);
insert into package_assertions default values;
grant all on package_assertions to service_role;
create function pg_temp.pcheck(ok boolean,label text)returns void language plpgsql as $$begin
 if ok is distinct from true then raise exception 'PACKAGE FAIL: %',label;end if;
 update package_assertions set n=n+1;
end$$;
create function pg_temp.prefuse(statement text,expected text,label text)returns void language plpgsql as $$begin
 begin execute statement;exception when others then
  if position(expected in sqlerrm)>0 then perform pg_temp.pcheck(true,label);return;end if;raise;end;
 raise exception 'PACKAGE FAIL expected %: %',expected,label;
end$$;
insert into auth.users(id,email,is_anonymous,email_confirmed_at)values
 ('e1000000-0000-4000-8000-000000000001','package-owner@example.invalid',false,now()),
 ('e1000000-0000-4000-8000-000000000002','package-member@example.invalid',false,now());
insert into orgs(id,name,plan,plan_source)values
 ('e2000000-0000-4000-8000-000000000001','Synthetic photo package','pro','manual'),
 ('e2000000-0000-4000-8000-000000000002','Synthetic unchanged cash wallet','pro','manual'),
 ('e2000000-0000-4000-8000-000000000003','Synthetic empty package','pro','manual');
insert into memberships(user_id,org_id,role)select 'e1000000-0000-4000-8000-000000000001',id,'owner'from orgs where id::text like 'e2000000%';
insert into memberships(user_id,org_id,role)values('e1000000-0000-4000-8000-000000000002','e2000000-0000-4000-8000-000000000001','agent');
set local role service_role;
do $$declare
 u uuid:='e1000000-0000-4000-8000-000000000001';v uuid:='e1000000-0000-4000-8000-000000000002';o uuid:='e2000000-0000-4000-8000-000000000001';
 plain uuid:='e2000000-0000-4000-8000-000000000002';empty_org uuid:='e2000000-0000-4000-8000-000000000003';
 f uuid;plain_f uuid;empty_f uuid;r jsonb;role_name text;sig text;t timestamptz:=now()-interval '1 minute';e timestamptz;
 components jsonb:='{"storage":10,"delivery":10,"compute":10,"email":10,"support":10,"retention":10,"uncertainty":10}';
 policy text:='one-gemini-1k-4096-plus-one-kontext-20261007';tariff text:='published-standard-20261006';
begin
 e:=t+interval '1 month';sig:='public.provision_serving_photo_partition(uuid,integer,integer,bigint,text,text,text)';
 foreach role_name in array array['anon','authenticated']loop
  perform pg_temp.pcheck(not has_function_privilege(role_name,sig,'execute'),'service-only package provisioning');
  perform pg_temp.pcheck(not has_function_privilege(role_name,'public.serving_photo_package_context(uuid,uuid)','execute'),'service-only package presentation');
  perform pg_temp.pcheck(not has_table_privilege(role_name,'serving_photo_partitions','SELECT,INSERT,UPDATE,DELETE')and not has_table_privilege(role_name,'serving_photo_admissions','SELECT,INSERT,UPDATE,DELETE'),'clients cannot inspect or mint package authority');
 end loop;
 perform pg_temp.pcheck(not has_table_privilege('service_role','serving_photo_partitions','INSERT,UPDATE,DELETE')and not has_table_privilege('service_role','serving_photo_admissions','INSERT,UPDATE,DELETE'),'service cannot rewrite admission tombstones');
 f:=(provision_serving_funding(o,'retail','synthetic-photo-package',null,1000,0,t,e,1,components,repeat('a',64))->>'funding_id')::uuid;
 perform pg_temp.prefuse(format('select provision_serving_photo_partition(%L,0,3,100,%L,%L,%L)',f,policy,tariff,repeat('b',64)),'RP402','package cannot exceed inclusive funded cash');
 perform pg_temp.prefuse(format('select provision_serving_photo_partition(%L,0,2,100,%L,''changed-tariff'',%L)',f,policy,repeat('b',64)),'RP400','unknown tariff refused');
 r:=provision_serving_photo_partition(f,0,2,100,policy,tariff,repeat('b',64));
 perform pg_temp.pcheck(r->>'protected_photo_cents'='71'and r->>'other_ai_cents'='100','aggregate full chain rounded up and separate wallet');
 perform pg_temp.pcheck((provision_serving_photo_partition(f,0,2,100,policy,tariff,repeat('b',64))->>'replay')::boolean,'same receipt replay cannot replenish');
 perform pg_temp.prefuse(format('select provision_serving_photo_partition(%L,0,1,100,%L,%L,%L)',f,policy,tariff,repeat('b',64)),'RP409','counts immutable');
 perform pg_temp.prefuse(format('select provision_serving_photo_partition(%L,0,2,101,%L,%L,%L)',f,policy,tariff,repeat('b',64)),'RP409','wallet immutable');
 perform pg_temp.prefuse(format('select serving_cost_reserve(%L,%L,''package-helper-too-much'',''photo.suggest'',''gemini'',''gemini-3.6-flash'',%L,101,%L)',u,o,repeat('a',64),tariff),'RP402','helper cannot consume protected photo cash');
 perform pg_temp.pcheck(not exists(select 1 from serving_cost_reservations where funding_id=f),'failed helper consumes no cash or count');
 perform serving_cost_reserve(u,o,'package-helper-full','photo.suggest','gemini','gemini-3.6-flash',repeat('a',64),100,tariff);
 perform serving_cost_finish(u,o,'package-helper-full','photo.suggest','uncertain',null);
 perform pg_temp.prefuse(format('select serving_cost_reserve(%L,%L,''package-other-too-much'',''coach.chat'',''anthropic'',''synthetic'',%L,0.0001,%L)',u,o,repeat('a',64),tariff),'RP402','other AI cannot consume protected photo cash');
 perform pg_temp.prefuse(format('select serving_cost_reserve(%L,%L,''package-unbound-fallback'',''photo.sky:1'',''fal'',''fal-ai/flux-pro/kontext'',%L,4,%L)',u,o,repeat('a',64),tariff),'RP409','fallback requires exact prior primary');
 perform pg_temp.prefuse(format('select serving_cost_reserve(%L,%L,''package-wrong-quote'',''photo.sky:0'',''gemini'',''gemini-3.1-flash-image'',%L,31.1297,%L)',u,o,repeat('a',64),tariff),'RP403','primary quote immutable');
 perform pg_temp.prefuse(format('select serving_cost_reserve(%L,%L,''package-extra-stage'',''photo.sky:2'',''fal'',''fal-ai/flux-pro/kontext'',%L,4,%L)',u,o,repeat('a',64),tariff),'RP403','no third photo attempt');
 perform serving_cost_reserve(u,o,'package-photo-first','photo.sky:0','gemini','gemini-3.1-flash-image',repeat('a',64),31.1296,tariff);
 perform serving_cost_finish(u,o,'package-photo-first','photo.sky:0','rejected',400);
 perform pg_temp.prefuse(format('select serving_cost_reserve(%L,%L,''package-photo-first'',''photo.sky:1'',''fal'',''fal-ai/flux-pro/kontext'',%L,4,%L)',u,o,repeat('b',64),tariff),'RP409','fallback cannot change input');
 perform serving_cost_reserve(u,o,'package-photo-first','photo.sky:1','fal','fal-ai/flux-pro/kontext',repeat('a',64),4,tariff);
 perform serving_cost_finish(u,o,'package-photo-first','photo.sky:1','uncertain',null);
 perform serving_cost_reserve(v,o,'package-photo-second','photo.twilight:0','gemini','gemini-3.1-flash-image',repeat('a',64),31.1296,tariff);
 perform serving_cost_reserve(v,o,'package-photo-second','photo.twilight:1','fal','flux-pro/kontext',repeat('a',64),4,tariff);
 perform pg_temp.pcheck((select count(*)=2 from serving_photo_admissions where funding_id=f),'members share exact two lifetime interval admissions');
 perform pg_temp.prefuse(format('select serving_cost_reserve(%L,%L,''package-photo-third'',''photo.lawn:0'',''gemini'',''gemini-3.1-flash-image'',%L,31.1296,%L)',u,o,repeat('a',64),tariff),'RP402','rejected first primary cannot recycle photo admission or borrow helper wallet');
 perform pg_temp.pcheck((select count(*)=5 from serving_cost_reservations where funding_id=f),'failed admissions leave exact five real attempt rows');
 r:=serving_photo_package_context(u,o);
 perform pg_temp.pcheck(r->>'org_id'=o::text and r->'photo_admissions'='{"cap":2,"used":2,"remaining":0}'::jsonb
  and r->'other_ai'='{"cap_cents":100,"used_cents":100,"remaining_cents":0}'::jsonb,'current package presentation binds exact own counters and independent wallet');
 perform pg_temp.pcheck(serving_photo_package_context(gen_random_uuid(),o)is null and serving_photo_package_context(v,plain)is null,'outsider and foreign workspace package withheld');
 -- Existing collected funding remains a shared cash wallet unless separately
 -- partitioned before its first attempt; neither history nor saved results is rewritten.
 plain_f:=(provision_serving_funding(plain,'retail','synthetic-plain-wallet',null,1000,0,t,e,1,components,repeat('a',64))->>'funding_id')::uuid;
 perform serving_cost_reserve(u,plain,'existing-wallet-helper','photo.suggest','gemini','synthetic',repeat('a',64),170,'synthetic');
 perform pg_temp.pcheck((select hold_cents=170 from serving_cost_reservations where funding_id=plain_f),'unpartitioned funding unchanged');
 perform pg_temp.pcheck(serving_photo_package_context(u,plain)is null,'unconfigured package cannot replace legacy nominal quotas');
 perform pg_temp.prefuse(format('select provision_serving_photo_partition(%L,0,1,100,%L,%L,%L)',plain_f,policy,tariff,repeat('b',64)),'RP409','no retroactive reinterpretation of old financial interval');
 empty_f:=(provision_serving_funding(empty_org,'retail','synthetic-empty-package',null,1000,0,t,e,1,components,repeat('a',64))->>'funding_id')::uuid;
 perform provision_serving_photo_partition(empty_f,0,0,180,policy,tariff,repeat('b',64));
 perform pg_temp.prefuse(format('select serving_cost_reserve(%L,%L,''empty-photo-attempt'',''photo.sky:0'',''gemini'',''gemini-3.1-flash-image'',%L,31.1296,%L)',u,empty_org,repeat('a',64),tariff),'RP402','photo cannot spend a larger other AI wallet');
 perform serving_cost_reserve(u,empty_org,'empty-other-attempt','coach.chat','anthropic','synthetic',repeat('a',64),180,tariff);
 perform pg_temp.pcheck(not exists(select 1 from serving_photo_admissions where funding_id=empty_f),'empty package grants no photos');
end$$;
reset role;
-- A deliberately corrupted/legacy overlapping receipt is inserted by the
-- owned database audit role, never by a service/client money writer. A package
-- must refuse it rather than display/spend an arbitrary current receipt.
create temporary table overlapping_package_funding(id uuid);
with copied as(
 insert into serving_funding(org_id,source,collection_ref,actor_id,net_receipts_cents,sponsored_cents,starts_at,ends_at,retention_ends_at,
  service_months,recurring_reserve_cents,reserve_components,evidence_sha256)
 select org_id,source,'synthetic-overlapping-legacy-receipt',actor_id,net_receipts_cents,sponsored_cents,starts_at,ends_at,retention_ends_at,
  service_months,recurring_reserve_cents,reserve_components,evidence_sha256 from serving_funding where collection_ref='synthetic-photo-package'
 returning id
)insert into overlapping_package_funding select id from copied;
insert into serving_funding_slices
 select copied.id,0,original.org_id,original.starts_at,original.ends_at,250,70
 from overlapping_package_funding copied cross join serving_funding original where original.collection_ref='synthetic-photo-package';
grant select on overlapping_package_funding to service_role;
set local role service_role;
select pg_temp.prefuse('select serving_photo_package_context(''e1000000-0000-4000-8000-000000000001'',''e2000000-0000-4000-8000-000000000001'')','RP409','overlapping current receipt cannot display arbitrary package');
select pg_temp.prefuse('select serving_cost_reserve(''e1000000-0000-4000-8000-000000000001'',''e2000000-0000-4000-8000-000000000001'',''overlapping-photo-attempt'',''photo.sky:0'',''gemini'',''gemini-3.1-flash-image'',repeat(''a'',64),31.1296,''published-standard-20261006'')','RP409','overlapping receipt cannot switch package spending authority');
select pg_temp.prefuse('select provision_serving_photo_partition(id,0,1,100,''one-gemini-1k-4096-plus-one-kontext-20261007'',''published-standard-20261006'',repeat(''b'',64))from overlapping_package_funding','RP409','overlapping receipt cannot mint another partition');
reset role;
select 'PASS '||n||' photo partition assertions'from package_assertions;
rollback;
