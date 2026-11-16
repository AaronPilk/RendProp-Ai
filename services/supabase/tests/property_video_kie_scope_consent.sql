-- Actual SQL authority on an owned disposable DB only. The driver prepends
-- BEGIN, the existing synthetic property/source seed, canonical identity and
-- existing synthetic paid-clip helpers. No provider, encoded media or network.
create temporary table kg_checks(n integer);insert into kg_checks values(0);grant all on kg_checks to service_role,authenticated;
create function pg_temp.kg_ok(v boolean,label text)returns void language plpgsql as $$begin if v is distinct from true then raise exception'KIE-SCOPE FAIL: %',label;end if;update kg_checks set n=n+1;end$$;
create function pg_temp.kg_refuse(command text,needle text,label text)returns void language plpgsql as $$begin begin execute command;exception when others then if position(needle in sqlerrm)>0 then perform pg_temp.kg_ok(true,label);return;end if;raise;end;raise exception'KIE-SCOPE FAIL: allowed %',label;end$$;
create function pg_temp.kg_op(i integer)returns uuid language sql as $$select('f8a00000-0000-4000-8000-'||lpad(i::text,12,'0'))::uuid$$;
create function pg_temp.kg_id(i integer)returns uuid language sql as $$select('f8b00000-0000-4000-8000-'||lpad(i::text,12,'0'))::uuid$$;
create function pg_temp.kg_recipe(i integer,n integer default 2)returns jsonb language sql as $$select jsonb_set(jsonb_set(jsonb_set(m,'{operation_id}',to_jsonb(pg_temp.kg_op(i)::text)),'{sources}',(select jsonb_agg(value order by ord)from jsonb_array_elements(m->'sources')with ordinality e(value,ord)where ord<=n)),'{presentation,shot_labels}',(select jsonb_agg(null::text)from generate_series(1,n)))from bm$$;
create function pg_temp.kie()returns jsonb language sql as $$select j from kie_identity_file$$;
create function pg_temp.kg_permission()returns jsonb language sql as $$select'{"token":"property-video-jobs-v2","disclosure_revision":"owned-db-fixture-r1"}'::jsonb$$;
create function pg_temp.kg_grant(i integer,n integer default 2,extra jsonb default'{}')returns uuid language plpgsql security definer as $$declare rowdata jsonb;begin
 rowdata:=jsonb_build_object('id',pg_temp.kg_id(i),'profile','kie-kling3-4k-steady-v1','quality_identity',pg_temp.kie(),'actor_id',(select actor from bf),'library_org_id',public.listing_owner_library((select listing from bf)),'listing_id',(select listing from bf),'operation_ids',jsonb_build_array(pg_temp.kg_op(i)),
 'sources',(select jsonb_agg(jsonb_build_object('photo_asset_id',s->'photo_asset_id','photo_version_id',s->'photo_version_id','photo_provenance_id',s->'photo_provenance_id','sha256',repeat('a',64))order by ord)from jsonb_array_elements(pg_temp.kg_recipe(i,n)->'sources')with ordinality e(s,ord)),
 'max_creates',n,'max_cents',n*167.5,'creates_used',0,'cents_used',0,'approval_ref','OWNED-DB-SYNTHETIC-NOT-OWNER-APPROVAL','created_at',now(),'expires_at',now()+interval'1 hour','revoked_at',null,'revoked_reason',null)||extra;
 insert into public.property_video_kie_test_grants select *from jsonb_populate_record(null::public.property_video_kie_test_grants,rowdata);return pg_temp.kg_id(i);end$$;
