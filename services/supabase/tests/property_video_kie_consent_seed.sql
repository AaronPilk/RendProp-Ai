-- K4: what the ACTUAL docs/handoff/KIE-ACTIVATION.sql seeds, and what it admits.
-- The driver (property_video_kie_consent_seed_pg.py) applies every migration to
-- an owned disposable Postgres, publishes a SYNTHETIC processor-permission
-- contract, runs the real activation script with
--   -v processor_disclosure='<identifier>' and the three exact baselines,
-- then prepends BEGIN + the existing synthetic property/source seed, the
-- canonical identity and the scope-consent helpers before this file, and rolls
-- back. No provider, encoded media, network or production value is involved;
-- the activation happens only inside that disposable database.
-- The driver hands the disclosure identifier in as :'processor_disclosure'.
select set_config('rendprop.kc_processor_disclosure',:'processor_disclosure',false);
create temporary table kc_checks(n integer);insert into kc_checks values(0);grant all on kc_checks to service_role,authenticated;
create function pg_temp.kc_ok(v boolean,label text)returns void language plpgsql as $$begin if v is distinct from true then raise exception'KIE-SEED FAIL: %',label;end if;update kc_checks set n=n+1;end$$;
create function pg_temp.kc_refuse(command text,needle text,label text)returns void language plpgsql as $$begin begin execute command;exception when others then if position(needle in sqlerrm)>0 then perform pg_temp.kc_ok(true,label);return;end if;raise;end;raise exception'KIE-SEED FAIL: allowed %',label;end$$;
create function pg_temp.kc_disclosure()returns text language sql stable as $$select current_setting('rendprop.kc_processor_disclosure',true)$$;
create function pg_temp.kc_record()returns jsonb language sql stable as $$select value from app_config where key='property_video_quality_kie_activation'$$;

-- 1. The exact seed shape the activation wrote.
select pg_temp.kc_ok((select value from app_config where key='property_video_quality')='{"enabled":true,"profile":"kie-kling3-4k-steady-v1","vendor_content_license":"kie-terms-2025-08-01-section-3-owner-accepted"}'::jsonb,'selector is exactly the acknowledged Kie selector');
select pg_temp.kc_ok((select enabled from ai_routes where id='7f2c9a3e-4b1d-4e8a-9c55-1d6e0b7a4f21'),'pinned Kie route row is enabled');
select pg_temp.kc_ok((select count(*)=1 from ai_routes where enabled and provider='kie'),'only the pinned Kie row was enabled');
select pg_temp.kc_ok((select count(*)=0 from ai_routes where id<>'7f2c9a3e-4b1d-4e8a-9c55-1d6e0b7a4f21'and updated_at>(select activated_at from(select(pg_temp.kc_record()->>'activated_at')::timestamptz activated_at)t)),'no other route row was touched');
select pg_temp.kc_ok(pg_temp.kc_record()is not null and jsonb_typeof(pg_temp.kc_record())='object','activation record exists');
select pg_temp.kc_ok((select array_agg(k order by k)from jsonb_object_keys(pg_temp.kc_record())k)=array['activated_at','consent_disclosure_revision','previous_selector','processor_disclosure','profile','rollback_mode','rolled_back_at','route_disabled_at','route_enabled_before','route_id','vendor_content_license'],'activation record has exactly the documented keys');
select pg_temp.kc_ok(pg_temp.kc_record()->>'profile'='kie-kling3-4k-steady-v1'and pg_temp.kc_record()->>'route_id'='7f2c9a3e-4b1d-4e8a-9c55-1d6e0b7a4f21','record names the profile and the pinned row');
select pg_temp.kc_ok(pg_temp.kc_record()->'previous_selector'='{"present":true,"value":{"enabled":false,"profile":"fal-kling3-4k-v1"}}'::jsonb,'record saved the exact migration-default previous selector for KIE-ROLLBACK.sql');
select pg_temp.kc_ok(pg_temp.kc_record()->'route_enabled_before'='false'::jsonb,'record saved the row as OFF before activation');
select pg_temp.kc_ok(pg_temp.kc_record()->>'processor_disclosure'=pg_temp.kc_disclosure()and length(pg_temp.kc_disclosure())between 1 and 200,'record saved the -v processor_disclosure identifier verbatim');
select pg_temp.kc_ok(pg_temp.kc_record()->>'consent_disclosure_revision'='owned-db-fixture-r1','record saved the published disclosure_revision');
select pg_temp.kc_ok(pg_temp.kc_record()->>'vendor_content_license'='kie-terms-2025-08-01-section-3-owner-accepted','record saved the content-license acknowledgement');
select pg_temp.kc_ok((pg_temp.kc_record()->>'activated_at')::timestamptz between now()-interval'10 minutes'and now(),'record is stamped with the activation time');
select pg_temp.kc_ok(pg_temp.kc_record()->'rolled_back_at'='null'::jsonb and pg_temp.kc_record()->'rollback_mode'='null'::jsonb and pg_temp.kc_record()->'route_disabled_at'='null'::jsonb,'record is not rolled back');
select pg_temp.kc_ok((select count(*)from app_config where key in('property_video_quality_hold','property_video_kie_test_grants'))=0,'activation created no hold and no grant');
select pg_temp.kc_ok(not exists(select 1 from property_video_kie_test_grants)and not exists(select 1 from property_video_jobs),'activation created no job and no grant');
update app_config set value=jsonb_set(value,'{enabled}','true')where key='property_video_jobs';

