-- Kie Kling 3.0 native-4K profile (kie-kling3-4k-steady-v1) on the actual
-- installed SQL. Closed synthetic receipts only: no encoded media, model,
-- provider or network call. The driver (property_video_kie_profile_pg.py)
-- prepends the owned-property seed, the shared paid-clip helpers and the
-- canonical identity file as kie_identity_file(j jsonb) and the Deno PG fixture text as kie_pg_fixture(t, identity).
create temporary table checks(n integer);insert into checks values(0);grant all on checks to service_role,authenticated;
create function pg_temp.ok(v boolean,label text)returns void language plpgsql as $$begin if v is distinct from true then raise exception'KIE-PROFILE FAIL: %',label;end if;update checks set n=n+1;end$$;
create function pg_temp.refuse(command text,needle text,label text)returns void language plpgsql as $$begin begin execute command;exception when others then if position(needle in sqlerrm)>0 then perform pg_temp.ok(true,label);return;end if;raise;end;raise exception'KIE-PROFILE FAIL: allowed %',label;end$$;
create function pg_temp.recipe(i integer,n integer default 2)returns jsonb language sql as $$
 select jsonb_set(jsonb_set(jsonb_set(m,'{operation_id}',to_jsonb(('f6a00000-0000-4000-8000-'||lpad(i::text,12,'0'))::text)),'{sources}',(select jsonb_agg(value order by ord)from jsonb_array_elements(m->'sources')with ordinality e(value,ord)where ord<=n)),'{presentation,shot_labels}',(select jsonb_agg(null::text)from generate_series(1,n)))from bm
$$;
create function pg_temp.op(i integer)returns uuid language sql as $$select('f6a00000-0000-4000-8000-'||lpad(i::text,12,'0'))::uuid$$;
create function pg_temp.kie()returns jsonb language sql as $$select j from kie_identity_file$$;
create function pg_temp.job(i integer)returns uuid language sql as $$select id from public.property_video_jobs where actor_id=(select actor from bf)and operation_id=pg_temp.op(i)$$;
-- The selector and pinned route are operator data: owner-only fixture switches.
create function pg_temp.selector(v jsonb)returns void language sql security definer as $$update public.app_config set value=v where key='property_video_quality'$$;
-- Activation = what docs/handoff/KIE-ACTIVATION.sql does: enable ONLY the pinned
-- row (seeded OFF, AI-router contract section 3) AND set the acknowledged selector.
create function pg_temp.kie_on()returns void language sql security definer as $$
 update public.ai_routes set enabled=true where id='7f2c9a3e-4b1d-4e8a-9c55-1d6e0b7a4f21';
 update public.app_config set value='{"enabled":true,"profile":"kie-kling3-4k-steady-v1","vendor_content_license":"kie-terms-2025-08-01-section-3-owner-accepted"}'where key='property_video_quality'$$;
create temporary table kie_route_original as select *from ai_routes where id='7f2c9a3e-4b1d-4e8a-9c55-1d6e0b7a4f21';grant select on kie_route_original to service_role;
-- The activated row: the reviewed row with only enabled flipped.
create temporary table kie_route_active as select *from kie_route_original;update kie_route_active set enabled=true;grant select on kie_route_active to service_role;
create function pg_temp.route_set(change text)returns void language plpgsql security definer as $$begin execute change;end$$;
create function pg_temp.restore_route()returns void language plpgsql security definer as $$begin delete from public.ai_routes where id='7f2c9a3e-4b1d-4e8a-9c55-1d6e0b7a4f21';insert into public.ai_routes select *from kie_route_active;end$$;
create function pg_temp.drift(change text,i integer,label text)returns void language plpgsql as $$begin
 perform pg_temp.route_set(change);
 perform pg_temp.refuse(format($f$select public.property_video_job_admit((select actor from bf),pg_temp.recipe(%s),335,'kie-kling3-4k-steady-v1')$f$,i),'RP409:',label);
 perform pg_temp.ok(pg_temp.job(i)is null,label||' (no job)');
 perform pg_temp.restore_route();end$$;
-- The actual worker money path: real quota receipts, priced hold from the FROZEN
-- job identity, settlement, receipt, provenance, binding and retained clip facts.
create function pg_temp.kie_hold(p_job uuid,p_key text,p_sha text)returns jsonb language plpgsql as $$declare j public.property_video_jobs;i jsonb;billing uuid;b jsonb;m jsonb;begin
 select *into j from public.property_video_jobs where id=p_job;i:=j.quality_identity;billing:=public.library_actor_billing_org(j.actor_id,j.org_id);
 b:=public.bump_rate_receipt('aivideo:'||billing,300,20,1);m:=public.bump_rate_receipt('reelmo:'||billing,2592000,(public.org_entitlement(billing)).reels_per_month,1);
 return public.app_video_cost_reserve_v2(j.actor_id,j.org_id,p_key,'reel',i->>'provider',i->>'model',p_sha,(i->>'attempt_cents')::numeric,(i->>'seconds')::numeric,(i->>'unit_cents')::numeric,
  -- Same meta as submitReservedVideo with kiePropertyRouteStep: pinned route id,
  -- canonical adapter task (bind_property_video_source requires video.reel_clip).
  jsonb_build_object('route_id',i->>'route_id','task','video.reel_clip','unit',i->>'unit','seconds',i->'seconds','price_estimated',true),(m->>'window_start')::timestamptz,(b->>'window_start')::timestamptz,j.listing_id);end$$;