create function pg_temp.kg_admit(i integer,g uuid,n integer default 2)returns jsonb language sql as $$select public.property_video_job_admit_v2((select actor from bf),pg_temp.kg_recipe(i,n),n*167.5,'kie-kling3-4k-steady-v1',pg_temp.kg_permission(),g)$$;
create function pg_temp.kg_authority(c jsonb)returns jsonb language sql as $$select public.property_video_kie_dispatch_authority((c#>>'{job,id}')::uuid,(c#>>'{source,lease_token}')::uuid,(c#>>'{source,attempt_id}')::uuid)$$;

-- Migration defaults are observed BEFORE any fixture grants or disclosures.
select pg_temp.kg_ok((select value='{"enabled":false,"profile":"fal-kling3-4k-v1"}'::jsonb from app_config where key='property_video_quality'),'all-migration default remains OFF');
select pg_temp.kg_ok((select not enabled from ai_routes where id='7f2c9a3e-4b1d-4e8a-9c55-1d6e0b7a4f21'),'all-migration Kie row remains OFF');
select pg_temp.kg_ok(not exists(select 1 from property_video_kie_test_grants)and not exists(select 1 from property_video_kie_test_grant_uses),'migrations seed no approval or grant use');
select pg_temp.kg_ok(not exists(select 1 from app_config where key='property_video_processor_consent'),'migrations publish no processor approval');
update app_config set value=jsonb_set(value,'{enabled}','true')where key='property_video_jobs';
set local role service_role;
select pg_temp.kg_ok(property_video_processor_consent_current()is null,'unpublished processor disclosure is unavailable');
select pg_temp.kg_refuse($q$select property_video_processor_consent_record('kie-kling3-4k-steady-v1',null)$q$,'RP403: Allow the listed AI processors','Kie missing permission is refused');
select pg_temp.kg_refuse($q$select property_video_processor_consent_record('kie-kling3-4k-steady-v1','{"token":"property-video-jobs-v1"}')$q$,'RP403: Allow the listed AI processors','Kie original v1 permission is refused');
select pg_temp.kg_refuse($q$select property_video_job_admit_v2((select actor from bf),pg_temp.kg_recipe(1),335,'kie-kling3-4k-steady-v1',null,null)$q$,'RP403: Allow AI processing','new RPC never invents missing permission');
reset role;
-- An isolated NEGATIVE reproduces the exact legacy-admit causal RP403. This
-- synthetic selector/row change is rolled back; it is not operator activation.
update ai_routes set enabled=true where id='7f2c9a3e-4b1d-4e8a-9c55-1d6e0b7a4f21';
update app_config set value='{"enabled":true,"profile":"kie-kling3-4k-steady-v1","vendor_content_license":"kie-terms-2025-08-01-section-3-owner-accepted"}'where key='property_video_quality';
set local role service_role;
select pg_temp.kg_refuse($q$select property_video_job_admit((select actor from bf),pg_temp.kg_recipe(1),335,'kie-kling3-4k-steady-v1')$q$,'RP403: Allow the listed AI processors','actual legacy Kie admission without consent stays refused');
select pg_temp.kg_ok(not exists(select 1 from property_video_jobs),'legacy refusal creates no job');
reset role;update app_config set value='{"enabled":false,"profile":"fal-kling3-4k-v1"}'where key='property_video_quality';
-- ONLY NOW publish an explicitly synthetic contract and scoped fixture grant.
insert into app_config(key,value)values('property_video_processor_consent','{"token":"property-video-jobs-v2","disclosure_revision":"owned-db-fixture-r1","processors":["fal","kie"],"profiles":["kie-kling3-4k-steady-v1"]}');
select pg_temp.kg_grant(10);
select pg_temp.kg_refuse($q$select pg_temp.kg_grant(99,2,jsonb_build_object('library_org_id',(select other_org from bf)))$q$,'RP409: The owner quality-test library','grant creation must bind the listing library');
set local role service_role;
select pg_temp.kg_ok(property_video_processor_consent_current()->>'disclosure_revision'='owned-db-fixture-r1','real current processor contract is read');
select pg_temp.kg_refuse($q$select property_video_job_admit_v2((select actor from bf),pg_temp.kg_recipe(10),335,'kie-kling3-4k-steady-v1','{"token":"property-video-jobs-v1"}',pg_temp.kg_id(10))$q$,'RP403: Allow the listed AI processors','v1 cannot borrow an owner grant');
select pg_temp.kg_refuse($q$select property_video_job_admit_v2((select actor from bf),pg_temp.kg_recipe(10),335,'kie-kling3-4k-steady-v1','{"token":"property-video-jobs-v2","disclosure_revision":"stale"}',pg_temp.kg_id(10))$q$,'RP403: Allow the current AI processor','stale permission cannot admit');
select pg_temp.kg_refuse($q$select property_video_kie_test_grant_scope(pg_temp.kg_id(10),(select other from bf),pg_temp.kg_recipe(10))$q$,'RP403: This video is outside','grant cannot change actor');
select pg_temp.kg_refuse($q$select property_video_kie_test_grant_scope(pg_temp.kg_id(10),(select actor from bf),pg_temp.kg_recipe(11))$q$,'RP403: This video is outside','grant cannot change operation');
select pg_temp.kg_refuse($q$select property_video_kie_test_grant_scope(pg_temp.kg_id(10),(select actor from bf),jsonb_set(pg_temp.kg_recipe(10),'{listing_id}',to_jsonb(gen_random_uuid()::text)))$q$,'RP403: This video is outside','grant cannot change listing');
select pg_temp.kg_refuse($q$select property_video_kie_test_grant_scope(pg_temp.kg_id(10),(select actor from bf),jsonb_set(pg_temp.kg_recipe(10),'{sources}',jsonb_build_array(pg_temp.kg_recipe(10)#>'{sources,1}',pg_temp.kg_recipe(10)#>'{sources,0}')))$q$,'RP403: This video is outside','grant preserves ordered source identities');
select pg_temp.kg_refuse($q$select property_video_kie_test_grant_scope(pg_temp.kg_id(10),(select actor from bf),jsonb_set(pg_temp.kg_recipe(10),'{sources,0,photo_version_id}','"another-version"'))$q$,'RP403: This video is outside','grant preserves exact photo version');
select pg_temp.kg_refuse($q$select property_video_job_admit_v2((select actor from bf),jsonb_set(pg_temp.kg_recipe(10),'{expected_org_id}',to_jsonb((select other_org from bf)::text)),335,'kie-kling3-4k-steady-v1',pg_temp.kg_permission(),pg_temp.kg_id(10))$q$,'RP404: Property library is unavailable','v2 admission retains physical workspace fence');
select pg_temp.kg_ok(property_video_quality_profile()='legacy'and property_video_quality_profile_for((select actor from bf),pg_temp.kg_recipe(10),pg_temp.kg_id(10))='kie-kling3-4k-steady-v1','grant narrows owner request while global selector stays OFF');
create temporary table kg_job as select pg_temp.kg_admit(10,pg_temp.kg_id(10))a;grant select on kg_job to service_role;
select pg_temp.kg_ok((select a->>'accepted'='true'and a#>>'{job,quality_profile}'='kie-kling3-4k-steady-v1'and a#>>'{job,consent_revision}'='property-video-jobs-v2'and a#>>'{job,processor_consent,disclosure_revision}'='owned-db-fixture-r1'and a#>>'{job,kie_test_grant_id}'=pg_temp.kg_id(10)::text from kg_job),'real v2 admission persists exact permission and grant');
select pg_temp.kg_ok((select creates_used=0 and cents_used=0 from property_video_kie_test_grants where id=pg_temp.kg_id(10)),'admission alone consumes no supplier create');
select pg_temp.kg_ok(paid_quality_processing_budget((select org from bf))=6500,'admitted own Kie work keeps bounded drain floor with global selector OFF');
reset role;select pg_temp.kg_grant(14,1);update app_config set value='{"enabled":true,"profile":"hold-new-paid-admissions","hold_id":"f8b00000-0000-4000-8000-000000000999"}'where key='property_video_quality';set local role service_role;
select pg_temp.kg_refuse($q$select pg_temp.kg_admit(14,pg_temp.kg_id(14),1)$q$,'RP503:','hold refuses new grant-scoped admission');
select pg_temp.kg_ok(paid_quality_processing_budget((select org from bf))=6500,'admitted own Kie work retains drain floor during hold');
select pg_temp.kg_ok((property_video_job_scope((select(a#>>'{job,id}')::uuid from kg_job),(select actor from bf),true)).quality_profile='kie-kling3-4k-steady-v1','saved Kie job remains readable under hold');
reset role;update app_config set value='{"enabled":false,"profile":"fal-kling3-4k-v1"}'where key='property_video_quality';set local role service_role;
select pg_temp.kg_ok((select property_video_job_admit_v2((select actor from bf),pg_temp.kg_recipe(10),null,'unknown','{"token":"property-video-jobs-v2","disclosure_revision":"stale"}',null)->'job'=a->'job'from kg_job),'accepted operation replay precedes new quote and consent checks');
select pg_temp.kg_refuse($q$update property_video_jobs set processor_consent=jsonb_set(processor_consent,'{disclosure_revision}','"rewritten"')where id=(select(a#>>'{job,id}')::uuid from kg_job)$q$,'RP409: A saved video permission','saved processor permission is immutable');
create temporary table kg_claim1 as select property_video_job_claim((select(a#>>'{job,id}')::uuid from kg_job),'slot-0')c;grant select on kg_claim1 to service_role;
create temporary table kg_claim2 as select property_video_job_claim((select(a#>>'{job,id}')::uuid from kg_job),'slot-1')c;grant select on kg_claim2 to service_role;
select pg_temp.kg_ok((select c->>'action'='dispatch'from kg_claim1)and(select c->>'action'='dispatch'from kg_claim2),'actual worker obtains two exact shot leases');
select pg_temp.kg_refuse($q$select property_video_kie_dispatch_authority((select(a#>>'{job,id}')::uuid from kg_job),gen_random_uuid(),(select(c#>>'{source,attempt_id}')::uuid from kg_claim1))$q$,'RP409: Video attempt lease','dispatch authority requires exact lease');
select pg_temp.kg_ok((pg_temp.kg_authority((select c from kg_claim1))->>'replayed')='false','first actual dispatch authority consumes once');
select pg_temp.kg_ok((pg_temp.kg_authority((select c from kg_claim1))->>'replayed')='true','same attempt authority returns an immutable replay');
select pg_temp.kg_ok((select creates_used=1 and cents_used=167.5 from property_video_kie_test_grants where id=pg_temp.kg_id(10))and(select count(*)=1 from property_video_kie_test_grant_uses),'idempotent authority has exactly one create and167.5c');
select pg_temp.kg_refuse($q$update property_video_kie_test_grant_uses set cents=167.5$q$,'permission denied','service cannot rewrite owner create-use receipts');
reset role;
select pg_temp.kg_refuse($q$update property_video_kie_test_grant_uses set cents=167.5$q$,'RP409: An owner quality-test create is an immutable receipt','even privileged create-use rewrite reaches immutable trigger');
set local role service_role;
-- Existing closed paid-clip helper uses real reservation/settle/receipt/binding
-- functions with only synthetic supplier facts. It does not send or encode media.
select pg_temp.kie_paid_clip((select c from kg_claim1),'OWNED-DB-FAKE-KIE-TASK');
select pg_temp.kg_refuse($q$select pg_temp.kg_authority((select c from kg_claim1))$q$,'RP409:','accepted clip cannot acquire a new supplier send');
reset role;update property_video_kie_test_grants set revoked_at=now(),revoked_reason='owned-db-test-revocation'where id=pg_temp.kg_id(10);set local role service_role;
select pg_temp.kg_refuse($q$select pg_temp.kg_authority((select c from kg_claim2))$q$,'RP403: The owner quality-test permission has ended','revoked grant refuses next unsent clip');
select pg_temp.kg_ok((select count(*)=1 from property_video_kie_test_grant_uses),'revocation adds no create receipt');
select pg_temp.kg_ok((select(c->>'action')<>'dispatch'from(select property_video_job_claim((select(a#>>'{job,id}')::uuid from kg_job),'slot-0')c)t),'accepted-task read does not create a fresh dispatch');
reset role;
select pg_temp.kg_grant(11,1);
select pg_temp.kg_grant(12,2,jsonb_build_object('max_cents',167.5));
select pg_temp.kg_grant(13,1,jsonb_build_object('sources',jsonb_build_array(jsonb_build_object('photo_asset_id',pg_temp.kg_recipe(13,1)#>'{sources,0,photo_asset_id}','photo_version_id',pg_temp.kg_recipe(13,1)#>'{sources,0,photo_version_id}','photo_provenance_id',null,'sha256',repeat('b',64)))));
set local role service_role;
select pg_temp.kg_refuse($q$select pg_temp.kg_admit(12,pg_temp.kg_id(12))$q$,'RP403: This video is outside','exact grant cents ceiling refuses admission');
select pg_temp.kg_refuse($q$select pg_temp.kg_admit(13,pg_temp.kg_id(13),1)$q$,'RP409: An owner quality-test photo changed','prepared-byte hash mismatch refuses');
create temporary table kg_unknown as select pg_temp.kg_admit(11,pg_temp.kg_id(11),1)a;grant select on kg_unknown to service_role;
create temporary table kg_unknown_claim as select property_video_job_claim((select(a#>>'{job,id}')::uuid from kg_unknown),'slot-0')c;grant select on kg_unknown_claim to service_role;
select pg_temp.kg_authority((select c from kg_unknown_claim));
select property_video_job_failure((select(c#>>'{job,id}')::uuid from kg_unknown_claim),(select(c#>>'{source,lease_token}')::uuid from kg_unknown_claim),(select(c#>>'{source,attempt_id}')::uuid from kg_unknown_claim),'fixture-unknown-provider-reply',true);
select pg_temp.kg_refuse($q$select pg_temp.kg_authority((select c from kg_unknown_claim))$q$,'RP409: Video job no longer accepts work','unknown outcome cannot authorize a new send');
select pg_temp.kg_refuse($q$select property_video_job_resume((select actor from bf),(select(a#>>'{job,id}')::uuid from kg_unknown),167.5)$q$,'RP409:','unknown outcome cannot be reset by resume');
reset role;update app_config set value=jsonb_set(value,'{disclosure_revision}','"owned-db-fixture-r2"')where key='property_video_processor_consent';set local role service_role;
select pg_temp.kg_refuse($q$select property_video_processor_consent_record('kie-kling3-4k-steady-v1',pg_temp.kg_permission())$q$,'RP403: Allow the current AI processor','rotated disclosure refuses stale new permission');
select pg_temp.kg_ok((select a#>>'{job,processor_consent,disclosure_revision}'='owned-db-fixture-r1'from kg_job),'accepted historic permission stays exact after disclosure rotation');
select property_video_job_cancel_all((select actor from bf),pg_temp.kg_op(900),'ai_consent_revoked');
select pg_temp.kg_refuse($q$select pg_temp.kg_authority((select c from kg_claim2))$q$,'RP409: Video job no longer accepts work','consent revocation stops all new worker sends');
select pg_temp.kg_ok(property_video_quality_profile()='legacy','owner grant fixture never changes global OFF selector');
select pg_temp.kg_ok(paid_quality_processing_budget((select org from bf))=0,'cancelled jobs no longer keep admitted-work drain floor');
reset role;
select pg_temp.kg_ok((select count(*)=2 from property_video_jobs),'stopped/unknown jobs and recorded consent are retained');
set local role authenticated;
select pg_temp.kg_refuse('select public.property_video_processor_consent_current()','permission denied','tenant cannot read service processor contract RPC');
select pg_temp.kg_refuse($q$select public.property_video_kie_dispatch_authority(gen_random_uuid(),gen_random_uuid(),gen_random_uuid())$q$,'permission denied','tenant cannot grant supplier dispatch');
select pg_temp.kg_refuse($q$insert into public.property_video_kie_test_grants(id)values(gen_random_uuid())$q$,'permission denied','tenant cannot forge owner approval');
reset role;
select jsonb_build_object('passed',true,'assertions',n,'scope','actual owned-DB v2 consent/grant/dispatch SQL; synthetic receipts only')from kg_checks;
rollback;