-- 2. The published contract, as the runtime reads it, and the global selector.
set local role service_role;
select pg_temp.kc_ok(property_video_processor_consent_current()='{"token":"property-video-jobs-v2","disclosure_revision":"owned-db-fixture-r1","processors":["fal","kie"],"profiles":["kie-kling3-4k-steady-v1"]}'::jsonb,'the published processor contract is read back exactly');
select pg_temp.kc_ok(property_video_quality_profile()='kie-kling3-4k-steady-v1','the global selector now names the Kie profile (no grant involved)');
select pg_temp.kc_ok(property_video_quality_profile_for((select actor from bf),pg_temp.kg_recipe(1),null)='kie-kling3-4k-steady-v1','a request without a grant resolves to the Kie profile');

-- 3. Admission: the current v2 permission admits; v1, missing and stale refuse.
select pg_temp.kc_refuse($q$select property_video_job_admit_v2((select actor from bf),pg_temp.kg_recipe(1),335,'kie-kling3-4k-steady-v1',null,null)$q$,'RP403: Allow AI processing','missing permission is refused');
select pg_temp.kc_refuse($q$select property_video_job_admit_v2((select actor from bf),pg_temp.kg_recipe(1),335,'kie-kling3-4k-steady-v1','{"token":"property-video-jobs-v1"}',null)$q$,'RP403: Allow the listed AI processors','original v1 permission is refused under the activated selector');
select pg_temp.kc_refuse($q$select property_video_job_admit_v2((select actor from bf),pg_temp.kg_recipe(1),335,'kie-kling3-4k-steady-v1','{"token":"property-video-jobs-v2","disclosure_revision":"stale"}',null)$q$,'RP403: Allow the current AI processor','a stale v2 revision is refused');
select pg_temp.kc_refuse($q$select property_video_job_admit((select actor from bf),pg_temp.kg_recipe(1),335,'kie-kling3-4k-steady-v1')$q$,'RP403: Allow the listed AI processors','the legacy v1 admission API cannot admit a Kie job');
select pg_temp.kc_refuse($q$select property_video_job_admit_v2((select actor from bf),pg_temp.kg_recipe(1),335,'fal-kling3-4k-v1',pg_temp.kg_permission(),null)$q$,'RP409','a stale FAL quote cannot admit under the Kie selector');
select pg_temp.kc_ok(not exists(select 1 from property_video_jobs),'every refusal creates no job');
create temporary table kc_job as select property_video_job_admit_v2((select actor from bf),pg_temp.kg_recipe(1),335,'kie-kling3-4k-steady-v1',pg_temp.kg_permission(),null)a;grant select on kc_job to service_role;
select pg_temp.kc_ok((select a->>'accepted'='true'from kc_job),'the current v2 permission admits a two-source Kie job');
select pg_temp.kc_ok((select a#>>'{job,quality_profile}'='kie-kling3-4k-steady-v1'and a#>>'{job,consent_revision}'='property-video-jobs-v2'and a#>>'{job,processor_consent,disclosure_revision}'='owned-db-fixture-r1'and a#>'{job,kie_test_grant_id}'='null'::jsonb from kc_job),'the admitted job carries the Kie profile, the v2 permission and no grant');
select pg_temp.kc_ok((select(a#>'{job,processor_consent}')-'recorded_at'='{"token":"property-video-jobs-v2","disclosure_revision":"owned-db-fixture-r1","processors":["fal","kie"]}'::jsonb from kc_job),'the saved permission records the contract processors');
select pg_temp.kc_ok((select quality_identity=pg_temp.kie()from property_video_jobs),'the frozen identity equals the canonical identity file');
select pg_temp.kc_ok((select deadline=created_at+interval'24 hours'from property_video_jobs),'the Kie job has the 24 h deadline');
-- The worker's dispatch authority for a globally activated job: the exact evidence engine.ts checks.
create temporary table kc_claim as select property_video_job_claim((select(a#>>'{job,id}')::uuid from kc_job),'slot-0')c;grant select on kc_claim to service_role;
select pg_temp.kc_ok((select c->>'action'='dispatch'from kc_claim),'the worker obtains a dispatch lease');
create temporary table kc_authority as select property_video_kie_dispatch_authority((select(c#>>'{job,id}')::uuid from kc_claim),(select(c#>>'{source,lease_token}')::uuid from kc_claim),(select(c#>>'{source,attempt_id}')::uuid from kc_claim))e;grant select on kc_authority to service_role;
select pg_temp.kc_ok((select e->>'authority'='activated_profile'and(select array_agg(k order by k)from jsonb_object_keys(e)k)=array['attempt_id','authority','job_id']and e->>'job_id'=(select a#>>'{job,id}'from kc_job)from kc_authority),'activated-profile authority has exactly the shape engine.ts accepts');
select pg_temp.kc_ok(not exists(select 1 from property_video_kie_test_grant_uses)and not exists(select 1 from app_video_cost_reservations)and not exists(select 1 from cost_ledger),'authority alone consumes no grant, hold or ledger row');
reset role;
-- A rotated disclosure makes the activation record's saved revision historical, not the admitted job's.
update app_config set value=jsonb_set(value,'{disclosure_revision}','"owned-db-fixture-r2"')where key='property_video_processor_consent';
set local role service_role;
select pg_temp.kc_refuse($q$select property_video_job_admit_v2((select actor from bf),pg_temp.kg_recipe(2),335,'kie-kling3-4k-steady-v1',pg_temp.kg_permission(),null)$q$,'RP403: Allow the current AI processor','after a disclosure rotation the previous revision no longer admits');
select pg_temp.kc_ok((select a#>>'{job,processor_consent,disclosure_revision}'='owned-db-fixture-r1'from kc_job)and pg_temp.kc_record()->>'consent_disclosure_revision'='owned-db-fixture-r1','the admitted job and the activation record keep the revision they were made under');
reset role;
set local role authenticated;
select pg_temp.kc_refuse($q$update public.app_config set value='{}'where key='property_video_quality_kie_activation'$q$,'permission denied','a tenant cannot rewrite the activation record');
reset role;
select jsonb_build_object('passed',true,'assertions',n,'scope','actual KIE-ACTIVATION.sql seed shape and v2/v1 admission on an owned disposable DB; synthetic contract and seed only')from kc_checks;
rollback;