create function pg_temp.kie_reserve(c jsonb)returns jsonb language plpgsql as $$declare j public.property_video_jobs;src public.property_video_job_sources;begin
 select *into j from public.property_video_jobs where id=(c#>>'{job,id}')::uuid;select *into src from public.property_video_job_sources where job_id=j.id and attempt_id=(c#>>'{source,attempt_id}')::uuid;
 if c->>'action'<>'dispatch'or src.state<>'dispatching'or j.quality_profile<>'kie-kling3-4k-steady-v1'then raise exception'KIE-PROFILE FAIL: Kie money fixture requires an actual Kie dispatch grant';end if;
 return pg_temp.kie_hold(j.id,src.request_key,src.source->>'sha256');end$$;
create function pg_temp.kie_paid_clip(c jsonb,request text)returns jsonb language plpgsql as $$declare j public.property_video_jobs;src public.property_video_job_sources;i jsonb;prov public.media_provenance;claim jsonb;begin
 perform pg_temp.kie_reserve(c);
 select *into j from public.property_video_jobs where id=(c#>>'{job,id}')::uuid;select *into src from public.property_video_job_sources where job_id=j.id and attempt_id=(c#>>'{source,attempt_id}')::uuid;i:=j.quality_identity;
 perform public.app_video_cost_settle(j.actor_id,j.org_id,src.request_key,request);
 perform public.property_video_job_receipt(j.id,src.attempt_id,jsonb_build_object('request_id',request,'model_id',i->>'model'));
 prov:=public.property_video_job_provenance(j.id,src.attempt_id,request,i->>'model');
 perform public.bind_property_video_source(j.actor_id,j.listing_id,src.asset_id,src.photo_provenance_id,request,prov.id,src.source->>'sha256',repeat('d',32));
 perform public.property_video_job_clip(j.id,src.attempt_id,jsonb_build_object('bucket','renders','storage_key','private-kie-fixture/'||src.attempt_id||'.mp4','sha256',repeat('e',64),'width',3840,'height',2160,'fps',24,'frames',120,'duration_s',5));
 claim:=public.property_video_job_claim(j.id,'slot-0');if claim->>'action'<>'extract_frames'then raise exception'KIE-PROFILE FAIL: paid Kie clip did not claim quality extraction';end if;return claim;end$$;
create function pg_temp.kie_accept_qc(c jsonb)returns void language plpgsql as $$declare src public.property_video_job_sources;j public.property_video_jobs;begin
 select *into src from public.property_video_job_sources where job_id=(c#>>'{job,id}')::uuid and attempt_id=(c#>>'{source,attempt_id}')::uuid;select *into j from public.property_video_jobs where id=src.job_id;
 update public.media_provenance set qc=jsonb_build_object('publishable',true,'request_id',src.receipt->>'request_id','source_sha256',repeat('d',32))where id=src.generation_provenance_id;
 insert into public.cost_ledger(org_id,feature,provider,model,total_cents,meta)values(j.org_id,'qc','anthropic','fixture-judge',.0001,jsonb_build_object('request_id',src.receipt->>'request_id','publishable',true));
 perform public.property_video_job_qc(j.id,src.lease_token,src.attempt_id);end$$;
create function pg_temp.kie_structural_refusal(c jsonb)returns void language plpgsql as $$declare j public.property_video_jobs;src public.property_video_job_sources;verdict jsonb;begin
 select *into j from public.property_video_jobs where id=(c#>>'{job,id}')::uuid;select *into src from public.property_video_job_sources where job_id=j.id and attempt_id=(c#>>'{source,attempt_id}')::uuid;
 verdict:=jsonb_build_object('task','judge.qc_drift','request_id',src.receipt->>'request_id','source_sha256',repeat('d',32),'verdict','fail','action','refuse','publishable',false,'failed',jsonb_build_array('architecture'));
 update public.media_provenance set qc=verdict where id=src.generation_provenance_id;
 insert into public.cost_ledger(org_id,feature,provider,model,total_cents,meta)values(j.org_id,'qc','openai','fixture-judge',.0001,verdict||jsonb_build_object('kind','video_drift','provenance_id',src.generation_provenance_id,'source_asset_id',src.asset_id));
 perform public.property_video_job_failure(j.id,src.lease_token,src.attempt_id,'quality_check_refused',false);end$$;
create function pg_temp.kie_retry_grant(c jsonb)returns void language plpgsql security definer as $$declare j public.property_video_jobs;s public.property_video_job_sources;r public.app_video_cost_reservations;v jsonb;begin
 select *into j from public.property_video_jobs where id=(c#>>'{job,id}')::uuid;select *into s from public.property_video_job_sources where job_id=j.id and attempt_id=(c#>>'{source,attempt_id}')::uuid;
 select *into r from public.app_video_cost_reservations where actor_id=j.actor_id and org_id=j.org_id and idempotency_key=s.request_key;
 v:=jsonb_build_object('task','judge.qc_drift','request_id',s.receipt->>'request_id','source_sha256',repeat('d',32),'verdict','fail','action','retry','publishable',false,'failed',jsonb_build_array('contents','additions'),'attempt',0);
 update public.media_provenance set qc=v where id=s.generation_provenance_id;
 insert into public.cost_ledger(org_id,feature,provider,model,total_cents,meta)values(j.org_id,'qc','anthropic','fixture-judge',.0001,v||jsonb_build_object('kind','video_drift','provenance_id',s.generation_provenance_id,'source_asset_id',s.asset_id));
 insert into public.app_video_drift_checks(reservation_id,actor_id,org_id,listing_id,source_sha256,state,result)values(r.id,j.actor_id,j.org_id,j.listing_id,repeat('d',32),'retry',jsonb_build_object('drift',v));end$$;
-- Explicit publication surfaces (renders/render jobs, selected compositions,
-- publication operations, websites, publication slots) and the listing row.
create function pg_temp.publication_state()returns jsonb language sql security definer as $$select jsonb_build_object(
 'renders',(select count(*)from public.renders),'published',(select count(*)from public.renders where published_at is not null),'render_jobs',(select count(*)from public.render_jobs),
 'compositions',(select count(*)from public.property_video_compositions),'selected',(select count(*)from public.property_video_compositions where selected),'publication_ops',(select count(*)from public.property_video_publication_ops),
 'websites',(select count(*)from public.property_website_settings),'publication_slots',(select count(*)from public.workspace_publication_slots),
 'listing',(select to_jsonb(l)from public.listings l where l.id=(select listing from bf)))$$;

-- Catalog: inactive by default, one pinned row, isolated tasks, service-only.
select pg_temp.ok((select value='{"enabled":false,"profile":"fal-kling3-4k-v1"}'::jsonb from app_config where key='property_video_quality'),'default selector unchanged and Kie inactive');
select pg_temp.ok((select not enabled from kie_route_original)and(select not enabled from ai_routes where id='7f2c9a3e-4b1d-4e8a-9c55-1d6e0b7a4f21')
  and not exists(select 1 from ai_routes where provider in('kie','higgsfield')and enabled),'fresh migration leaves the pinned row disabled and no reseller row enabled');
select pg_temp.ok((select(to_jsonb(r)-'created_at'-'updated_at'-'note')=jsonb_build_object('id','7f2c9a3e-4b1d-4e8a-9c55-1d6e0b7a4f21','task','video.property_reel_clip_kie','position',1,'provider','kie','model','kling-3.0/video','unit','second','unit_cents',33.5,
  'capabilities',jsonb_build_array('i2v','1080p','5s','native4k','preserve_photo'),'max_latency_s',1800,'min_plan','free','same_model_as','kling_3_pro','privacy_tier','trains_by_default','enabled',false,'retire_after',null,'params',jsonb_build_object('kie_mode','4K','sound',false))
  and position('kie-kling3-4k-steady-v1'in note)>0 and position('OFF until the owner-approved activation'in note)>0 from kie_route_original r),'pinned Kie route row exact (seeded OFF)');
select pg_temp.ok((select r.id::text=i->>'route_id'and r.task=i->>'task'and r.provider=i->>'provider'and r.model=i->>'model'and r.unit=i->>'unit'and r.unit_cents=(i->>'unit_cents')::numeric and r.privacy_tier=i->>'privacy_tier'
  and r.params=jsonb_build_object('kie_mode',i->'mode','sound',i->'sound')from kie_route_original r,kie_identity_file x(i)),'pinned row equals canonical identity file');
select pg_temp.ok((select(i->>'unit_cents')::numeric*(i->>'seconds')::numeric=(i->>'attempt_cents')::numeric and(i->>'attempt_cents')::numeric=167.5 and(i->>'credits_per_second')::numeric*(i->>'usd_per_credit')::numeric*100=(i->>'unit_cents')::numeric
  and i->'max_paid_attempts_per_source'='2'::jsonb and i->'output_fps'='24'::jsonb and i->>'content_license_ack'='kie-terms-2025-08-01-section-3-owner-accepted'from kie_identity_file x(i)),'canonical identity prices one 5s attempt at exactly 167.5 cents');
select pg_temp.ok((select count(*)=1 and min(provider)='fal'and min(model)='fal-ai/kling-video/v3/4k/image-to-video'and min(unit_cents)=42 from ai_routes where task='video.property_reel_clip'),'FAL task still resolves exactly one row');
select pg_temp.ok((select count(*)=1 from ai_routes where task='video.property_reel_clip_kie')and not exists(select 1 from ai_routes where model='kling-3.0/video'and id<>'7f2c9a3e-4b1d-4e8a-9c55-1d6e0b7a4f21'),'Kie task resolves exactly one row');
-- The Deno identity test reads functions/ai-video/fixtures/kie-property-identity-pg.json
-- (kie_pg_fixture.t): exactly this schema's identity and seeded pinned row, only
-- the two row timestamps normalised.
select pg_temp.ok((select regexp_replace(json_build_object('quality_identity',public.property_video_quality_identity('kie-kling3-4k-steady-v1'),'pinned_route',(select to_jsonb(r)from public.ai_routes r where r.id='7f2c9a3e-4b1d-4e8a-9c55-1d6e0b7a4f21'))::text,
  '"(created_at|updated_at)": "[^"]*"','"\1": "2026-10-16T00:00:00+00:00"','g')||E'\n'=t from kie_pg_fixture),'live identity and pinned route equal the Deno PG fixture byte for byte');
-- Only docs/handoff/KIE-ACTIVATION.sql writes the activation record (with the
-- processor-disclosure attestation); the migration never seeds one.
select pg_temp.ok(not exists(select 1 from app_config where key='property_video_quality_kie_activation'),'migration seeds no Kie activation record');
select pg_temp.ok(has_function_privilege('service_role','public.property_video_quality_identity(text)','execute')and not has_function_privilege('authenticated','public.property_video_quality_identity(text)','execute')
  and not has_function_privilege('anon','public.property_video_quality_identity(text)','execute')and not exists(select 1 from pg_proc p,aclexplode(p.proacl)a where p.oid='public.property_video_quality_identity(text)'::regprocedure and a.grantee=0),'identity function is service-role only');
select pg_temp.ok((select p.provolatile='i'and not p.prosecdef and l.lanname='sql'and p.proconfig=array['search_path=""']from pg_proc p join pg_language l on l.oid=p.prolang where p.oid='public.property_video_quality_identity(text)'::regprocedure),'identity function is immutable SQL with empty search_path');
select pg_temp.ok(not has_function_privilege('authenticated','public.property_video_job_admit(uuid,jsonb,numeric,text)','execute')and not has_function_privilege('anon','public.property_video_quality_profile()','execute')
  and not has_function_privilege('authenticated','public.property_video_job_audio_preflight(uuid,uuid,text,text,numeric,integer)','execute')and not has_function_privilege('authenticated','public.background_video_delivery(uuid,uuid,uuid,text,bigint)','execute')
  and not has_function_privilege('authenticated','public.property_video_quality_freeze()','execute'),'patched authorities stay service-only');
select pg_temp.ok((select data_type='jsonb'and is_nullable='YES'and column_default is null from information_schema.columns where table_schema='public'and table_name='property_video_jobs'and column_name='quality_identity'),'quality_identity is nullable jsonb without default');
select pg_temp.ok((select pg_get_constraintdef(oid)from pg_constraint where conrelid='public.property_video_jobs'::regclass and conname='property_video_quality_profile_check')=$c$CHECK ((quality_profile = ANY (ARRAY['legacy'::text, 'fal-kling3-4k-v1'::text, 'fal-kling3-4k-steady-v2'::text, 'kie-kling3-4k-steady-v1'::text])))$c$,'saved profile constraint admits exactly four profiles');
set local role service_role;
select pg_temp.ok((select property_video_quality_identity('kie-kling3-4k-steady-v1')=j and property_video_quality_identity('kie-kling3-4k-steady-v1')::text=j::text from kie_identity_file),'SQL identity equals canonical JSON file');
select pg_temp.ok(property_video_quality_identity('legacy')is null and property_video_quality_identity('fal-kling3-4k-v1')is null and property_video_quality_identity('fal-kling3-4k-steady-v2')is null and property_video_quality_identity('kie-kling3-4k-steady-v2')is null,'legacy and FAL profiles have no identity');

-- Activation: exact acknowledgement AND the pinned row; rollback (selector) to the FAL values.
reset role;update app_config set value=jsonb_set(value,'{enabled}','true')where key='property_video_jobs';set local role service_role;
select pg_temp.ok(property_video_quality_profile()='legacy','OFF resolves legacy');
select pg_temp.refuse($q$select property_video_job_admit((select actor from bf),pg_temp.recipe(8),335,'kie-kling3-4k-steady-v1')$q$,'RP409:','fresh migration: a Kie quote cannot admit');
select pg_temp.ok(pg_temp.job(8)is null,'fresh migration: refused Kie quote creates no job');
create temporary table oldjob as select(property_video_job_enqueue((select actor from bf),pg_temp.recipe(1))).*;grant select on oldjob to service_role;
select pg_temp.ok((select quality_profile='legacy'and quality_identity is null and deadline=created_at+interval'4h'from oldjob),'legacy job keeps 4h with no identity');
-- Closed actual Apple receipt fixture: ordinary Max, no internal grant.
reset role;update app_config set value='{"mode":"ceiling","free_published_listings":1}'where key='serving_mode';
-- The shared seed's manual Starter grant admitted its listing. Release it so
-- this test exercises the verified Apple entitlement as the plan authority.
update orgs set plan='free',plan_source=null,plan_expires_at=null where id=(select org from bf);
set local role service_role;
select apply_apple_entitlement_v2((select org from bf),(select actor from bf),'kie-quality-original','kie-quality-transaction','com.rendprop.app.starter.monthly','max','Production','active',now()+interval'29 days',true,'DID_RENEW',now()-interval'1 day',now()-interval'30 seconds',now()-interval'30 seconds',now()-interval'30 seconds');
select pg_temp.ok(not org_has_internal_testing_grant((select org from bf))and(org_entitlement((select org from bf))).reels_per_month=30,'real ordinary Max capacity, no sponsored grant');
reset role;
update app_config set value=jsonb_set(value,'{enabled}','true')where key='paid_quality_processing';
update app_config set value='{"enabled":false}'where key='photo_preservation_quality';
update app_config set value='{"enabled":true,"profile":"kie-kling3-4k-steady-v1"}'where key='property_video_quality';
set local role service_role;
select pg_temp.refuse('select property_video_quality_profile()','RP503:','Kie without acknowledgement is unavailable');
select pg_temp.ok(paid_quality_processing_budget((select org from bf))=0,'unacknowledged Kie does not unlock paid processing');
select pg_temp.refuse($q$select property_video_job_admit((select actor from bf),pg_temp.recipe(2),335,'kie-kling3-4k-steady-v1')$q$,'RP503:','unacknowledged Kie cannot admit');
select pg_temp.refuse($q$select property_video_job_enqueue((select actor from bf),pg_temp.recipe(3))$q$,'RP503:','unacknowledged Kie blocks direct enqueue');
select pg_temp.ok(pg_temp.job(2)is null and pg_temp.job(3)is null,'refused activation creates no job');
-- Enabling the pinned row without the acknowledgement is not activation either.
select pg_temp.route_set($r$update public.ai_routes set enabled=true where id='7f2c9a3e-4b1d-4e8a-9c55-1d6e0b7a4f21'$r$);
select pg_temp.refuse('select property_video_quality_profile()','RP503:','enabled row without acknowledgement keeps the selector refusing');
select pg_temp.refuse($q$select property_video_job_admit((select actor from bf),pg_temp.recipe(6),335,'kie-kling3-4k-steady-v1')$q$,'RP503:','enabled row without acknowledgement cannot admit');
select pg_temp.ok(pg_temp.job(6)is null and paid_quality_processing_budget((select org from bf))=0,'enabled row without acknowledgement creates no job and unlocks nothing');
select pg_temp.route_set($r$update public.ai_routes set enabled=false where id='7f2c9a3e-4b1d-4e8a-9c55-1d6e0b7a4f21'$r$);
select pg_temp.selector('{"enabled":true,"profile":"kie-kling3-4k-steady-v1","vendor_content_license":"kie-terms-2025-08-01-section-3-owner-accepted "}');
select pg_temp.refuse('select property_video_quality_profile()','RP503:','inexact acknowledgement is unavailable');
select pg_temp.selector('{"enabled":true,"profile":"kie-kling3-4k-steady-v1","vendor_content_license":"kie-terms-2025-08-01-section-3"}');
select pg_temp.refuse('select property_video_quality_profile()','RP503:','partial acknowledgement is unavailable');
select pg_temp.selector('{"enabled":true,"profile":"kie-kling3-4k-steady-v1","vendor_content_license":["kie-terms-2025-08-01-section-3-owner-accepted"]}');
select pg_temp.refuse('select property_video_quality_profile()','RP503:','non-string acknowledgement is unavailable');
select pg_temp.selector('{"enabled":"true","profile":"kie-kling3-4k-steady-v1","vendor_content_license":"kie-terms-2025-08-01-section-3-owner-accepted"}');
select pg_temp.refuse('select property_video_quality_profile()','RP503:','non-boolean enable flag is unavailable');
-- The acknowledged selector alone is not activation: the pinned row is still OFF.
select pg_temp.selector('{"enabled":true,"profile":"kie-kling3-4k-steady-v1","vendor_content_license":"kie-terms-2025-08-01-section-3-owner-accepted"}');
select pg_temp.ok(property_video_quality_profile()='kie-kling3-4k-steady-v1'and not(select enabled from ai_routes where id='7f2c9a3e-4b1d-4e8a-9c55-1d6e0b7a4f21'),'acknowledged config alone selects Kie while the pinned row stays OFF');
select pg_temp.refuse($q$select property_video_job_admit((select actor from bf),pg_temp.recipe(7),335,'kie-kling3-4k-steady-v1')$q$,'RP409: The Kie property-video route changed before admission','acknowledged config alone cannot admit while the pinned row is OFF');
select pg_temp.ok(pg_temp.job(7)is null,'acknowledged config alone creates no job');
select pg_temp.kie_on();
select pg_temp.ok(property_video_quality_profile()='kie-kling3-4k-steady-v1','exact acknowledgement selects Kie');
select pg_temp.ok((select to_jsonb(r)=(select to_jsonb(a)from kie_route_active a)from ai_routes r where r.id='7f2c9a3e-4b1d-4e8a-9c55-1d6e0b7a4f21'),'activation flips only enabled on the pinned row');
select pg_temp.ok(paid_quality_processing_budget((select org from bf))=6500,'acknowledged Kie recognizes same ordinary paid policy');
select pg_temp.selector('{"enabled":true,"profile":"fal-kling3-4k-steady-v2"}');
select pg_temp.ok(property_video_quality_profile()='fal-kling3-4k-steady-v2'and paid_quality_processing_budget((select org from bf))=6500,'rollback to the FAL v2 selector works');
select pg_temp.selector('{"enabled":true,"profile":"fal-kling3-4k-v1","vendor_content_license":"kie-terms-2025-08-01-section-3-owner-accepted"}');
select pg_temp.ok(property_video_quality_profile()='fal-kling3-4k-v1'and paid_quality_processing_budget((select org from bf))=6500,'FAL v1 selector ignores a stray acknowledgement');
select pg_temp.selector('{"enabled":false,"profile":"kie-kling3-4k-steady-v1","vendor_content_license":"kie-terms-2025-08-01-section-3-owner-accepted"}');
select pg_temp.ok(property_video_quality_profile()='legacy'and paid_quality_processing_budget((select org from bf))=0,'disabled Kie selector resolves legacy');

-- Admission freezes profile, exact identity and the 24h deadline.
select pg_temp.kie_on();
create temporary table k1 as select property_video_job_admit((select actor from bf),pg_temp.recipe(10),335,'kie-kling3-4k-steady-v1')a;grant select on k1 to service_role;
select pg_temp.ok((select a->>'accepted'='true'and a#>>'{job,quality_profile}'='kie-kling3-4k-steady-v1'from k1),'Kie admission freezes profile');
select pg_temp.ok((select a#>'{job,quality_identity}'=pg_temp.kie()and(a#>'{job,quality_identity}')::text=pg_temp.kie()::text from k1),'Kie admission freezes exact canonical identity');
select pg_temp.ok((select(a#>>'{job,deadline}')::timestamptz=(a#>>'{job,created_at}')::timestamptz+interval'24h'from k1),'Kie bounded 24h deadline');
select pg_temp.ok((select quality_identity::text=pg_temp.kie()::text from property_video_jobs where id=pg_temp.job(10)),'stored Kie identity is the canonical JSON');
select pg_temp.ok((select(to_jsonb(j)->'quality_identity')::text=(select identity from kie_pg_fixture)from property_video_jobs j where j.id=pg_temp.job(10)),'admitted Kie job identity text equals the Deno PG fixture identity');
select pg_temp.ok((select a#>'{job,manifest}'=pg_temp.recipe(10)and not(a#>'{job,manifest}'?'quality_profile')and not(a#>'{job,manifest}'?'quality_identity')from k1),'server metadata never rewrites user manifest');
select pg_temp.refuse($q$update property_video_jobs set quality_identity=jsonb_set(quality_identity,'{unit_cents}','33.6')where id=pg_temp.job(10)$q$,'RP409:','saved Kie identity cannot be changed');
select pg_temp.refuse($q$update property_video_jobs set quality_identity=null where id=pg_temp.job(10)$q$,'RP409:','saved Kie identity cannot be erased');
select pg_temp.refuse($q$update property_video_jobs set quality_identity=pg_temp.kie()where id=(select id from oldjob)$q$,'RP409:','legacy job cannot gain an identity');
select pg_temp.refuse($q$update property_video_jobs set quality_profile='fal-kling3-4k-steady-v2'where id=pg_temp.job(10)$q$,'RP409:','saved Kie profile cannot be changed');
select set_config('rendprop.property_video_quality_profile','kie-kling3-4k-steady-v1',true);
insert into property_video_jobs(operation_id,actor_id,listing_id,org_id,library_org_id,manifest,manifest_sha256,source_count,consent_revision,quality_identity)
 select pg_temp.op(5),o.actor_id,o.listing_id,o.org_id,o.library_org_id,pg_temp.recipe(5),encode(sha256(convert_to(pg_temp.recipe(5)::text,'UTF8')),'hex'),2,o.consent_revision,jsonb_set(pg_temp.kie(),'{unit_cents}','0.01')from oldjob o;
select set_config('rendprop.property_video_quality_profile','',true);
select pg_temp.ok((select quality_profile='kie-kling3-4k-steady-v1'and quality_identity::text=pg_temp.kie()::text and deadline=created_at+interval'24h'from property_video_jobs where id=pg_temp.job(5)),'insert-time identity is server-derived, never caller-supplied');
with u as(update property_video_jobs set message='kie fixture note'where id=pg_temp.job(5)returning quality_identity)select pg_temp.ok((select quality_identity::text=pg_temp.kie()::text from u),'ordinary job updates keep the frozen identity');
select pg_temp.selector('{"enabled":false,"profile":"fal-kling3-4k-v1"}');
insert into property_video_jobs(operation_id,actor_id,listing_id,org_id,library_org_id,manifest,manifest_sha256,source_count,consent_revision,quality_identity)
 select pg_temp.op(4),o.actor_id,o.listing_id,o.org_id,o.library_org_id,pg_temp.recipe(4),encode(sha256(convert_to(pg_temp.recipe(4)::text,'UTF8')),'hex'),2,o.consent_revision,pg_temp.kie()from oldjob o;
select pg_temp.ok((select quality_profile='legacy'and quality_identity is null from property_video_jobs where id=pg_temp.job(4)),'legacy insert cannot smuggle an identity');
-- Legacy/FAL keep their behaviour with NULL identity; replay precedes everything.
select pg_temp.selector('{"enabled":true,"profile":"fal-kling3-4k-steady-v2"}');
create temporary table fal2 as select property_video_job_admit((select actor from bf),pg_temp.recipe(20),500,'fal-kling3-4k-steady-v2')a;grant select on fal2 to service_role;
select pg_temp.ok((select a#>>'{job,quality_profile}'='fal-kling3-4k-steady-v2'and a#>'{job,quality_identity}'='null'::jsonb and(a#>>'{job,deadline}')::timestamptz=(a#>>'{job,created_at}')::timestamptz+interval'24h'from fal2),'FAL v2 job keeps old behaviour with null identity');
select pg_temp.refuse($q$select property_video_job_admit((select actor from bf),pg_temp.recipe(21),335,'kie-kling3-4k-steady-v1')$q$,'RP409:','stale Kie quote after cutover to FAL refuses');
select pg_temp.ok(pg_temp.job(21)is null,'stale Kie quote creates no job');
select pg_temp.ok((select(property_video_job_admit((select actor from bf),pg_temp.recipe(10),null,'unknown')->'job')::text=(a->'job')::text from k1),'existing Kie replay is byte-exact after cutover');
-- That cutover is the DEFAULT docs/handoff/KIE-ROLLBACK.sql: selector only. The
-- pinned row stays ON and exact, so the admitted Kie job keeps the active
-- worker scope every dispatch needs, with its frozen identity.
select pg_temp.ok((select to_jsonb(r)=(select to_jsonb(a)from kie_route_active a)from ai_routes r where r.id='7f2c9a3e-4b1d-4e8a-9c55-1d6e0b7a4f21'),'default rollback (selector only) leaves the pinned row ON and exact');
select pg_temp.ok((select quality_profile='kie-kling3-4k-steady-v1'and quality_identity::text=pg_temp.kie()::text from property_video_job_scope(pg_temp.job(10),(select actor from bf),true)),'admitted Kie job keeps active worker scope and frozen identity after a default rollback');
select pg_temp.selector('{"enabled":true,"profile":"fal-kling3-4k-v1"}');
create temporary table fal1 as select property_video_job_admit((select actor from bf),pg_temp.recipe(22),500,'fal-kling3-4k-v1')a;
select pg_temp.ok((select a#>>'{job,quality_profile}'='fal-kling3-4k-v1'and a#>'{job,quality_identity}'='null'::jsonb and(a#>>'{job,deadline}')::timestamptz=(a#>>'{job,created_at}')::timestamptz+interval'24h'from fal1),'FAL v1 job keeps old behaviour with null identity');
select pg_temp.kie_on();
select pg_temp.refuse($q$select property_video_job_admit((select actor from bf),pg_temp.recipe(23),500)$q$,'RP409:','old 3-argument runtime cannot admit while Kie is active');
select pg_temp.refuse($q$select property_video_job_enqueue((select actor from bf),pg_temp.recipe(24))$q$,'RP409:','direct enqueue cannot bypass the quoted Kie profile');
select pg_temp.refuse($q$select property_video_job_admit((select actor from bf),pg_temp.recipe(25),500,'fal-kling3-4k-steady-v2')$q$,'RP409:','stale FAL quote after Kie cutover refuses');
select pg_temp.refuse($q$select property_video_job_admit((select actor from bf),pg_temp.recipe(26),335,'kie-kling3-4k-steady-v2')$q$,'RP409:','unknown Kie profile refuses');
select pg_temp.ok((select(property_video_job_admit((select actor from bf),pg_temp.recipe(20),null,'unknown')->'job')::text=(a->'job')::text from fal2),'existing FAL replay is byte-exact while Kie is active');
-- EMERGENCY rollback (-v emergency_stop=on) also switches the pinned row OFF.
select pg_temp.route_set($r$update public.ai_routes set enabled=false where id='7f2c9a3e-4b1d-4e8a-9c55-1d6e0b7a4f21'$r$);
select pg_temp.ok((select(property_video_job_admit((select actor from bf),pg_temp.recipe(10),null,'unknown')->'job')::text=(a->'job')::text from k1),'existing Kie replay precedes the route identity check');
select pg_temp.ok((select not enabled from ai_routes where id='7f2c9a3e-4b1d-4e8a-9c55-1d6e0b7a4f21')and(select quality_profile='kie-kling3-4k-steady-v1'and quality_identity::text=pg_temp.kie()::text from property_video_jobs where id=pg_temp.job(10)),'emergency stop (pinned row OFF) keeps the admitted Kie job frozen');
select pg_temp.restore_route();

-- Generation-only minimum: 167.5 cents per source, exact numeric.
select pg_temp.refuse($q$select property_video_job_admit((select actor from bf),pg_temp.recipe(30),167.4999*2,'kie-kling3-4k-steady-v1')$q$,'RP400:','quote below 167.5 per source refuses');
select pg_temp.refuse($q$select property_video_job_admit((select actor from bf),pg_temp.recipe(31,3),167.4999*3,'kie-kling3-4k-steady-v1')$q$,'RP400:','fractional cent below 3 x 167.5 refuses');
select pg_temp.refuse($q$select property_video_job_admit((select actor from bf),pg_temp.recipe(32,1),167.49999999,'kie-kling3-4k-steady-v1')$q$,'RP400:','single source one hundred-millionth short refuses');
select pg_temp.refuse($q$select property_video_job_admit((select actor from bf),pg_temp.recipe(33),null,'kie-kling3-4k-steady-v1')$q$,'RP400:','missing Kie quote refuses');
select pg_temp.ok(pg_temp.job(30)is null and pg_temp.job(31)is null and pg_temp.job(32)is null and pg_temp.job(33)is null,'underpriced Kie quotes create no job');
create temporary table k3s as select property_video_job_admit((select actor from bf),pg_temp.recipe(34,3),167.5*3,'kie-kling3-4k-steady-v1')a;
select pg_temp.ok((select a->>'accepted'='true'and a#>>'{job,source_count}'='3'and a#>'{job,quality_identity}'=pg_temp.kie()from k3s),'exact 3 x 167.5 quote admits');
create temporary table k1src as select property_video_job_admit((select actor from bf),pg_temp.recipe(35,1),167.5,'kie-kling3-4k-steady-v1')a;
select pg_temp.ok((select a->>'accepted'='true'and a#>'{job,quality_identity}'=pg_temp.kie()from k1src),'exact single-source 167.5 quote admits');
select pg_temp.ok((select property_video_job_admit((select actor from bf),pg_temp.recipe(36,100),167.5*100,'kie-kling3-4k-steady-v1')->>'operation_closed'='true'),'100-source Kie funding refuses on an ordinary plan without bypass');

-- Live pinned route must equal the identity before capacity checks.
select pg_temp.drift($d$update public.ai_routes set unit_cents=33.6 where id='7f2c9a3e-4b1d-4e8a-9c55-1d6e0b7a4f21'$d$,40,'route unit_cents drift refuses');
select pg_temp.drift($d$update public.ai_routes set unit_cents=33.4999 where id='7f2c9a3e-4b1d-4e8a-9c55-1d6e0b7a4f21'$d$,41,'route underpriced unit_cents drift refuses');
select pg_temp.drift($d$update public.ai_routes set params='{"kie_mode":"pro","sound":false}'where id='7f2c9a3e-4b1d-4e8a-9c55-1d6e0b7a4f21'$d$,42,'route mode pro drift refuses');
select pg_temp.drift($d$update public.ai_routes set params='{"kie_mode":"4K","sound":true}'where id='7f2c9a3e-4b1d-4e8a-9c55-1d6e0b7a4f21'$d$,43,'route sound drift refuses');
select pg_temp.drift($d$update public.ai_routes set params='{"kie_mode":"4K","sound":false,"multi_shots":true}'where id='7f2c9a3e-4b1d-4e8a-9c55-1d6e0b7a4f21'$d$,44,'route extra param drift refuses');
select pg_temp.drift($d$update public.ai_routes set params=null where id='7f2c9a3e-4b1d-4e8a-9c55-1d6e0b7a4f21'$d$,45,'route default params drift refuses');
select pg_temp.drift($d$update public.ai_routes set enabled=false where id='7f2c9a3e-4b1d-4e8a-9c55-1d6e0b7a4f21'$d$,46,'disabled route refuses');
select pg_temp.drift($d$update public.ai_routes set privacy_tier='retained_30d'where id='7f2c9a3e-4b1d-4e8a-9c55-1d6e0b7a4f21'$d$,47,'route privacy tier drift refuses');
select pg_temp.drift($d$update public.ai_routes set provider='fal'where id='7f2c9a3e-4b1d-4e8a-9c55-1d6e0b7a4f21'$d$,48,'route provider drift refuses');
select pg_temp.drift($d$update public.ai_routes set model='kling-3.0/video-pro'where id='7f2c9a3e-4b1d-4e8a-9c55-1d6e0b7a4f21'$d$,49,'route model drift refuses');
select pg_temp.drift($d$update public.ai_routes set task='video.property_reel_clip_kie_v2'where id='7f2c9a3e-4b1d-4e8a-9c55-1d6e0b7a4f21'$d$,50,'route task drift refuses');
select pg_temp.drift($d$update public.ai_routes set unit='call'where id='7f2c9a3e-4b1d-4e8a-9c55-1d6e0b7a4f21'$d$,51,'route unit drift refuses');
select pg_temp.drift($d$update public.ai_routes set retire_after=(now()at time zone'UTC')::date where id='7f2c9a3e-4b1d-4e8a-9c55-1d6e0b7a4f21'$d$,52,'route retiring today refuses');
select pg_temp.drift($d$update public.ai_routes set retire_after=(now()at time zone'UTC')::date-1 where id='7f2c9a3e-4b1d-4e8a-9c55-1d6e0b7a4f21'$d$,53,'retired route refuses');
select pg_temp.drift($d$delete from public.ai_routes where id='7f2c9a3e-4b1d-4e8a-9c55-1d6e0b7a4f21'$d$,54,'missing route refuses');
select pg_temp.route_set($d$update public.ai_routes set retire_after=(now()at time zone'UTC')::date+30,note='operator note edit',max_latency_s=900 where id='7f2c9a3e-4b1d-4e8a-9c55-1d6e0b7a4f21'$d$);
select pg_temp.ok((select property_video_job_admit((select actor from bf),pg_temp.recipe(55),335,'kie-kling3-4k-steady-v1')#>'{job,quality_identity}'=pg_temp.kie()),'future retirement and non-identity metadata still admit');
select pg_temp.restore_route();
select pg_temp.ok((select to_jsonb(r)=(select to_jsonb(a)from kie_route_active a)from ai_routes r where r.id='7f2c9a3e-4b1d-4e8a-9c55-1d6e0b7a4f21'),'pinned route restored exactly (activated) after drift checks');

-- Account switch: another account or workspace cannot admit, replay or scope.
select pg_temp.refuse($q$select property_video_job_admit((select other from bf),pg_temp.recipe(60),335,'kie-kling3-4k-steady-v1')$q$,'RP403:','another account cannot admit into this listing');
select pg_temp.refuse($q$select property_video_job_admit((select actor from bf),jsonb_set(pg_temp.recipe(61),'{expected_org_id}',to_jsonb((select other_org from bf)::text)),335,'kie-kling3-4k-steady-v1')$q$,'RP404:','switched workspace cannot admit into this listing');
select pg_temp.refuse($q$select property_video_job_admit((select other from bf),pg_temp.recipe(10),null,'unknown')$q$,'RP403:','another account cannot replay the Kie operation');
select pg_temp.refuse($q$select property_video_job_scope(pg_temp.job(10),(select other from bf),true)$q$,'RP404:','another account cannot obtain worker scope');
select pg_temp.refuse($q$select property_video_job_cancel((select other from bf),pg_temp.job(10))$q$,'RP404:','another account cannot cancel the Kie job');
select pg_temp.refuse($q$select property_video_job_resume((select other from bf),pg_temp.job(10),0)$q$,'RP404:','another account cannot resume the Kie job');
select pg_temp.ok(not exists(select 1 from property_video_jobs where actor_id=(select other from bf)or operation_id in(pg_temp.op(60),pg_temp.op(61))),'account switch creates no job');
select pg_temp.ok((property_video_job_scope(pg_temp.job(10),(select actor from bf),true)).quality_identity::text=pg_temp.kie()::text,'owner worker scope carries the frozen identity');

-- Narration admission uses the frozen 24 fps steady cadence, not caller FPS.
create temporary table aud as select(property_video_audio_prepare((select actor from bf),jsonb_build_object('operation_id','f6b00000-0000-4000-8000-000000000001','listing_id',(select listing from bf),'expected_org_id',(select org from bf),'bytes',100,'sha256',repeat('d',64),'mime','audio/mp4'))).*;
select property_video_audio_complete((select actor from bf),(select id from aud),'"audio-etag"');
create function pg_temp.voice(i integer,transition text,seconds numeric)returns jsonb language plpgsql as $$declare m jsonb;j public.property_video_jobs;c jsonb;begin
 m:=jsonb_set(jsonb_set(pg_temp.recipe(i),'{narration_asset_id}',to_jsonb((select id::text from aud))),'{presentation,transition}',to_jsonb(transition));
 j:=jsonb_populate_record(null::public.property_video_jobs,public.property_video_job_admit((select actor from bf),m,335,'kie-kling3-4k-steady-v1')->'job');
 if j.quality_profile<>'kie-kling3-4k-steady-v1'or j.quality_identity::text is distinct from pg_temp.kie()::text then raise exception'KIE-PROFILE FAIL: narrated Kie job lost its frozen identity';end if;
 c:=public.property_video_job_claim(j.id,'slot-0');
 if c->>'action'<>'inspect_audio'then raise exception'KIE-PROFILE FAIL: narration lease must precede paid Kie clips';end if;
 perform public.property_video_job_audio_source(j.id,(c#>>'{job,audio_lease}')::uuid,jsonb_build_object('bucket','renders','storage_key',(select storage_key from aud),'bytes',100,'sha256',repeat('d',64),'etag','"audio-etag"','content_type','audio/mp4'));
 j:=public.property_video_job_audio_preflight(j.id,(c#>>'{job,audio_lease}')::uuid,j.manifest_sha256,repeat('d',64),seconds,1);
 return j.audio_preflight;end$$;
select pg_temp.ok(pg_temp.voice(90,'dissolve',9.84)=jsonb_build_object('within_limit',true,'sha256',repeat('d',64),'duration_s',9.84,'audio_streams',1,'max_duration_s',9.75),'Kie dissolve exact6frames24fps admits');
select pg_temp.ok(pg_temp.voice(91,'dissolve',9.851)->'within_limit'='false'::jsonb,'Kie narration above exact limit refuses before any clip');
select pg_temp.ok(abs((pg_temp.voice(92,'whip',9)->>'max_duration_s')::numeric-(10-4/24.0))<.0000001,'Kie whip exact4frames24fps');
select pg_temp.ok((pg_temp.voice(93,'cut',10.05)->>'max_duration_s')::numeric=10,'Kie cut duration remains sourcecount times5');
select pg_temp.ok((select count(*)=0 from app_video_cost_reservations),'narration preflight never reserves a paid clip');

-- Priced basis with the real money functions: one attempt = 5 x 33.5 = 167.5,
-- one settled ledger row; the single QC retry is a second distinct paid attempt;
-- a third paid generation for the same source is impossible.
create temporary table spend0 as select serving_ceiling_spent_cents((select org from bf),null,null)s;
create temporary table k1c as select property_video_job_claim(pg_temp.job(10),'slot-0')c;
select pg_temp.ok((select c->>'action'='dispatch'and c#>>'{source,position}'='0'and c#>>'{job,quality_profile}'='kie-kling3-4k-steady-v1'and c#>'{job,quality_identity}'=pg_temp.kie()from k1c),'dispatch claim carries frozen Kie profile and identity');
create temporary table k1q as select pg_temp.kie_paid_clip((select c from k1c),'kie-fixture-task-10-a')c;
select pg_temp.ok((select count(*)=1 and min(provider)='kie'and min(model)='kling-3.0/video'and min(units)=5 and min(unit_cost_cents)=33.5 and min(total_cents)=167.5 and min(total_cents::text)='167.5000'and min(hold_cents)=167.5
  and bool_and(feature='reel'and settled_at is not null and released_at is null and provider_request_id='kie-fixture-task-10-a'and meta->>'route_id'='7f2c9a3e-4b1d-4e8a-9c55-1d6e0b7a4f21'and meta->>'task'='video.reel_clip')
  from app_video_cost_reservations where idempotency_key=(select c#>>'{source,request_key}'from k1c)),'Kie attempt reserves 5 x 33.5 = exactly 167.5');
select pg_temp.ok((select count(*)=1 and min(l.provider)='kie'and min(l.model)='kling-3.0/video'and min(l.units)=5 and min(l.unit_cost_cents)=33.5 and min(l.total_cents)=167.5 and bool_and(l.meta->>'request_id'='kie-fixture-task-10-a'and l.meta->>'stage'='reel')
  from cost_ledger l where l.feature='reel'and l.meta->>'request_key'=(select c#>>'{source,request_key}'from k1c)),'Kie settlement writes one exact ledger row');
select pg_temp.ok(serving_ceiling_spent_cents((select org from bf),null,null)-(select s from spend0)=167.5,'ceiling spend counts exactly one Kie attempt');
select pg_temp.ok((select count(*)=1 from app_video_allowance_receipts a join app_video_cost_reservations r on r.id=a.reservation_id where r.idempotency_key=(select c#>>'{source,request_key}'from k1c)and a.listing_id=(select listing from bf)),'Kie attempt consumes one real allowance receipt');
select pg_temp.kie_retry_grant((select c from k1q));
select pg_temp.ok((property_video_job_quality_retry(pg_temp.job(10),(select(c#>>'{source,lease_token}')::uuid from k1q),(select(c#>>'{source,attempt_id}')::uuid from k1q))->>'retry_scheduled')::boolean,'single QC retry schedules one more paid Kie attempt');
create temporary table k1c2 as select property_video_job_claim(pg_temp.job(10),'slot-0')c;
select pg_temp.ok((select c->>'action'='dispatch'and c#>>'{source,position}'='0'and c#>>'{source,request_key}'<>(select c#>>'{source,request_key}'from k1c)and c#>'{job,quality_identity}'=pg_temp.kie()from k1c2),'retry dispatch uses a new funding key and the same frozen identity');
create temporary table k1q2 as select pg_temp.kie_paid_clip((select c from k1c2),'kie-fixture-task-10-b')c;
select pg_temp.ok((select count(*)=2 and count(distinct cost_ledger_id)=2 and sum(total_cents)=335.0 and bool_and(provider='kie'and model='kling-3.0/video'and total_cents=167.5 and settled_at is not null)
  from app_video_cost_reservations where idempotency_key in((select c#>>'{source,request_key}'from k1c),(select c#>>'{source,request_key}'from k1c2))),'retry creates a second distinct 167.5 reservation (sum 335.0)');
select pg_temp.ok((select count(*)=2 and sum(total_cents)=335.0 from cost_ledger where feature='reel'and provider='kie'and meta->>'request_key'in((select c#>>'{source,request_key}'from k1c),(select c#>>'{source,request_key}'from k1c2))),'two Kie ledger rows total exactly 335.0');
select pg_temp.ok(serving_ceiling_spent_cents((select org from bf),null,null)-(select s from spend0)between 335 and 335.001,'ceiling spend counts both paid Kie attempts');
select pg_temp.kie_retry_grant((select c from k1q2));
select pg_temp.refuse($q$select property_video_job_quality_retry(pg_temp.job(10),(select(c#>>'{source,lease_token}')::uuid from k1q2),(select(c#>>'{source,attempt_id}')::uuid from k1q2))$q$,'RP409:','single retry: a third paid Kie generation is impossible');
select pg_temp.refuse($q$select pg_temp.kie_hold(pg_temp.job(10),(select c#>>'{source,request_key}'from k1c2),repeat('a',64))$q$,'RP409:','a used Kie funding key never authorizes another POST');
select property_video_job_failure(pg_temp.job(10),(select(c#>>'{source,lease_token}')::uuid from k1q2),(select(c#>>'{source,attempt_id}')::uuid from k1q2),'quality_check_refused',false);
select pg_temp.ok((select j.state='failed'and s.state='failed'and s.quality_retries=1 and jsonb_array_length(s.quality_retry_history)=1 from property_video_jobs j join property_video_job_sources s on s.job_id=j.id and s.position=0 where j.id=pg_temp.job(10)),'refused retry clip pauses with its single retry spent');
select pg_temp.refuse($q$select property_video_job_claim(pg_temp.job(10),'slot-0')$q$,'RP409:','paused Kie job dispatches nothing more');
-- Owner resume takes the existing CPU-only recovery of the retained second clip.
select pg_temp.ok((property_video_job_resume((select actor from bf),pg_temp.job(10),335)).state='generating','owner resume of the paused Kie job is accepted');
select pg_temp.ok((select quality_retries=1 and cpu_recoveries=1 and attempt_id=(select(c#>>'{source,attempt_id}')::uuid from k1q2)and request_key=(select c#>>'{source,request_key}'from k1c2)
  and receipt->>'request_id'='kie-fixture-task-10-b'and clip is not null from property_video_job_sources where job_id=pg_temp.job(10)and position=0),'owner resume only rechecks the retained second clip');
create temporary table k1c3 as select property_video_job_claim(pg_temp.job(10),'slot-0')c;
select pg_temp.ok((select c->>'action'='extract_frames'and c#>>'{source,attempt_id}'=(select c#>>'{source,attempt_id}'from k1q2)from k1c3),'resumed Kie source is CPU-rechecked, never redispatched');
select pg_temp.refuse($q$select property_video_job_quality_retry(pg_temp.job(10),(select(c#>>'{source,lease_token}')::uuid from k1c3),(select(c#>>'{source,attempt_id}')::uuid from k1c3))$q$,'RP409:','resume does not reset the single paid retry');
select pg_temp.ok((select count(*)=(pg_temp.kie()->>'max_paid_attempts_per_source')::integer from app_video_cost_reservations r join property_video_jobs j on j.actor_id=r.actor_id and j.org_id=r.org_id
  where j.id=pg_temp.job(10)and r.idempotency_key in(select s.request_key from property_video_job_sources s where s.job_id=j.id union select h#>>'{prior_source,request_key}'from property_video_job_sources s,jsonb_array_elements(s.quality_retry_history)h where s.job_id=j.id)),'source paid attempts equal identity maximum of two');
select property_video_job_cancel((select actor from bf),pg_temp.job(10));

-- A Kie job finishing ready only notifies: no publication of any kind.
create temporary table k2 as select property_video_job_admit((select actor from bf),pg_temp.recipe(70),335,'kie-kling3-4k-steady-v1')a;
create temporary table k2q0 as select pg_temp.kie_paid_clip(property_video_job_claim(pg_temp.job(70),'slot-0'),'kie-fixture-task-70-a')c;
select pg_temp.kie_accept_qc((select c from k2q0));
create temporary table k2q1 as select pg_temp.kie_paid_clip(property_video_job_claim(pg_temp.job(70),'slot-0'),'kie-fixture-task-70-b')c;
select pg_temp.kie_structural_refusal((select c from k2q1));
create temporary table k2comp as select property_video_job_claim(pg_temp.job(70),'slot-0')c;
select pg_temp.ok((select c->>'action'='compose'and c#>'{job,quality_identity}'=pg_temp.kie()and jsonb_array_length(c->'sources')=2 from k2comp),'compose lease carries the frozen Kie identity');
create temporary table pub_before as select pg_temp.publication_state()s;
create temporary table k2out as select property_video_job_outputs_reserve(pg_temp.job(70),(select(c#>>'{job,compose_lease}')::uuid from k2comp),2000,repeat('b',64),100,repeat('c',64))o;
create temporary table k2done as select(property_video_job_finish(pg_temp.job(70),(select(c#>>'{job,compose_lease}')::uuid from k2comp),jsonb_build_object('manifest_sha256',(select c#>>'{job,manifest_sha256}'from k2comp),'asset_id',o->>'asset_id','poster_asset_id',o->>'poster_asset_id','bytes',2000,'sha256',repeat('b',64),'poster_bytes',100,'poster_sha256',repeat('c',64),'etag','"master-etag"','poster_etag','"poster-etag"','width',1920,'height',1080,'duration_s',10))).*from k2out;
select pg_temp.ok((select state='ready'and quality_profile='kie-kling3-4k-steady-v1'and quality_identity::text=pg_temp.kie()::text and result->>'original_photo_count'='1'from k2done),'Kie job finishes ready with its frozen identity');
select pg_temp.ok(pg_temp.publication_state()=(select s from pub_before)and(select(s->>'published')::integer=0 from pub_before),'finishing a Kie job creates no publication');
select pg_temp.ok((select count(*)=1 from notification_outbox where dedupe_key='property_video_ready:'||pg_temp.job(70)||':'||(select actor from bf)),'ready Kie job only notifies once');
select pg_temp.ok(background_video_delivery((select actor from bf),(select org from bf),(select listing from bf),(select o->>'key'from k2out),0)->>'quality_profile'='kie-kling3-4k-steady-v1','ready Kie master projects frozen profile');
select pg_temp.ok(background_video_delivery(null,(select org from bf),(select listing from bf),(select o->>'key'from k2out),0)->>'quality_profile'='kie-kling3-4k-steady-v1'
  and not(background_video_delivery(null,(select org from bf),(select listing from bf),(select o->>'key'from k2out),0)?'quality_identity'),'public authority projects the same profile and no provider identity');
select pg_temp.refuse($q$select background_video_delivery((select other from bf),(select org from bf),(select listing from bf),(select o->>'key'from k2out),0)$q$,'RP404:','Kie master keeps the private reader scope');

-- Cancellation is final: a late accepted receipt cannot resurrect the job.
create temporary table k3 as select property_video_job_admit((select actor from bf),pg_temp.recipe(80,1),167.5,'kie-kling3-4k-steady-v1')a;
create temporary table k3d as select property_video_job_claim(pg_temp.job(80),'slot-0')c;grant select on k3d to service_role;
select pg_temp.kie_reserve((select c from k3d));
select pg_temp.ok((property_video_job_cancel((select actor from bf),pg_temp.job(80))->>'cancelled')::boolean,'owner cancels the Kie job while its POST is in flight');
select app_video_cost_settle((select actor from bf),(select org from bf),(select c#>>'{source,request_key}'from k3d),'kie-fixture-task-80');
select pg_temp.ok(property_video_job_receipt(pg_temp.job(80),(select(c#>>'{source,attempt_id}')::uuid from k3d),'{"request_id":"kie-fixture-task-80","model_id":"kling-3.0/video"}'),'late accepted Kie receipt is retained for reconciliation');
select pg_temp.ok((select j.state='cancelled'and j.cancelled_at is not null and s.state='dispatching'and s.receipt->>'request_id'='kie-fixture-task-80'and s.clip is null and j.quality_identity::text=pg_temp.kie()::text
  from property_video_jobs j join property_video_job_sources s on s.job_id=j.id where j.id=pg_temp.job(80)),'cancelled Kie job does not resurrect on a late receipt');
select pg_temp.refuse($q$select property_video_job_claim(pg_temp.job(80),'slot-0')$q$,'RP409:','cancelled Kie job grants no further work');
select pg_temp.refuse($q$select property_video_job_clip(pg_temp.job(80),(select(c#>>'{source,attempt_id}')::uuid from k3d),'{"storage_key":"late.mp4"}')$q$,'RP409:','cancelled Kie job cannot attach a late clip');
select pg_temp.refuse($q$select property_video_job_provenance(pg_temp.job(80),(select(c#>>'{source,attempt_id}')::uuid from k3d),'kie-fixture-task-80','kling-3.0/video')$q$,'RP409:','cancelled Kie job cannot bind late provenance');
select pg_temp.refuse($q$select property_video_job_resume((select actor from bf),pg_temp.job(80),167.5)$q$,'RP409:','cancelled Kie job cannot resume');
select pg_temp.ok((select count(*)=1 and min(total_cents)=167.5 and bool_and(settled_at is not null and released_at is null)from app_video_cost_reservations where idempotency_key=(select c#>>'{source,request_key}'from k3d)),'late accepted Kie charge stays recorded exactly once');

-- Whole-run invariants.
select pg_temp.ok((select bool_and(case when quality_profile='kie-kling3-4k-steady-v1'then quality_identity::text=pg_temp.kie()::text else quality_identity is null end)from property_video_jobs),'every saved job carries exactly its profile identity');
select pg_temp.ok((select count(*)=5 and sum(total_cents)=837.5 and bool_and(provider='kie'and model='kling-3.0/video'and units=5 and unit_cost_cents=33.5)from app_video_cost_reservations),'Kie jobs never reserve a FAL step; five exact Kie attempts');

-- Kie vendor-account refusals reach the worker as HTTP 402: a definite Kie
-- 401/402/403 refusal releases its hold, and a missing KIE_API_KEY refuses
-- before any hold. The worker files both as capacity_before_dispatch (not
-- ambiguous). Through the real reservation, release, failure and resume
-- functions the paused Kie job then resumes on the existing generic capacity
-- path (nothing Kie-specific in SQL): pending again with a new request key, one
-- more admission retry, frozen profile and identity unchanged, at most three
-- resumes. An unreleased (uncertain) Kie hold is never reset or resumed, and the
-- FAL-only unaccepted-submission recovery never matches a Kie attempt.
reset role;
create function pg_temp.kcap_dispatch(i integer)returns jsonb language plpgsql as $$declare c jsonb;begin
 c:=public.property_video_job_claim(pg_temp.job(i),'slot-0');
 if c->>'action'is distinct from'dispatch'or c#>>'{source,position}'is distinct from'0'or c#>'{job,quality_identity}'is distinct from pg_temp.kie()then
  raise exception'KIE-PROFILE FAIL: Kie capacity fixture expected a dispatch grant of source 0 with the frozen identity, got %',c;end if;
 return c;end$$;
create function pg_temp.kcap_pause(c jsonb,p_ambiguous boolean default false)returns boolean language sql as $$
 select public.property_video_job_failure((c#>>'{job,id}')::uuid,(c#>>'{source,lease_token}')::uuid,(c#>>'{source,attempt_id}')::uuid,'capacity_before_dispatch',p_ambiguous)$$;
-- The actual hold for the granted clip, then the definite provider refusal receipt.
create function pg_temp.kcap_refused(c jsonb,p_status integer)returns jsonb language plpgsql as $$declare j public.property_video_jobs;begin
 perform pg_temp.kie_reserve(c);select *into j from public.property_video_jobs where id=(c#>>'{job,id}')::uuid;
 return public.app_video_cost_release_rejected(j.actor_id,j.org_id,c#>>'{source,request_key}',p_status,'upstream');end$$;
-- One refused paid attempt: dispatch grant, exact 167.5 hold, release, pause.
create function pg_temp.kcap_cycle(i integer,p_status integer,p_retries integer,p_label text)returns text language plpgsql as $$declare c jsonb;r public.app_video_cost_reservations;j public.property_video_jobs;s public.property_video_job_sources;begin
 c:=pg_temp.kcap_dispatch(i);
 perform pg_temp.ok((pg_temp.kcap_refused(c,p_status)->>'released')::boolean,p_label||': the definite Kie refusal is recorded');
 select *into r from public.app_video_cost_reservations where idempotency_key=c#>>'{source,request_key}';
 perform pg_temp.ok(r.provider='kie'and r.model='kling-3.0/video'and r.units=5 and r.unit_cost_cents=33.5 and r.total_cents=167.5 and r.hold_cents=167.5 and r.released_at is not null and r.rejection_status=p_status
  and r.rejection_error_class='upstream'and r.settled_at is null and r.cost_ledger_id is null and r.provider_request_id is null,p_label||': the definite Kie refusal released its exact 167.5 hold');
 perform pg_temp.ok(pg_temp.kcap_pause(c),p_label||': the released Kie refusal files a capacity pause');
 select *into j from public.property_video_jobs where id=pg_temp.job(i);select *into s from public.property_video_job_sources where job_id=j.id and position=0;
 perform pg_temp.ok(j.state='failed'and j.quality_identity::text=pg_temp.kie()::text and s.state='failed'and s.last_error='capacity_before_dispatch'and s.admission_retries=p_retries and s.receipt is null
  and s.request_key=c#>>'{source,request_key}'and public.property_video_submit_refusal(j.id,s.attempt_id)is null and not public.property_video_submit_resume_available(j.id),p_label||': the Kie pause never takes the FAL-only submit-refusal recovery');
 return c#>>'{source,request_key}';end$$;
-- Owner resume on the existing generic path with a whole-recipe quote of
-- 167.5 per remaining shot.
create function pg_temp.kcap_resume(i integer,p_retries integer,p_old_key text,p_label text)returns void language plpgsql as $$declare j public.property_video_jobs;s public.property_video_job_sources;n integer;begin
 select count(*)into n from public.property_video_job_sources where job_id=pg_temp.job(i)and state in('pending','failed');
 j:=public.property_video_job_resume((select actor from bf),pg_temp.job(i),(pg_temp.kie()->>'attempt_cents')::numeric*n);
 select *into s from public.property_video_job_sources where job_id=j.id and position=0;
 perform pg_temp.ok(n=2 and j.state='generating'and j.quality_profile='kie-kling3-4k-steady-v1'and j.quality_identity::text=pg_temp.kie()::text,p_label||': owner resume restarts the paused Kie job with its frozen profile and identity');
 perform pg_temp.ok(s.state='pending'and s.admission_retries=p_retries and s.attempt_id is null and s.request_key is null and s.lease_token is null and s.last_error is null and s.receipt is null
  and jsonb_array_length(s.non_dispatch_history)=p_retries and s.non_dispatch_history->(p_retries-1)->>'request_key'=p_old_key and s.non_dispatch_history->(p_retries-1)->>'reason'='capacity_before_dispatch',
  p_label||': the resumed Kie source is pending again with one more admission retry');end$$;
-- Every FAL and legacy job, source, non-Kie route and non-Kie reservation.
create function pg_temp.kcap_fal()returns text language sql security definer as $$
 select md5(coalesce((select string_agg(to_jsonb(j)::text,E'\n'order by j.id)from public.property_video_jobs j where j.quality_profile<>'kie-kling3-4k-steady-v1'),'')
  ||coalesce((select string_agg(to_jsonb(s)::text,E'\n'order by s.job_id,s.position)from public.property_video_job_sources s join public.property_video_jobs j on j.id=s.job_id where j.quality_profile<>'kie-kling3-4k-steady-v1'),'')
  ||coalesce((select string_agg(to_jsonb(r)::text,E'\n'order by r.id)from public.ai_routes r where r.provider<>'kie'),'')
  ||coalesce((select string_agg(to_jsonb(r)::text,E'\n'order by r.id)from public.app_video_cost_reservations r where r.provider<>'kie'),''))$$;
set local role service_role;
create temporary table kcap_fal_before as select pg_temp.kcap_fal()s;
-- (1) A refusal before any hold (missing KIE_API_KEY): no reservation exists.
create temporary table kcap_b as select property_video_job_admit((select actor from bf),pg_temp.recipe(110),335,'kie-kling3-4k-steady-v1')a;
select pg_temp.ok((select a->>'accepted'='true'and a#>'{job,quality_identity}'=pg_temp.kie()from kcap_b),'capacity fixture admits a Kie job with the frozen identity');
create temporary table kcap_b0 as select pg_temp.kcap_dispatch(110)c;
select pg_temp.ok(pg_temp.kcap_pause((select c from kcap_b0)),'a Kie refusal before any hold files a capacity pause');
select pg_temp.ok((select j.state='failed'and s.state='failed'and s.last_error='capacity_before_dispatch'and s.admission_retries=0
  and not exists(select 1 from app_video_cost_reservations where idempotency_key=(select c#>>'{source,request_key}'from kcap_b0))
  and property_video_submit_refusal(j.id,s.attempt_id)is null
  from property_video_jobs j join property_video_job_sources s on s.job_id=j.id and s.position=0 where j.id=pg_temp.job(110)),'the no-hold Kie pause holds no reservation and is no FAL submit refusal');
select pg_temp.kcap_resume(110,1,(select c#>>'{source,request_key}'from kcap_b0),'no-hold Kie pause');
create temporary table kcap_b1 as select pg_temp.kcap_dispatch(110)c;
select pg_temp.ok((select c#>>'{source,request_key}'<>(select c#>>'{source,request_key}'from kcap_b0)and c#>>'{source,request_key}'='bgvideo:'||(c#>>'{source,attempt_id}')from kcap_b1),'the resumed Kie source dispatches under a new request key');
select pg_temp.ok((property_video_job_cancel((select actor from bf),pg_temp.job(110))->>'cancelled')::boolean,'owner cancels the resumed no-hold Kie job');
-- (2) Definite Kie 402, 401 and 403 refusals, each with its hold released:
-- three resumes, then the next pause is not resumable.
create temporary table kcap_a as select property_video_job_admit((select actor from bf),pg_temp.recipe(111),335,'kie-kling3-4k-steady-v1')a;
create temporary table kcap_keys(n integer,request_key text);
insert into kcap_keys select 1,pg_temp.kcap_cycle(111,402,0,'first Kie refusal (402)');
select pg_temp.kcap_resume(111,1,(select request_key from kcap_keys where n=1),'first Kie refusal (402)');
insert into kcap_keys select 2,pg_temp.kcap_cycle(111,401,1,'second Kie refusal (401)');
select pg_temp.kcap_resume(111,2,(select request_key from kcap_keys where n=2),'second Kie refusal (401)');
insert into kcap_keys select 3,pg_temp.kcap_cycle(111,403,2,'third Kie refusal (403)');
select pg_temp.kcap_resume(111,3,(select request_key from kcap_keys where n=3),'third Kie refusal (403)');
insert into kcap_keys select 4,pg_temp.kcap_cycle(111,402,3,'fourth Kie refusal (402)');
select pg_temp.refuse($q$select property_video_job_resume((select actor from bf),pg_temp.job(111),335)$q$,'RP409: This saved video is not a safely resumable capacity pause','a Kie pause after three resumes is refused');
select pg_temp.ok((select j.state='failed'and j.quality_profile='kie-kling3-4k-steady-v1'and j.quality_identity::text=pg_temp.kie()::text and s.state='failed'and s.admission_retries=3
  and jsonb_array_length(s.non_dispatch_history)=3 and s.request_key=(select request_key from kcap_keys where n=4)
  from property_video_jobs j join property_video_job_sources s on s.job_id=j.id and s.position=0 where j.id=pg_temp.job(111)),'the refused resume changes nothing');
select pg_temp.ok((select count(*)=4 and count(distinct request_key)=4 and bool_and(request_key~'^bgvideo:[0-9a-f-]{36}$')from kcap_keys),'every resumed Kie attempt used a new request key');
select pg_temp.ok((select count(*)=4 and string_agg(r.rejection_status::text,','order by k.n)='402,401,403,402'and bool_and(r.provider='kie'and r.total_cents=167.5 and r.released_at is not null and r.settled_at is null and r.cost_ledger_id is null)
  and not exists(select 1 from cost_ledger l where l.meta->>'request_key'in(select request_key from kcap_keys))
  from kcap_keys k join app_video_cost_reservations r on r.idempotency_key=k.request_key),'four released Kie holds and no ledger charge');
-- (3) Even a released Kie 403 filed under the FAL refusal code never matches
-- the FAL-only receipt (provider fal, 210 cents, 403): no submit-refusal
-- recovery and, outside the capacity pause, no resume.
create temporary table kcap_d as select property_video_job_admit((select actor from bf),pg_temp.recipe(112),335,'kie-kling3-4k-steady-v1')a;
create temporary table kcap_d0 as select pg_temp.kcap_dispatch(112)c;
select pg_temp.ok((pg_temp.kcap_refused((select c from kcap_d0),403)->>'released')::boolean,'a definite Kie 403 is recorded');
select pg_temp.ok(property_video_job_failure(pg_temp.job(112),(select(c#>>'{source,lease_token}')::uuid from kcap_d0),(select(c#>>'{source,attempt_id}')::uuid from kcap_d0),'provider_submit_refused',false),'the worker files the Kie refusal under the FAL code');
select pg_temp.ok((select s.state='failed'and s.last_error='provider_submit_refused'and property_video_submit_refusal(s.job_id,s.attempt_id)is null and not property_video_submit_resume_available(s.job_id)
  from property_video_job_sources s where s.job_id=pg_temp.job(112)and s.position=0),'a released Kie 403 never matches the FAL-only submit-refusal receipt');
select pg_temp.refuse($q$select property_video_job_resume((select actor from bf),pg_temp.job(112),335)$q$,'RP409:','a Kie source outside the capacity pause cannot resume as a FAL submit refusal');
-- (4) An unreleased Kie hold (the POST may have been sent) is never reset: the
-- capacity pause refuses, the uncertain dispatch goes to reconciliation, the
-- job cannot resume and the hold stays held exactly once.
create temporary table kcap_c as select property_video_job_admit((select actor from bf),pg_temp.recipe(113),335,'kie-kling3-4k-steady-v1')a;
create temporary table kcap_c0 as select pg_temp.kcap_dispatch(113)c;
select pg_temp.ok((pg_temp.kie_reserve((select c from kcap_c0))->>'reserved')::boolean,'the uncertain Kie attempt holds its 167.5');
select pg_temp.refuse($q$select pg_temp.kcap_pause((select c from kcap_c0))$q$,'RP409: Accepted or uncertain supplier work cannot be reset','an unreleased Kie hold cannot be filed as a capacity pause');
select pg_temp.ok(pg_temp.kcap_pause((select c from kcap_c0),true),'the uncertain Kie dispatch is filed as ambiguous');
select pg_temp.ok((select j.state='needs_reconciliation'and s.state='ambiguous'and j.quality_identity::text=pg_temp.kie()::text from property_video_jobs j join property_video_job_sources s on s.job_id=j.id and s.position=0 where j.id=pg_temp.job(113)),'the uncertain Kie hold moves the job to reconciliation');
select pg_temp.refuse($q$select property_video_job_resume((select actor from bf),pg_temp.job(113),335)$q$,'RP409:','an unreleased (ambiguous) Kie hold is not resumable');
select pg_temp.ok((select count(*)=1 and bool_and(provider='kie'and total_cents=167.5 and released_at is null and settled_at is null)from app_video_cost_reservations where idempotency_key=(select c#>>'{source,request_key}'from kcap_c0)),'the uncertain Kie hold stays held exactly once');
select pg_temp.ok(pg_temp.kcap_fal()=(select s from kcap_fal_before),'Kie capacity pauses leave every FAL and legacy job, source, route and reservation untouched');
select pg_temp.ok((select bool_and(case when quality_profile='kie-kling3-4k-steady-v1'then quality_identity::text=pg_temp.kie()::text else quality_identity is null end)from property_video_jobs),'every saved job still carries exactly its profile identity');
reset role;select jsonb_build_object('passed',true,'assertions',(select n from checks));
rollback;
