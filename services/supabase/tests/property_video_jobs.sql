\set ON_ERROR_STOP on
begin;
create temporary table checks(n integer);insert into checks values(0);grant all on checks to service_role,authenticated;
create function pg_temp.ok(v boolean,label text)returns void language plpgsql as $$begin if v is distinct from true then raise exception'BGVIDEO FAIL: %',label;end if;update checks set n=n+1;end$$;
create function pg_temp.refuse(command text,needle text,label text)returns void language plpgsql as $$begin begin execute command;exception when others then if position(needle in sqlerrm)>0 then perform pg_temp.ok(true,label);return;end if;raise;end;raise exception'BGVIDEO FAIL: allowed %',label;end$$;

-- Closed synthetic provider transport, actual paid binding/QC/fallback RPCs.
-- These rows attest receipt authority only, never real generated pixels.
create function pg_temp.paid_clip(c jsonb)returns jsonb language plpgsql as $$declare j public.property_video_jobs;src public.property_video_job_sources;rid uuid:=gen_random_uuid();lid uuid:=gen_random_uuid();request text;prov public.media_provenance;claim jsonb;begin
 select * into j from public.property_video_jobs where id=(c#>>'{job,id}')::uuid;select * into src from public.property_video_job_sources where job_id=j.id and attempt_id=(c#>>'{source,attempt_id}')::uuid;
 request:='fixture-provider:'||src.attempt_id;
 insert into public.app_video_cost_reservations(id,actor_id,org_id,idempotency_key,feature,provider,model,input_sha256,units,unit_cost_cents,total_cents,hold_cents,meta)values(rid,j.actor_id,j.org_id,src.request_key,'reel','fal','fixture-model',src.source->>'sha256',1,.0001,.0001,.0001,'{"task":"video.reel_clip"}');
 insert into public.cost_ledger(id,org_id,feature,provider,model,total_cents,meta)values(lid,j.org_id,'reel','fal','fixture-model',.0001,jsonb_build_object('app_video_reservation_id',rid,'request_id',request,'request_key',src.request_key,'stage','reel'));
 update public.app_video_cost_reservations set provider_request_id=request,cost_ledger_id=lid,settled_at=now()where id=rid;
 insert into public.app_video_allowance_receipts(reservation_id,listing_id,monthly_key,monthly_window_start,burst_key,burst_window_start)values(rid,j.listing_id,'fixture-month',now(),'fixture-burst',now());
 perform public.property_video_job_receipt(j.id,src.attempt_id,jsonb_build_object('request_id',request,'model_id','fixture-model'));
 prov:=public.property_video_job_provenance(j.id,src.attempt_id,request,'fixture-model');
 perform public.bind_property_video_source(j.actor_id,j.listing_id,src.asset_id,src.photo_provenance_id,request,prov.id,src.source->>'sha256',repeat('d',32));
 perform public.property_video_job_clip(j.id,src.attempt_id,jsonb_build_object('storage_key','private-fixture/'||src.attempt_id||'.mp4','sha256',repeat('e',64),'width',1088,'height',1920,'duration_s',5.042));
 claim:=public.property_video_job_claim(j.id,'slot-0');if claim->>'action'<>'extract_frames'then raise exception'BGVIDEO FAIL: paid fixture did not claim quality extraction';end if;return claim;end$$;
create function pg_temp.reject_claim(c jsonb)returns void language plpgsql as $$declare q jsonb;j public.property_video_jobs;src public.property_video_job_sources;verdict jsonb;begin
 q:=pg_temp.paid_clip(c);select * into j from public.property_video_jobs where id=(q#>>'{job,id}')::uuid;select * into src from public.property_video_job_sources where job_id=j.id and attempt_id=(q#>>'{source,attempt_id}')::uuid;
 verdict:=jsonb_build_object('task','judge.qc_drift','request_id',src.receipt->>'request_id','source_sha256',repeat('d',32),'verdict','fail','action','refuse','publishable',false,'failed',jsonb_build_array('architecture'));
 update public.media_provenance set qc=verdict where id=src.generation_provenance_id;
 insert into public.cost_ledger(org_id,feature,provider,model,total_cents,meta)values(j.org_id,'qc','openai','fixture-judge',.0001,verdict||jsonb_build_object('kind','video_drift','provenance_id',src.generation_provenance_id,'source_asset_id',src.asset_id));
 perform public.property_video_job_failure(j.id,src.lease_token,src.attempt_id,'quality_check_refused',false);end$$;

insert into auth.users(id,email,is_anonymous)values('f1100000-0000-4000-8000-000000000001','background-owner@fixture.invalid',false),('f1100000-0000-4000-8000-000000000002','background-other@fixture.invalid',false);
create temporary table bf as select 'f1100000-0000-4000-8000-000000000001'::uuid actor,'f1100000-0000-4000-8000-000000000002'::uuid other,(select org_id from memberships where user_id='f1100000-0000-4000-8000-000000000001'and role='owner'limit 1)org,(select org_id from memberships where user_id='f1100000-0000-4000-8000-000000000002'and role='owner'limit 1)other_org,'f1300000-0000-4000-8000-000000000001'::uuid listing;
grant select on bf to service_role,authenticated;
-- This fixture exercises paid background video delivery, not the unpaid
-- free-week gate. Keep its owner on a normal paid workspace.
update orgs set plan='starter',plan_source='manual' where id=(select org from bf);
insert into listings(id,org_id,agent_id,address)values((select listing from bf),(select org from bf),(select actor from bf),'Synthetic background property');
set local session_replication_role=replica;
insert into capture_assets(id,listing_id,kind,bucket,storage_key,bytes,sha256,uploaded,transport_version,content_type)select md5('bg-photo:'||i)::uuid,(select listing from bf),'photo','renders','renders/'||(select org from bf)||'/'||(select listing from bf)||'/gallery-'||i||'.jpg',100,repeat('a',64),true,2,'image/jpeg'from generate_series(1,100)i;
insert into upload_reservations(asset_id,org_id,listing_id,actor_id,day,spec,held_bytes,spent_bytes,state,settled_at)select id,(select org from bf),listing_id,(select actor from bf),current_date,'{}',0,bytes,'completed',now()from capture_assets where listing_id=(select listing from bf);
insert into upload_operations(asset_id,kind,bucket,object_key,bytes,expected_bytes,content_type,content_type_declared,asset_kind,state,etag)select id,'copy',bucket,storage_key,bytes,bytes,content_type,true,kind,'retained','"source-etag"'from capture_assets where listing_id=(select listing from bf);
set local session_replication_role=origin;
create temporary table bm as select jsonb_build_object('operation_id','f1700000-0000-4000-8000-000000000001','listing_id',listing,'expected_org_id',org,'purpose','listing','aspect','16:9','allow_original_photo_fallback',true,'presentation',jsonb_build_object('transition','cut','shot_caption_style','off','spoken_captions',false,'title_card',null,'shot_labels',(select jsonb_agg(null::text)from generate_series(1,100))),'music',null,'narration_asset_id',null,'narration_result_id',null,'narration_words','[]'::jsonb,'sources',(select jsonb_agg(jsonb_build_object('photo_id','selected:'||i,'photo_asset_id',md5('bg-photo:'||i)::uuid,'photo_version_id','staged-selected-'||i,'photo_provenance_id',null,'motion','push_in')order by i)from generate_series(1,100)i))m from bf;
grant select on bm to service_role,authenticated;
select pg_temp.ok((select bool_and(relrowsecurity)from pg_class where relname in('property_video_jobs','property_video_job_sources','property_video_job_outputs','property_video_audio_assets','property_video_stop_operations','property_video_music_catalog')),'all new API tables have RLS');
select pg_temp.ok(not exists(select 1 from information_schema.role_table_grants where table_name like'property_video_job%'and grantee in('anon','authenticated')),'clients cannot forge jobs/source/output rows');
select pg_temp.ok(not has_function_privilege('authenticated','public.property_video_job_claim(uuid,text)','execute'),'client cannot claim supplier admission');
select pg_temp.ok(not has_function_privilege('authenticated','public.property_video_job_cancel_all(uuid,uuid,text)','execute'),'client cannot impersonate cancellation actor');
select pg_temp.ok((select value->>'enabled'='false'from app_config where key='property_video_jobs'),'background runtime ships inactive');
select pg_temp.ok((select bool_and(not enabled)from property_video_music_catalog),'music activation remains off');
select pg_temp.ok((select intended_usd_cents=2500 and not production_enabled and not sandbox_enabled from property_website_products where product_id='com.rendprop.app.website.premium.property'),'25-dollar price intent does not activate SKU');
set local role service_role;
select pg_temp.refuse('select property_video_job_enqueue((select actor from bf),(select m from bm))','RP503:','inactive runtime refuses enqueue');
reset role;update app_config set value=jsonb_set(value,'{enabled}','true')where key='property_video_jobs';set local role service_role;
select pg_temp.refuse('select property_video_job_enqueue((select other from bf),(select m from bm))','RP403:','other account cannot submit property');
select pg_temp.refuse($q$select property_video_job_enqueue((select actor from bf),(select jsonb_set(m,'{sources}',(m->'sources')||(m#>'{sources,0}'))from bm))$q$,'RP400:','101 source request refuses before job');
create temporary table bj as select(property_video_job_enqueue((select actor from bf),(select m from bm))).*;grant select on bj to service_role,authenticated;
select pg_temp.ok((select source_count=100 from bj),'100 exact selected sources accepted');
select pg_temp.ok((select count(*)=100 and min(position)=0 and max(position)=99 from property_video_job_sources where job_id=(select id from bj)),'100 source positions retained without drops');
select pg_temp.ok((property_video_job_enqueue((select actor from bf),(select m from bm))).id=(select id from bj),'same saved operation retries without another job');
select pg_temp.refuse($q$select property_video_job_enqueue((select actor from bf),(select jsonb_set(m,'{allow_original_photo_fallback}','false')from bm))$q$,'RP409:','same operation cannot replace its frozen options');
select pg_temp.refuse('select property_video_job_scope((select id from bj),(select other from bf),false)','RP404:','foreign account cannot inspect job');
select pg_temp.refuse($q$select property_video_job_claim((select id from bj),'other-slot')$q$,'insufficient_privilege','unbounded worker identity refused');
create temporary table claim1 as select property_video_job_claim((select id from bj),'slot-0')c;create temporary table claim2 as select property_video_job_claim((select id from bj),'slot-1')c;
select pg_temp.ok((select c->>'action'='dispatch'from claim1)and(select c->>'action'='dispatch'from claim2),'two granted shots are distinct');
select pg_temp.ok(property_video_job_claim((select id from bj),'slot-0')->>'action'='wait','third supplier admission waits');
select pg_temp.refuse($q$select property_video_job_receipt((select id from bj),(select(c#>>'{source,attempt_id}')::uuid from claim1),' {"request_id":"unpaid-provider"}'::jsonb)$q$,'RP409:','unsettled provider boolean is not a paid receipt');
select pg_temp.refuse($q$select property_video_job_qc((select id from bj),(select(c#>>'{source,lease_token}')::uuid from claim1),(select(c#>>'{source,attempt_id}')::uuid from claim1))$q$,'RP409:','no provider/QC ledger cannot claim AI ready');
select pg_temp.reject_claim((select c from claim1));
select pg_temp.reject_claim((select c from claim2));
-- These are98 separate normal RPC requests, not one aggregate production
-- statement. Retain the30s per-call deadline on slower/JIT-enabled hosts.
select format($sequence$
do $claim$declare c jsonb;begin
 c:=property_video_job_claim((select id from bj),'slot-0');
 if c->>'action'<>'dispatch'then raise exception using message='100-source sequential admission dropped position'||%s||': '||c;end if;
 perform pg_temp.reject_claim(c);
end$claim$;
$sequence$,i)from generate_series(3,100)i
\gexec
select pg_temp.ok((select count(*)=100 and bool_and(fallback_evidence->>'action'='refuse')from property_video_job_sources where job_id=(select id from bj)and state='original_photo'),'all100 explicit original-photo fallbacks preserve order');
create temporary table comp as select property_video_job_claim((select id from bj),'slot-0')c;grant select on comp to service_role,authenticated;
select pg_temp.ok((select c->>'action'='compose'and jsonb_array_length(c->'sources')=100 from comp),'composition contains every selected photo');
select pg_temp.refuse($q$select property_video_job_outputs_reserve((select id from bj),gen_random_uuid(),1000,repeat('b',64),100,repeat('c',64))$q$,'RP409:','stale CPU lease cannot acquire output write');
select pg_temp.refuse($q$select property_video_job_outputs_reserve((select id from bj),(select(c#>>'{job,compose_lease}')::uuid from comp),1610612737,repeat('b',64),100,repeat('c',64))$q$,'RP400:','server output refuses above the registered1.5GiB delivery contract');
do $$declare admitted boolean:=false;o jsonb;begin
 begin
  o:=property_video_job_outputs_reserve((select id from bj),(select(c#>>'{job,compose_lease}')::uuid from comp),1610612736,repeat('b',64),100,repeat('c',64));
  admitted:=o->>'asset_id'=(select(c#>>'{job,output_asset_id}')from comp);
  raise exception using errcode='PZ002',message='Synthetic maximum reserve rollback';
 exception when sqlstate'PZ002'then null;end;
 perform pg_temp.ok(admitted,'exact1.5GiB output boundary admitted after every overlayreplay');
end$$;
create temporary table outs as select property_video_job_outputs_reserve((select id from bj),(select(c#>>'{job,compose_lease}')::uuid from comp),367001600,repeat('b',64),100,repeat('c',64))o;grant select on outs to service_role,authenticated;
select pg_temp.ok((select count(*)=2 and bool_and(state='reserved')from property_video_job_outputs),'actual outputs reserved before storage writes');
select pg_temp.ok((select count(*)=2 from capture_assets where id in((select(o->>'asset_id')::uuid from outs),(select(o->>'poster_asset_id')::uuid from outs))and not uploaded),'unfinished output assets cannot publish');
create temporary table facts as select jsonb_build_object('manifest_sha256',(select manifest_sha256 from bj),'asset_id',o->>'asset_id','poster_asset_id',o->>'poster_asset_id','bytes',367001600,'sha256',repeat('b',64),'poster_bytes',100,'poster_sha256',repeat('c',64),'etag','"master-etag"','poster_etag','"poster-etag"','width',1920,'height',1080,'duration_s',500)f from outs;grant select on facts to service_role,authenticated;
select pg_temp.refuse($q$select property_video_job_finish((select id from bj),(select(c#>>'{job,compose_lease}')::uuid from comp),(select jsonb_set(f,'{height}','720')from facts))$q$,'RP400:','720p is refused despite output receipt');
select pg_temp.refuse($q$select property_video_job_finish((select id from bj),(select(c#>>'{job,compose_lease}')::uuid from comp),(select jsonb_set(f,'{manifest_sha256}','"changed"')from facts))$q$,'RP409:','source manifest mismatch cannot finalize');
create temporary table finished as select(property_video_job_finish((select id from bj),(select(c#>>'{job,compose_lease}')::uuid from comp),(select f from facts))).*;grant select on finished to authenticated;select pg_temp.ok((select state='ready'from finished),'actual100-source finish atomically registers master/poster');
select pg_temp.ok((select jsonb_array_length(result->'sources')=100 and result->>'original_photo_count'='100'and result->>'branding_policy'='unbranded'and result->'music'='null'::jsonb from property_video_jobs where id=(select id from bj)),'ready result honestly labels100 original sources and musicOff');
select pg_temp.ok((select result#>>'{sources,99,photo_version_id}'='staged-selected-100'from property_video_jobs where id=(select id from bj)),'selected version order persists to output');
select pg_temp.ok((select count(*)=1 from notification_outbox where dedupe_key='property_video_ready:'||(select id from bj)||':'||(select actor from bf)),'ready notification queued exactlyonce');
select pg_temp.ok((select count(*)=0 from renders where listing_id=(select listing from bf)),'completion never automatically publishes');
select pg_temp.ok(property_video_notification_current((select id from bj),(select actor from bf)),'current private ready notification passes');
select pg_temp.ok(not property_video_notification_current((select id from bj),(select other from bf)),'notification cannot switch recipient');
select pg_temp.ok(property_owned_upload((select actor from bf),(select listing from bf),(select(o->>'asset_id')::uuid from outs),'video')->>'etag'='"master-etag"','server output integrates actual owned-media authority');
-- Larger-than-generic real SQL output receipt/authority; no object is fetched
-- or claimed to be encoded by this transport-free role/budget fixture.
select pg_temp.ok((background_video_delivery((select actor from bf),(select org from bf),(select listing from bf),(select o->>'key'from outs),0)->>'bytes')::bigint=367001600,'registered350MiB master has exact larger byte authority');
select pg_temp.ok(background_video_delivery(null,(select org from bf),(select listing from bf),(select o->>'key'from outs),0)->>'max_object_bytes'='1610612736','public authority has same exact registered master ceiling');
select pg_temp.refuse($q$select background_video_delivery((select other from bf),(select org from bf),(select listing from bf),(select o->>'key'from outs),0)$q$,'RP404:','foreign actor cannot borrow private large master');
select pg_temp.refuse($q$select background_video_delivery(null,(select other_org from bf),(select listing from bf),(select o->>'key'from outs),367001600)$q$,'RP403:','wrong physicalorg cannot claim registered limit');
select pg_temp.refuse($q$select background_video_delivery(null,(select org from bf),(select listing from bf),(select o->>'key'||'-forged'from outs),367001600)$q$,'RP403:','background key pattern cannot authorize unregistered bytes');
select pg_temp.refuse($q$select background_video_delivery(null,(select org from bf),(select listing from bf),(select o->>'key'from outs),367001601)$q$,'RP400:','large read cannot exceed exact saved master bytes');
select pg_temp.ok(not has_function_privilege('authenticated','public.background_video_delivery(uuid,uuid,uuid,text,bigint)','execute')and not has_function_privilege('anon','public.background_video_delivery(uuid,uuid,uuid,text,bigint)','execute'),'registered larger-object authority stays service-only');
-- Each authorized read meters its bounded chunks in ONE transaction. Product
-- usage is unpriced; earlier finite financial receipts are not reset or charged.
reset role;
insert into media_delivery_budgets(org_id,receipt_ref,starts_at,ends_at,request_limit,byte_limit,storage_limit,tariff,reserves,evidence_sha256)values((select org from bf),'synthetic-large-read-budget',now()-interval'1 minute',now()+interval'1 day',20,300*1024*1024,2::bigint*1024*1024*1024,'{}','{}',repeat('d',64));
create temporary table media_usage_before as select coalesce((select used_requests from media_serving_usage where org_id=(select org from bf)and usage_day=(now()at time zone'UTC')::date),0)requests,coalesce((select used_bytes from media_serving_usage where org_id=(select org from bf)and usage_day=(now()at time zone'UTC')::date),0)bytes;
grant select on media_usage_before to service_role;
set local role service_role;
select pg_temp.ok(background_video_delivery((select actor from bf),(select org from bf),(select listing from bf),(select o->>'key'from outs),367001600)->>'bytes'='367001600','authorized large media is functional despite obsolete finite budget');
select pg_temp.ok((select used_bytes=0 and used_requests=0 from media_delivery_budgets where receipt_ref='synthetic-large-read-budget'),'authorizedlarge read does not reset or charge old finite budget');
reset role;update media_delivery_budgets set byte_limit=400*1024*1024 where receipt_ref='synthetic-large-read-budget';set local role service_role;
select background_video_delivery((select actor from bf),(select org from bf),(select listing from bf),(select o->>'key'from outs),367001600);
select pg_temp.ok((select used_bytes=(select bytes from media_usage_before)+734003200 and used_requests=(select requests from media_usage_before)+4 from media_serving_usage where org_id=(select org from bf)and usage_day=(now()at time zone'UTC')::date)and(select used_bytes=0 and used_requests=0 from media_delivery_budgets where receipt_ref='synthetic-large-read-budget'),'two350MiB reads meter exact unpriced bytes across four boundedchunks without financial charge');
select pg_temp.refuse($q$select media_delivery_admit((select org from bf),367001600,true)$q$,'RP400:','generic media budgetRPC is still256MiB');
reset role;update listings set deleted_at=now()where id=(select listing from bf);set local role service_role;
select pg_temp.refuse($q$select background_video_delivery(null,(select org from bf),(select listing from bf),(select o->>'key'from outs),0)$q$,'RP404:','withdrawnlisting cannot retain larger read authority');
reset role;update listings set deleted_at=null where id=(select listing from bf);delete from media_delivery_budgets where receipt_ref='synthetic-large-read-budget';set local role service_role;
select set_config('request.jwt.claim.sub',(select actor::text from bf),true);reset role;set local role authenticated;
select pg_temp.ok(property_owned_upload((select actor from bf),(select listing from bf),(select(o->>'asset_id')::uuid from outs),'video')->>'etag'='"master-etag"','authenticated publication sees only its own server output');
select pg_temp.ok((publish_property_video((select listing from bf),(select(o->>'asset_id')::uuid from outs),jsonb_build_object('schema',1,'purpose','listing','aspect','16:9','branding_policy','unbranded','sources',(select result->'sources'from finished)),(select(o->>'poster_asset_id')::uuid from outs),'photo-video:f1900000-0000-4000-8000-000000000001')).published_at is not null,'explicit publication of verified server master succeeds');
reset role;set local role service_role;
select pg_temp.ok((property_video_job_cancel((select actor from bf),(select id from bj))->>'cancelled')::boolean=false,'cancel preserves completed reviewable result');
-- Actor-wide cancellation survives withdrawn libraries and has immutable replay.
create temporary table stops as select(property_video_job_enqueue((select actor from bf),(select jsonb_set(m,'{operation_id}','"f1700000-0000-4000-8000-000000000002"')from bm))).id id;
select pg_temp.ok(property_video_job_cancel_all((select actor from bf),'f1800000-0000-4000-8000-000000000001','ai_consent_revoked')->>'cancelled_count'='1','consentrevocation stops all pending actorjobs');
create temporary table later as select(property_video_job_enqueue((select actor from bf),(select jsonb_set(m,'{operation_id}','"f1700000-0000-4000-8000-000000000003"')from bm))).id id;
select pg_temp.ok(property_video_job_cancel_all((select actor from bf),'f1800000-0000-4000-8000-000000000001','ai_consent_revoked')->>'cancelled_count'='1','old stop retry returns firstcount');
select pg_temp.ok((select state='queued'from property_video_jobs where id=(select id from later)),'old stop retry never cancels laternewjob');
select pg_temp.refuse($q$select property_video_job_cancel_all((select actor from bf),'f1800000-0000-4000-8000-000000000001','local_data_erasure')$q$,'RP409:','same cancellation operation cannot change reason');
select property_video_job_cancel_all((select actor from bf),'f1800000-0000-4000-8000-000000000002','local_data_erasure');
-- Expired unconfirmed dispatch becomes heldreconciliation and neverresubmits.
create temporary table crash as select(property_video_job_enqueue((select actor from bf),(select jsonb_set(m,'{operation_id}','"f1700000-0000-4000-8000-000000000004"')from bm))).id id;
select property_video_job_claim((select id from crash),'slot-0');reset role;update property_video_job_sources set lease_until=now()-interval'1 second'where job_id=(select id from crash)and state='dispatching';set local role service_role;
select property_video_job_reconcile_stale();select pg_temp.ok((select state='needs_reconciliation'from property_video_jobs where id=(select id from crash)),'expired unknownpaidgrant never blindretries');
select pg_temp.refuse($q$select property_video_job_claim((select id from crash),'slot-0')$q$,'RP409:','held ambiguousjob cannot dispatchanotherpaidshot');
-- Narration is its own immutableaudio authority and ships withdisabledmusic.
create temporary table aud as select(property_video_audio_prepare((select actor from bf),jsonb_build_object('operation_id','f1600000-0000-4000-8000-000000000001','listing_id',(select listing from bf),'expected_org_id',(select org from bf),'bytes',100,'mime','audio/mp4','sha256',repeat('d',64)))).*;
select pg_temp.ok((select mime='audio/mp4'and storage_key like '%/narration/%.m4a'from aud),'ownvoice uses properaudio registry');
select pg_temp.ok((property_video_audio_complete((select actor from bf),(select id from aud),'"audio-etag"')).state='ready','ownvoice completion registers exactetag');
select pg_temp.ok((property_video_audio_prepare((select actor from bf),jsonb_build_object('operation_id','f1600000-0000-4000-8000-000000000001','listing_id',(select listing from bf),'expected_org_id',(select org from bf),'bytes',100,'mime','audio/mp4','sha256',repeat('d',64)))).state='ready','lostaudioack replaydoesnotrequestanotherPUT');
select pg_temp.refuse($q$select property_video_audio_complete((select actor from bf),(select id from aud),'"other-etag"')$q$,'RP409:','audioetag immutable');
select pg_temp.refuse($q$select property_video_audio_complete((select other from bf),(select id from aud),'"audio-etag"')$q$,'RP404:','foreignaccount cannotcompleteaudio');
-- Narration actualduration is approved BEFORE any paid shot grant.
create temporary table voice_recipe as select jsonb_set(jsonb_set(jsonb_set(m,'{operation_id}','"f1700000-0000-4000-8000-000000000080"'),'{sources}',jsonb_build_array(m#>'{sources,0}',m#>'{sources,1}')),'{narration_asset_id}',to_jsonb((select id from aud)::text))m from bm;
create temporary table voice_job as select(property_video_job_enqueue((select actor from bf),(select m from voice_recipe))).id id;
create temporary table voice_claim as select property_video_job_claim((select id from voice_job),'slot-0')c;
select pg_temp.ok((select c->>'action'='inspect_audio'from voice_claim),'voice queuedjob claims onlyCPUpreflight beforepaidshots');
select pg_temp.ok((select bool_and(state='pending'and request_key is null)from property_video_job_sources where job_id=(select id from voice_job)),'overlongvoice hasnotconsumedanyproviderattempt');
select property_video_job_audio_source((select id from voice_job),(select(c#>>'{job,audio_lease}')::uuid from voice_claim),jsonb_build_object('bucket','renders','storage_key',(select storage_key from aud),'bytes',100,'sha256',repeat('d',64),'etag','"audio-etag"','content_type','audio/mp4'));
select pg_temp.refuse($q$select property_video_job_audio_preflight((select id from voice_job),gen_random_uuid(),(select c#>>'{job,manifest_sha256}'from voice_claim),repeat('d',64),20,1)$q$,'RP409:','staleaudiolease cannotapprove orrefusetake');
select pg_temp.ok((property_video_job_audio_preflight((select id from voice_job),(select(c#>>'{job,audio_lease}')::uuid from voice_claim),(select c#>>'{job,manifest_sha256}'from voice_claim),repeat('d',64),20,1)).state='failed','20svoice on2photo10svideo refusesbefore anypaidclip');
select pg_temp.ok((select bool_and(state='pending'and attempt_id is null)from property_video_job_sources where job_id=(select id from voice_job)),'durationrefusal keepsallpaidclipsunstarted');
create temporary table short_voice_job as select(property_video_job_enqueue((select actor from bf),(select jsonb_set(m,'{operation_id}','"f1700000-0000-4000-8000-000000000081"')from voice_recipe))).id id;
create temporary table short_voice_claim as select property_video_job_claim((select id from short_voice_job),'slot-0')c;
select property_video_job_audio_source((select id from short_voice_job),(select(c#>>'{job,audio_lease}')::uuid from short_voice_claim),jsonb_build_object('bucket','renders','storage_key',(select storage_key from aud),'bytes',100,'sha256',repeat('d',64),'etag','"audio-etag"','content_type','audio/mp4'));
select pg_temp.ok((property_video_job_audio_preflight((select id from short_voice_job),(select(c#>>'{job,audio_lease}')::uuid from short_voice_claim),(select c#>>'{job,manifest_sha256}'from short_voice_claim),repeat('d',64),10.05,1)).audio_preflight->>'duration_s'='10.05','codec paddingtolerance admits cuttakewithouttrim');
select pg_temp.ok(property_video_job_claim((select id from short_voice_job),'slot-0')->>'action'='dispatch','onlyapprovedactualduration unlockspaidshotadmission');
select property_video_job_cancel((select actor from bf),(select id from short_voice_job));
-- Whole-recipe capacity refuses impossible workloads before supplier admission.
select pg_temp.refuse($q$select property_video_recipe_capacity((select actor from bf),(select listing from bf),100,100)$q$,'RP402:','whole100-source recipe checks current customer allowance upfront');
select pg_temp.refuse($q$select property_video_recipe_capacity((select actor from bf),(select listing from bf),101,100)$q$,'RP400:','capacity quote remains100-bounded');
-- A video-specific alias is derived from the exact selected master, not a
-- browser upload claim. Only transport bytes are synthetic in this SQL suite.
reset role;update listings set gallery_asset_ids=array[md5('bg-photo:1')::uuid]where id=(select listing from bf);set local role service_role;
create temporary table prep_body as select jsonb_build_object('operation_id','f1500000-0000-4000-8000-000000000001','listing_id',(select listing from bf),'expected_org_id',(select org from bf),'photo_id','selected:1','photo_asset_id',md5('bg-photo:1')::uuid,'photo_version_id','asset:'||md5('bg-photo:1')::uuid,'photo_provenance_id',null)b;
create temporary table prep as select to_jsonb(property_video_preparation_enqueue((select actor from bf),(select b from prep_body)))p;
select pg_temp.ok((property_video_preparation_enqueue((select actor from bf),(select b from prep_body))).id=(select(p->>'id')::uuid from prep),'prepare lostPOST preserves operation andselectedmaster');
select pg_temp.refuse($q$select property_video_preparation_enqueue((select actor from bf),(select jsonb_set(jsonb_set(b,'{operation_id}','"f1500000-0000-4000-8000-000000000002"'),'{photo_asset_id}',to_jsonb(md5('bg-photo:2')::uuid))from prep_body))$q$,'RP409:','unselected master cannotcreatealias');
create temporary table prep_claim as select property_video_preparation_claim((select(p->>'id')::uuid from prep))c;
select pg_temp.ok((select c->>'action'='prepare_image'from prep_claim),'one CPUpreparation lease granted');
select pg_temp.ok(property_video_preparation_claim((select(p->>'id')::uuid from prep))->>'action'='wait','secondCPUcaller waits ratherthan duplicateencode');
select pg_temp.refuse($q$select property_video_preparation_outputs((select(p->>'id')::uuid from prep),gen_random_uuid(),repeat('a',64),(select(c#>>'{preparation,asset_id}')::uuid from prep_claim),100,repeat('e',64),2048,1536)$q$,'RP409:','stale preparation lease cannotadmitPUT');
select pg_temp.refuse($q$select property_video_preparation_outputs((select(p->>'id')::uuid from prep),(select(c#>>'{preparation,lease_token}')::uuid from prep_claim),repeat('b',64),(select(c#>>'{preparation,asset_id}')::uuid from prep_claim),100,repeat('e',64),2048,1536)$q$,'RP400:','prepared derivative mustmatch originalsource SHA');
select pg_temp.refuse($q$select property_video_preparation_outputs((select(p->>'id')::uuid from prep),(select(c#>>'{preparation,lease_token}')::uuid from prep_claim),repeat('a',64),(select(c#>>'{preparation,asset_id}')::uuid from prep_claim),100,repeat('e',64),2049,1536)$q$,'RP400:','preparedtarget stays withinactual provider2048 inputbound');
select property_video_preparation_outputs((select(p->>'id')::uuid from prep),(select(c#>>'{preparation,lease_token}')::uuid from prep_claim),repeat('a',64),(select(c#>>'{preparation,asset_id}')::uuid from prep_claim),100,repeat('e',64),2048,1536);
select pg_temp.refuse($q$select property_owned_upload((select actor from bf),(select listing from bf),(select(c#>>'{preparation,asset_id}')::uuid from prep_claim),'photo')$q$,'RP409:','unfinishedderivedJPEG cannot beproviderinput');
select property_video_preparation_finish((select(p->>'id')::uuid from prep),(select(c#>>'{preparation,lease_token}')::uuid from prep_claim),'"prepared-etag"');
select pg_temp.ok((property_video_preparation_finish((select(p->>'id')::uuid from prep),(select(c#>>'{preparation,lease_token}')::uuid from prep_claim),'"prepared-etag"')).state='ready','finishedpreparation retry is idempotent');
select pg_temp.ok(property_owned_upload((select actor from bf),(select listing from bf),(select(c#>>'{preparation,asset_id}')::uuid from prep_claim),'photo')->>'sha256'=repeat('e',64),'readyderivedsource hasexactregistered SHA');
select pg_temp.ok((select bytes=100 and sha256=repeat('a',64)and storage_key like '%/gallery-1.jpg'from capture_assets where id=md5('bg-photo:1')::uuid),'preparedinput leavesoriginalbytes/hash/key unchanged');
select pg_temp.ok((select gallery_asset_ids=array[md5('bg-photo:1')::uuid]from listings where id=(select listing from bf)),'videoinput doesnotreplace selectedgallerymaster');
select pg_temp.refuse($q$select property_photo_reference((select actor from bf),(select listing from bf),(select(c#>>'{preparation,asset_id}')::uuid from prep_claim),'f1800000-0000-4000-8000-000000000001')$q$,'RP409:','preparedalias cannotrelabel mastereffects');
reset role;set local session_replication_role=replica;update capture_assets set uploaded=false where id=md5('bg-photo:1')::uuid;set local session_replication_role=origin;set local role service_role;
select pg_temp.refuse($q$select property_owned_upload((select actor from bf),(select listing from bf),(select(c#>>'{preparation,asset_id}')::uuid from prep_claim),'photo')$q$,'RP409:','withdrawingmaster also withdrawsderivedinput');
reset role;set local session_replication_role=replica;update capture_assets set uploaded=true where id=md5('bg-photo:1')::uuid;set local session_replication_role=origin;set local role service_role;
create temporary table refused_recipe as select jsonb_set(m,'{operation_id}','"f1700000-0000-4000-8000-000000000050"')m from bm;
select pg_temp.ok(property_video_job_admit((select actor from bf),(select m from refused_recipe),10000)->>'operation_closed'='true','capacity refusal permanently closes operation before any paid clip');
select pg_temp.ok(property_video_operation_lookup((select actor from bf),(select listing from bf),(select org from bf),'f1700000-0000-4000-8000-000000000050')->>'operation_closed'='true','lookup echoes durable refused identity');
select pg_temp.refuse('select property_video_job_enqueue((select actor from bf),(select m from refused_recipe))','RP409:','closed refusal cannot later race into accepted job');
select pg_temp.ok(not(property_video_operation_lookup((select actor from bf),(select listing from bf),(select org from bf),'f1700000-0000-4000-8000-000000000051')->>'operation_closed')::boolean,'unknown null operation never claims conclusive refusal');
-- Ordinary paidStarter actualreceipt window, no sponsored/unlimited grant.
reset role;update app_config set value='{"mode":"ceiling","free_published_listings":1}'where key='serving_mode';
set local role service_role;
select apply_apple_entitlement_v2((select org from bf),(select actor from bf),'bg-paid-original','bg-paid-transaction','com.rendprop.app.starter.monthly','max','Production','active',now()+interval'29 days',true,'DID_RENEW',now()-interval'1 day',now()-interval'30 seconds',now()-interval'30 seconds',now()-interval'30 seconds');
select pg_temp.ok((org_entitlement((select org from bf))).reels_per_month=30 and not org_has_internal_testing_grant((select org from bf)),'ordinaryMax allows30 photo shots without owner grant');
select pg_temp.ok((plan_serving_ceiling((select org from bf))->>'ceiling_cents')::integer=2032,'Max50percentnetallocation deducts actual hosting reserve');
select pg_temp.ok((property_video_recipe_capacity((select actor from bf),(select listing from bf),20,676.908+622.592+20)->>'admitted')::boolean,'normalMax paidwindow admits20stage plus20defaultclips QC/planner bound');
create temporary table accepted_job as select(property_video_job_enqueue((select actor from bf),(select jsonb_set(m,'{operation_id}','"f1700000-0000-4000-8000-000000000052"')from bm))).id id;
create temporary table accepted_claim as select property_video_job_claim((select id from accepted_job),'slot-0')c;
select app_video_cost_reserve((select actor from bf),(select org from bf),(select c#>>'{source,request_key}'from accepted_claim),'reel','fal','bytedance/seedance/v1/pro/fast/image-to-video',repeat('a',64),24.3,5,4.86,'{}');
select pg_temp.ok(property_video_job_receipt((select id from accepted_job),(select(c#>>'{source,attempt_id}')::uuid from accepted_claim),'{"request_id":"accepted-before-ledger","model_id":"bytedance/seedance/v1/pro/fast/image-to-video","status_url":"https://private.invalid/status?job=opaque","response_url":"https://private.invalid/result?job=opaque","seconds":5}'),'accepted receipt saved before settlement to avoid duplicatepaidPOST');
select pg_temp.ok((select settled_at is null from app_video_cost_reservations where idempotency_key=(select c#>>'{source,request_key}'from accepted_claim)),'acceptance recovery keeps pricedunsettledhold intact');
-- A real accepted receipt must not serialize the entire remaining recipe.
create temporary table accepted_second as select property_video_job_claim((select id from accepted_job),'slot-1')c;
select pg_temp.ok((select c->>'action'='dispatch'and c#>>'{source,position}'='1'and c#>>'{source,request_key}'is distinct from(select c#>>'{source,request_key}'from accepted_claim)from accepted_second),'accepted first shot doesnotstarve second pending admission');
select app_video_cost_reserve((select actor from bf),(select org from bf),(select c#>>'{source,request_key}'from accepted_second),'reel','fal','bytedance/seedance/v1/pro/fast/image-to-video',repeat('a',64),24.3,5,4.86,'{}');
select property_video_job_receipt((select id from accepted_job),(select(c#>>'{source,attempt_id}')::uuid from accepted_second),'{"request_id":"accepted-second-before-ledger","model_id":"bytedance/seedance/v1/pro/fast/image-to-video","seconds":5}');
create temporary table fair_poll as select property_video_job_claim((select id from accepted_job),'slot-0')c;
select pg_temp.ok((select c->>'action'='poll'and c#>>'{source,position}'='0'from fair_poll),'two accepted receipts firstpoll preserves stableposition tie');
select property_video_job_poll_release((select id from accepted_job),(select(c#>>'{source,lease_token}')::uuid from fair_poll),(select(c#>>'{source,attempt_id}')::uuid from fair_poll));
update fair_poll set c=property_video_job_claim((select id from accepted_job),'slot-1');
select pg_temp.ok((select c->>'action'='poll'and c#>>'{source,position}'='1'from fair_poll),'neverchecked secondreceipt polledbefore firstagain');
select property_video_job_poll_release((select id from accepted_job),(select(c#>>'{source,lease_token}')::uuid from fair_poll),(select(c#>>'{source,attempt_id}')::uuid from fair_poll));
update fair_poll set c=property_video_job_claim((select id from accepted_job),'slot-0');
select pg_temp.ok((select c->>'action'='poll'and c#>>'{source,position}'='0'from fair_poll),'poll alternatesback to oldestchecked receipt');
select pg_temp.ok((select count(*)=2 and count(distinct provider_status_checked_at)=2 from property_video_job_sources where job_id=(select id from accepted_job)and state='processing'),'poll claims record independentactualclocktimes withintesttransaction');
select pg_temp.ok((select receipt->>'request_id'='accepted-before-ledger'and attempt_id=(select(c#>>'{source,attempt_id}')::uuid from accepted_claim)and quality_retries=0 and quality_retry_history='[]'::jsonb from property_video_job_sources where job_id=(select id from accepted_job)and position=0),'fair polling preserves exactpaid attempt receipt and retryhistory');
select pg_temp.ok(property_video_job_clip((select id from accepted_job),(select(c#>>'{source,attempt_id}')::uuid from accepted_claim),'{"bucket":"renders","storage_key":"private-owned-retained-clip.mp4","sha256":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","bytes":100,"etag":"actual-etag","content_type":"video/mp4","width":1920,"height":1080,"duration_s":5}'),'realengine storage_key receipt accepted byactualclipregistry');
select pg_temp.ok((select receipt->>'request_id'='accepted-before-ledger'and clip->>'storage_key'='private-owned-retained-clip.mp4'from property_video_job_sources where job_id=(select id from accepted_job)and position=0),'retained provider output andreceipt remainforlaterQC');
select pg_temp.refuse($q$select property_video_job_receipt((select id from accepted_job),(select(c#>>'{source,attempt_id}')::uuid from accepted_claim),'{"request_id":"different-paid-job","model_id":"bytedance/seedance/v1/pro/fast/image-to-video"}')$q$,'RP409:','accepted receipt cannot be overwritten withanother suppliercharge');
select property_video_job_cancel((select actor from bf),(select id from accepted_job));
select pg_temp.ok(jsonb_array_length(property_video_cancelled_attempts())=0,'recentordinary polls preserve30secondcancelledstatus throttling');
reset role;update property_video_job_sources set provider_status_checked_at=now()-interval'31 seconds'where job_id=(select id from accepted_job);set local role service_role;
select pg_temp.ok(jsonb_array_length(property_video_cancelled_attempts())=2,'bothcancelledknownpaidreceipts availableonlyforstatusmetadata reconciliation');
select pg_temp.refuse($q$select property_video_cancelled_terminal((select id from accepted_job),(select(c#>>'{source,attempt_id}')::uuid from accepted_claim),'foreign-request','fal','bytedance/seedance/v1/pro/fast/image-to-video')$q$,'RP409:','wrongproviderreceipt cannotfreecancelledslot');
select pg_temp.ok(property_video_cancelled_terminal((select id from accepted_job),(select(c#>>'{source,attempt_id}')::uuid from accepted_claim),'accepted-before-ledger','fal','bytedance/seedance/v1/pro/fast/image-to-video'),'confirmedterminalmetadata freesonlyknownsupplier slot');
select pg_temp.ok(property_video_cancelled_terminal((select id from accepted_job),(select(c#>>'{source,attempt_id}')::uuid from accepted_second),'accepted-second-before-ledger','fal','bytedance/seedance/v1/pro/fast/image-to-video'),'secondterminalmetadata freesonlyitsknownsupplier slot');
select pg_temp.ok((select released_at is null and settled_at is null and hold_cents=24.3 from app_video_cost_reservations where idempotency_key=(select c#>>'{source,request_key}'from accepted_claim)),'slotreconciliation leavesmoneyliabilityandledgerbinding unchanged');
select pg_temp.ok((select provider_terminal_at is null from property_video_job_sources where job_id=(select id from crash)and state='ambiguous'),'unknownsupplieracceptance remainsfenced');
select pg_temp.ok(not has_function_privilege('authenticated','public.property_video_cancelled_terminal(uuid,uuid,text,text,text)','execute'),'clients cannotassertterminalproviderstatus');

select pg_temp.ok(public_property_tour_index_pages()->>'page_size'='200','sitemapboundarypages use bounded200-rowauthority');
-- Actual old/newfunding custody: same receipt keeps original25percent slices.
reset role;update app_config set value=jsonb_set(value,'{net_margin_bps}','7500')where key='serving_envelope';set local role service_role;
create temporary table old_funding as select provision_serving_funding((select other_org from bf),'retail','bg-old-paid-receipt',null,4000,0,now()-interval'1 day',now()-interval'1 day'+interval'1 month',1,'{"storage":10,"delivery":10,"compute":10,"email":5,"support":5,"retention":10,"uncertainty":0}',repeat('a',64))r;
select pg_temp.ok((select(r->>'total_budget_cents')::integer=1000 from old_funding),'old verifiedreceipt starts with25percent netallocation');
reset role;update app_config set value=jsonb_set(value,'{net_margin_bps}','5000')where key='serving_envelope';set local role service_role;
select pg_temp.ok(provision_serving_funding((select other_org from bf),'retail','bg-old-paid-receipt',null,4000,0,now()-interval'1 day',now()-interval'1 day'+interval'1 month',1,'{"storage":10,"delivery":10,"compute":10,"email":5,"support":5,"retention":10,"uncertainty":0}',repeat('a',64))->>'replay'='true','restoring oldreceipt doesnotreallocate anexistingpaidwindow');
select pg_temp.ok((select sum(total_budget_cents)=1000 from serving_funding_slices where funding_id=(select(r->>'funding_id')::uuid from old_funding)),'existing slicedmoneyremains1000afterallocationconfigchange');
select pg_temp.ok(provision_serving_funding((select org from bf),'retail','bg-next-paid-receipt',null,4000,0,now()-interval'1 day',now()-interval'1 day'+interval'1 month',1,'{"storage":10,"delivery":10,"compute":10,"email":5,"support":5,"retention":10,"uncertainty":0}',repeat('a',64))->>'total_budget_cents'='2000','new attestedreceipt receives50percentnet inclusivebudget');
-- Trial ceiling/photo policy hasno effect on sharedallocatedpool or priorgrants.
select pg_temp.ok((select photo_edits=5 from subscription_trial_config),'futuretrialofferallowsfivephotoedits');
select pg_temp.ok((select(value->>'trial_ceiling_cents')::integer=500 and(value->>'free_lifetime_cents')::integer=0 from app_config where key='serving_envelope'),'trial500free0bothtruthful');
set local role service_role;
select apply_apple_entitlement_v2((select other_org from bf),(select other from bf),'bg-trial-original','bg-trial-transaction','com.rendprop.app.starter.monthly','max','Production','active',now()+interval'7 days',true,'SUBSCRIBED',now(),now(),now(),now());
reset role;insert into listings(id,org_id,agent_id,address)values('f1300000-0000-4000-8000-000000000002',(select other_org from bf),(select other from bf),'Synthetic trial property');set local role service_role;
select pg_temp.ok(plan_serving_ceiling((select other_org from bf))->>'ceiling_cents'='500','ordinaryintroductorywindowuses500cap');
select pg_temp.refuse($q$select property_video_recipe_capacity((select other from bf),'f1300000-0000-4000-8000-000000000002',20,676.908+622.592+20)$q$,'RP402:','introductorytrialrefuseswholevideoquotebeforeproviderdispatch');
-- Capacity pause/retry retains alreadyaccepted sources and cannotresetcharges.
create temporary table paused_recipe as select jsonb_set(jsonb_set(m,'{operation_id}','"f1700000-0000-4000-8000-000000000060"'),'{sources}',jsonb_build_array(m#>'{sources,0}',m#>'{sources,1}'))m from bm;
create temporary table paused_job as select(property_video_job_enqueue((select actor from bf),(select m from paused_recipe))).id id;
create temporary table pause_first as select property_video_job_claim((select id from paused_job),'slot-0')c;create temporary table pause_second as select property_video_job_claim((select id from paused_job),'slot-1')c;
select pg_temp.reject_claim((select c from pause_second));
select property_video_job_failure((select id from paused_job),(select(c#>>'{source,lease_token}')::uuid from pause_first),(select(c#>>'{source,attempt_id}')::uuid from pause_first),'capacity_before_dispatch',false);
select pg_temp.ok((select state='failed'from property_video_jobs where id=(select id from paused_job)),'pre-dispatchcapacitypauses ratherthan silentlychanging usermotion tooriginal');
select pg_temp.ok((property_video_job_resume((select actor from bf),(select id from paused_job),40)).state='generating','explicitresume reuses same savedjob');
select pg_temp.ok((select state='original_photo'from property_video_job_sources where job_id=(select id from paused_job)and position=1),'resume retainsalreadycompletedprivate source');
select pg_temp.ok((select state='pending'and admission_retries=1 and non_dispatch_history#>>'{0,request_key}'=(select c#>>'{source,request_key}'from pause_first)from property_video_job_sources where job_id=(select id from paused_job)and position=0),'resume retainsnonpaidattemptaudit and resets onlysafelyunpaid source');
select pg_temp.ok((property_video_job_resume((select actor from bf),(select id from paused_job),40)).state='generating','lostresume reply replaydoesnotconsumeanotherretry');
select property_video_job_cancel((select actor from bf),(select id from paused_job));
reset role;update listings set gallery_asset_ids=(select array_agg(id order by storage_key)from capture_assets where listing_id=(select listing from bf)and storage_key like '%/gallery-%')where id=(select listing from bf);set local role service_role;
select pg_temp.ok((select cardinality(gallery_asset_ids)=100 from listings where id=(select listing from bf)),'chosenpublicgalleryaccepts100ownedcompletedimages');
create temporary table cancel_prep as select(property_video_preparation_enqueue((select actor from bf),(select jsonb_set(b,'{operation_id}','"f1500000-0000-4000-8000-000000000070"')from prep_body))).id id;
select property_video_job_cancel_all((select actor from bf),'f1800000-0000-4000-8000-000000000070','local_data_erasure');
select pg_temp.ok((select state='failed'from property_video_preparations where id=(select id from cancel_prep)),'actor erasure also stops queuedCPUpreparation');
select pg_temp.ok(not has_function_privilege('authenticated','public.public_property_tour_index_pages()','execute'),'publicedgeonlyproxiesnarrowindexRPCwithoutdatabaseprivilege');
select pg_temp.ok((plan_entitlement('trial')).photo_edits_per_month=5 and(plan_entitlement('trial')).reels_per_month=0 and(plan_entitlement('trial')).cogs_ceiling_cents=500,'trialrawmetersmatchlimitedfuturetrialpolicy');
-- SEO index requires deliberateoptin andcurrentpublication/hosting.
select pg_temp.ok(jsonb_array_length(public_property_tour_index()->'tours')=0,'private-by-defaultpubliclinks notdiscovered');
reset role;update listings set details=jsonb_build_object('allow_indexing',true)where id=(select listing from bf);set local role service_role;
select pg_temp.ok(jsonb_array_length(public_property_tour_index()->'tours')=1,'optin publishedproperty included');
select pg_temp.ok(not(public_property_tour_index()#>'{tours,0}')?'actor_id'and not(public_property_tour_index()#>'{tours,0}')?'org_id','publicindex containsnoprivatefields');
reset role;update listings set status='archived'where id=(select listing from bf);set local role service_role;select pg_temp.ok(jsonb_array_length(public_property_tour_index()->'tours')=0,'archivedproperty removedfromindex');
select pg_temp.refuse('select public_property_tour_index(null,201)','RP400:','index is bounded');

-- Actual failure/resume authority. Paid bytes are synthetic but every normal
-- claim/receipt/binding/recovery step executes the installed SQL unchanged.
reset role;update listings set status='draft'where id=(select listing from bf);set local role service_role;
create function pg_temp.cpu_job(i integer)returns jsonb language plpgsql as $$declare j public.property_video_jobs;c jsonb;begin
 j:=property_video_job_enqueue((select actor from bf),jsonb_set(jsonb_set((select m from bm),'{operation_id}',to_jsonb(('f3700000-0000-4000-8000-'||lpad(i::text,12,'0'))::text)),'{sources}',jsonb_build_array((select m#>'{sources,0}'from bm),(select m#>'{sources,1}'from bm))));
 c:=property_video_job_claim(j.id,'slot-0');return pg_temp.paid_clip(c);end$$;
create function pg_temp.exhaust_cpu(c jsonb)returns void language plpgsql as $$declare next_claim jsonb:=c;begin
 loop
  perform property_video_job_failure((next_claim#>>'{job,id}')::uuid,(next_claim#>>'{source,lease_token}')::uuid,(next_claim#>>'{source,attempt_id}')::uuid,'cpu_extract_failed',false);
  exit when(select state='failed'from property_video_jobs where id=(next_claim#>>'{job,id}')::uuid);
  next_claim:=property_video_job_claim((next_claim#>>'{job,id}')::uuid,'slot-0');
  if next_claim->>'action'<>'extract_frames'then raise exception'BGVIDEO FAIL: infrastructure retry dispatched paid generation';end if;
 end loop;end$$;
create temporary table cpu_case as select pg_temp.cpu_job(1)c;grant select on cpu_case to service_role;
select pg_temp.exhaust_cpu((select c from cpu_case));
select pg_temp.ok((select s.state='failed'and s.cpu_attempts=3 and s.receipt is not null and s.clip->>'sha256'=repeat('e',64)from property_video_job_sources s where s.job_id=(select(c#>>'{job,id}')::uuid from cpu_case)and position=0),'threeCPUinfra failures pause with paidclip, never original fallback');
select pg_temp.ok((select state='failed'from property_video_jobs where id=(select(c#>>'{job,id}')::uuid from cpu_case)),'CPU exhaustion is explicit failed quality pause');
create temporary table preserved_cpu as select attempt_id,request_key,receipt,clip,generation_provenance_id from property_video_job_sources where job_id=(select(c#>>'{job,id}')::uuid from cpu_case)and position=0;grant select on preserved_cpu to service_role;
select pg_temp.refuse($q$select property_video_job_resume((select other from bf),(select(c#>>'{job,id}')::uuid from cpu_case),0)$q$,'RP404:','foreignactor cannot recover owned paidclip');
select pg_temp.ok((property_video_job_resume((select actor from bf),(select(c#>>'{job,id}')::uuid from cpu_case),0)).state='generating','normal explicit resume accepts paid CPU-only recovery without new reel quote');
select pg_temp.ok((select row(s.attempt_id,s.request_key,s.receipt,s.clip,s.generation_provenance_id)is not distinct from row(p.attempt_id,p.request_key,p.receipt,p.clip,p.generation_provenance_id)and s.cpu_recoveries=1 and jsonb_array_length(s.cpu_recovery_history)=1 and s.cpu_recovery_history#>>'{0,cpu_attempts}'='3'from property_video_job_sources s cross join preserved_cpu p where s.job_id=(select(c#>>'{job,id}')::uuid from cpu_case)and s.position=0),'CPU recovery preserves exact paid identities and records old exhausted attempt');
create temporary table retry_cpu as select property_video_job_claim((select(c#>>'{job,id}')::uuid from cpu_case),'slot-0')c;
select pg_temp.ok((select c->>'action'='extract_frames'and c#>>'{source,attempt_id}'=(select attempt_id::text from preserved_cpu)from retry_cpu),'recovery nextaction is extraction of same paidclip, not provider dispatch');
select property_video_job_resume((select actor from bf),(select(c#>>'{job,id}')::uuid from cpu_case),0);
select pg_temp.ok((select cpu_recoveries=1 from property_video_job_sources where job_id=(select(c#>>'{job,id}')::uuid from cpu_case)and position=0),'lostresume response replay doesnot consume another CPU cycle');
select pg_temp.refuse($q$select property_video_job_failure((select(c#>>'{job,id}')::uuid from cpu_case),(select(c#>>'{source,lease_token}')::uuid from cpu_case),(select(c#>>'{source,attempt_id}')::uuid from cpu_case),'cpu_extract_failed',false)$q$,'RP409:','staleCPUcallback cannot change resumedattempt');
select pg_temp.exhaust_cpu((select c from retry_cpu));select property_video_job_resume((select actor from bf),(select(c#>>'{job,id}')::uuid from cpu_case),0);
select pg_temp.exhaust_cpu(property_video_job_claim((select(c#>>'{job,id}')::uuid from cpu_case),'slot-0'));
do $$begin for i in 3..5 loop
 perform property_video_job_resume((select actor from bf),(select(c#>>'{job,id}')::uuid from cpu_case),0);
 perform pg_temp.exhaust_cpu(property_video_job_claim((select(c#>>'{job,id}')::uuid from cpu_case),'slot-0'));
end loop;end$$;
select pg_temp.ok((select cpu_recoveries=5 and jsonb_array_length(cpu_recovery_history)=5 from property_video_job_sources where job_id=(select(c#>>'{job,id}')::uuid from cpu_case)and position=0),'five explicit CPUcycles retain complete finite history');
select pg_temp.ok((select row(s.attempt_id,s.request_key,s.receipt,s.clip,s.generation_provenance_id)is not distinct from row(p.attempt_id,p.request_key,p.receipt,p.clip,p.generation_provenance_id)from property_video_job_sources s cross join preserved_cpu p where s.job_id=(select(c#>>'{job,id}')::uuid from cpu_case)and s.position=0),'fifthCPUrecovery still preserves original paidclip identity');
select pg_temp.refuse($q$select property_video_job_resume((select actor from bf),(select(c#>>'{job,id}')::uuid from cpu_case),0)$q$,'RP409:','CPUrecovery remains finite after five explicit cycles');
select pg_temp.ok((select count(*)=1 from app_video_cost_reservations where idempotency_key=(select request_key from preserved_cpu)),'allCPU retries retain one original paid generation reservation');
-- Missing, unknown or nonstructural QC cannot become a source substitution.
create temporary table unknown_case as select pg_temp.cpu_job(2)c;
select property_video_job_failure((select(c#>>'{job,id}')::uuid from unknown_case),(select(c#>>'{source,lease_token}')::uuid from unknown_case),(select(c#>>'{source,attempt_id}')::uuid from unknown_case),'quality_check_refused',false);
select pg_temp.ok((select state='failed'and fallback_evidence is null from property_video_job_sources where job_id=(select(c#>>'{job,id}')::uuid from unknown_case)and position=0),'QCrefusal code without paid terminal structural evidence never falls back');
select pg_temp.ok(property_video_structural_rejection((select(c#>>'{job,id}')::uuid from unknown_case),(select(c#>>'{source,attempt_id}')::uuid from unknown_case))is null,'missingQC cannot certify a propertychange');
create temporary table unknown_http as select pg_temp.cpu_job(3)c;
select property_video_job_failure((select(c#>>'{job,id}')::uuid from unknown_http),(select(c#>>'{source,lease_token}')::uuid from unknown_http),(select(c#>>'{source,attempt_id}')::uuid from unknown_http),'quality_check_unconfirmed',true);
select pg_temp.ok((select s.state='failed'and j.state='failed'from property_video_job_sources s join property_video_jobs j on j.id=s.job_id where s.job_id=(select(c#>>'{job,id}')::uuid from unknown_http)and position=0),'known paidclip with unknownQC pauses rather than claiming visualchange or ambiguousproviderPOST');
select pg_temp.refuse($q$update property_video_job_sources set state='original_photo'where job_id=(select(c#>>'{job,id}')::uuid from unknown_case)and position=0$q$,'RP409:','source transition cannot bypass structural authority with fallback boolean');
-- Replayed verdict stamps alone cannot substitute for matching paid authority.
create temporary table structural_source as select s.* from property_video_job_sources s where job_id=(select id from bj)and position=0;
select pg_temp.ok(property_video_structural_rejection((select job_id from structural_source),(select attempt_id from structural_source))is not null,'actual matching paid terminal structural receipt certifies fallback');
update media_provenance set qc=jsonb_set(qc,'{action}','"hold"')where id=(select generation_provenance_id from structural_source);
select pg_temp.ok(property_video_structural_rejection((select job_id from structural_source),(select attempt_id from structural_source))is null,'unknown or hold verdict never certifies fallback');
update media_provenance set qc=jsonb_set(jsonb_set(qc,'{action}','"refuse"'),'{source_sha256}',to_jsonb(repeat('f',32)))where id=(select generation_provenance_id from structural_source);
select pg_temp.ok(property_video_structural_rejection((select job_id from structural_source),(select attempt_id from structural_source))is null,'wrong source QC hash never certifies fallback');
update media_provenance set qc=jsonb_set(jsonb_set(qc,'{source_sha256}',to_jsonb(repeat('d',32))),'{failed}','["artifacts"]')where id=(select generation_provenance_id from structural_source);
select pg_temp.ok(property_video_structural_rejection((select job_id from structural_source),(select attempt_id from structural_source))is null,'artifacts alone do not claim a structural property change');
update media_provenance set qc=jsonb_set(qc,'{failed}','["architecture"]')where id=(select generation_provenance_id from structural_source);
select pg_temp.ok(property_video_structural_rejection((select job_id from structural_source),(select attempt_id from structural_source))is not null,'restored exact terminal source verdict certifies same immutable fallback');
update media_provenance set qc=jsonb_set(qc,'{failed}','["contents"]')where id=(select generation_provenance_id from structural_source);
select pg_temp.ok(property_video_structural_rejection((select job_id from structural_source),(select attempt_id from structural_source))is null,'unpaid or mismatched QC verdict cannot certify fallback');
update media_provenance set qc=jsonb_set(qc,'{failed}','["architecture"]')where id=(select generation_provenance_id from structural_source);

-- Simulate only the exact historical pre-migration row shape, with local
-- replica fixture insertion. Production repair uses the normal scoped RPC.
create temporary table historical as select pg_temp.cpu_job(4)c;
reset role;set local session_replication_role=replica;update property_video_job_sources set state='original_photo',cpu_attempts=3,last_error='cpu_extract_failed',lease_until=null where job_id=(select(c#>>'{job,id}')::uuid from historical)and position=0;update property_video_jobs set state='failed',compose_attempts=3 where id=(select(c#>>'{job,id}')::uuid from historical);set local session_replication_role=origin;set local role service_role;
select pg_temp.refuse($q$update property_video_jobs set state='composing'where id=(select(c#>>'{job,id}')::uuid from historical)$q$,'RP409:','historical infra fallback cannot enter composition');
select pg_temp.refuse($q$update property_video_jobs set state='ready'where id=(select(c#>>'{job,id}')::uuid from historical)$q$,'RP409:','historical infra fallback cannot register ready output');
select property_video_job_resume((select actor from bf),(select(c#>>'{job,id}')::uuid from historical),0);
select pg_temp.ok((select state='processing'and cpu_recoveries=1 and cpu_recovery_history#>>'{0,previous_state}'='original_photo'from property_video_job_sources where job_id=(select(c#>>'{job,id}')::uuid from historical)and position=0),'normal recovery corrects historical unsafe fallback without losing audit');
select pg_temp.ok((select compose_attempts=0 from property_video_jobs where id=(select(c#>>'{job,id}')::uuid from historical))and(select cpu_recovery_history#>>'{0,compose_attempts}'='3'from property_video_job_sources where job_id=(select(c#>>'{job,id}')::uuid from historical)and position=0),'normal CPU recovery restores finite assembly budget and retains prior exhausted count');
select pg_temp.ok(property_video_job_claim((select(c#>>'{job,id}')::uuid from historical),'slot-0')->>'action'='extract_frames','historical recovery rechecks retained clip, never regenerates');
select property_video_job_cancel((select actor from bf),(select(c#>>'{job,id}')::uuid from historical));
select pg_temp.refuse($q$select property_video_job_failure((select(c#>>'{job,id}')::uuid from historical),(select lease_token from property_video_job_sources where job_id=(select(c#>>'{job,id}')::uuid from historical)and position=0),(select(c#>>'{source,attempt_id}')::uuid from historical),'cpu_extract_failed',false)$q$,'RP409:','cancelledjob rejects lateCPUfailure');
select pg_temp.refuse($q$select property_video_job_resume((select actor from bf),(select(c#>>'{job,id}')::uuid from historical),0)$q$,'RP409:','cancelledjob cannot resume');
select pg_temp.ok(not has_function_privilege('authenticated','public.property_video_structural_rejection(uuid,uuid)','execute')and not has_function_privilege('anon','public.property_video_job_resume(uuid,uuid,numeric)','execute'),'fallback and CPU recovery authority remains serviceonly');

-- Existing terminal paid retry must not be confused with an infrastructure
-- refusal. Synthetic receipts retain actual database authority relationships.
reset role;
create function pg_temp.retry_grant(c jsonb)returns void language plpgsql security definer as $$declare j public.property_video_jobs;s public.property_video_job_sources;r public.app_video_cost_reservations;v jsonb;begin
 select *into j from property_video_jobs where id=(c#>>'{job,id}')::uuid;select *into s from property_video_job_sources where job_id=j.id and attempt_id=(c#>>'{source,attempt_id}')::uuid;
 select *into r from app_video_cost_reservations where actor_id=j.actor_id and org_id=j.org_id and idempotency_key=s.request_key;
 v:=jsonb_build_object('task','judge.qc_drift','request_id',s.receipt->>'request_id','source_sha256',repeat('d',32),'verdict','fail','action','retry','publishable',false,'failed',jsonb_build_array('contents','additions'),'attempt',0);
 update media_provenance set qc=v where id=s.generation_provenance_id;
 insert into cost_ledger(org_id,feature,provider,model,total_cents,meta)values(j.org_id,'qc','anthropic','fixture-judge',.0001,v||jsonb_build_object('kind','video_drift','provenance_id',s.generation_provenance_id,'source_asset_id',s.asset_id));
 insert into app_video_drift_checks(reservation_id,actor_id,org_id,listing_id,source_sha256,state,result)values(r.id,j.actor_id,j.org_id,j.listing_id,repeat('d',32),'retry',jsonb_build_object('drift',v));end$$;
set local role service_role;
create temporary table retry_case as select pg_temp.cpu_job(10)c;grant select on retry_case to service_role;
select pg_temp.refuse($q$select property_video_job_quality_retry((select(c#>>'{job,id}')::uuid from retry_case),(select(c#>>'{source,lease_token}')::uuid from retry_case),(select(c#>>'{source,attempt_id}')::uuid from retry_case))$q$,'RP409:','unknownQC cannot authorize paid retry');
select pg_temp.refuse($q$update property_video_job_sources s set quality_retries=1,quality_retry_history=quality_retry_history||jsonb_build_array(jsonb_build_object('prior_source',to_jsonb(s)-'quality_retry_history','quality_grant',null))where job_id=(select(c#>>'{job,id}')::uuid from retry_case)and position=0$q$,'RP409:','directtable forgednull grant cannot append paidretryhistory');
select pg_temp.refuse($q$update property_video_job_sources s set quality_retries=1,quality_retry_history=quality_retry_history||jsonb_build_array(jsonb_build_object('prior_source',to_jsonb(s)-'quality_retry_history'))where job_id=(select(c#>>'{job,id}')::uuid from retry_case)and position=0$q$,'RP409:','directtable absentgrant cannot append paidretryhistory');
select pg_temp.retry_grant((select c from retry_case));
-- An output stamp and paid judge row are insufficient without the durable,
-- terminal exact-source decision journal; an uncertain verdict cannot spend.
reset role;
create temporary table retry_journal as select *from app_video_drift_checks where reservation_id=(select id from app_video_cost_reservations where idempotency_key=(select c#>>'{source,request_key}'from retry_case));
delete from app_video_drift_checks where reservation_id=(select reservation_id from retry_journal);
set local role service_role;
select pg_temp.ok(property_video_quality_retry_evidence((select(c#>>'{job,id}')::uuid from retry_case),(select(c#>>'{source,attempt_id}')::uuid from retry_case))is null,'missingterminaljournal cannot authorize paid retry');
reset role;insert into app_video_drift_checks select *from retry_journal;set local role service_role;
select pg_temp.ok(property_video_quality_retry_evidence((select(c#>>'{job,id}')::uuid from retry_case),(select(c#>>'{source,attempt_id}')::uuid from retry_case))is not null,'exact paid terminal retry grant is recognized');
select pg_temp.refuse($q$select property_video_job_quality_retry((select(c#>>'{job,id}')::uuid from retry_case),gen_random_uuid(),(select(c#>>'{source,attempt_id}')::uuid from retry_case))$q$,'RP409:','wronglease cannot consume paid retry grant');
create temporary table retry_preserved as select to_jsonb(s)prior,(select deadline from property_video_jobs where id=s.job_id)deadline from property_video_job_sources s where job_id=(select(c#>>'{job,id}')::uuid from retry_case)and position=0;grant select on retry_preserved to service_role;
-- Reproduce the old engine's failed quality_check_refused state and recover
-- only through the normal fresh-owner resume action.
select property_video_job_failure((select(c#>>'{job,id}')::uuid from retry_case),(select(c#>>'{source,lease_token}')::uuid from retry_case),(select(c#>>'{source,attempt_id}')::uuid from retry_case),'quality_check_refused',false);
select pg_temp.ok((property_video_job_resume((select actor from bf),(select(c#>>'{job,id}')::uuid from retry_case),0)).state='generating','normal ownerresume schedules existing paid terminal retry grant');
select pg_temp.ok((select state='pending'and motion='push_in'and quality_retries=1 and attempt_id is null and request_key is null and clip is null and receipt is null and generation_provenance_id is null from property_video_job_sources where job_id=(select(c#>>'{job,id}')::uuid from retry_case)and position=0),'one safe retry awaits new normal paidadmission');
select pg_temp.ok((select quality_retry_history#>>'{0,prior_source,attempt_id}'=(select prior->>'attempt_id'from retry_preserved)and quality_retry_history#>'{0,prior_source,clip}'=(select prior->'clip'from retry_preserved)and quality_retry_history#>'{0,prior_source,receipt}'=(select prior->'receipt'from retry_preserved)and quality_retry_history#>>'{0,prior_source,generation_provenance_id}'=(select prior->>'generation_provenance_id'from retry_preserved)and jsonb_array_length(quality_retry_history#>'{0,quality_grant,qc_ledger_ids}')=1 from property_video_job_sources where job_id=(select(c#>>'{job,id}')::uuid from retry_case)and position=0),'prior paidclip source receipt provenance andQCledger retained');
select pg_temp.ok((select deadline=(select deadline from retry_preserved)and manifest_sha256=(select c#>>'{job,manifest_sha256}'from retry_case)and operation_id=(select(c#>>'{job,operation_id}')::uuid from retry_case)from property_video_jobs where id=(select(c#>>'{job,id}')::uuid from retry_case)),'quality retry never changes originaldeadline operation ormanifest');
select pg_temp.ok((property_video_job_quality_retry((select(c#>>'{job,id}')::uuid from retry_case),(select(c#>>'{source,lease_token}')::uuid from retry_case),(select(c#>>'{source,attempt_id}')::uuid from retry_case))->>'replay')='true','lostretryack replays exact archived attempt once');
select pg_temp.refuse($q$update property_video_job_sources set quality_retries=0 where job_id=(select(c#>>'{job,id}')::uuid from retry_case)and position=0$q$,'RP409:','qualityretry counter cannot be reset');
select pg_temp.refuse($q$update property_video_job_sources set quality_retry_history='[]'where job_id=(select(c#>>'{job,id}')::uuid from retry_case)and position=0$q$,'RP409:','paidqualityhistory cannot be deleted');
create temporary table next_quality as select property_video_job_claim((select(c#>>'{job,id}')::uuid from retry_case),'slot-0')c;grant select on next_quality to service_role;
select pg_temp.ok((select c->>'action'='dispatch'and c#>>'{source,motion}'='push_in'and c#>>'{source,attempt_id}'<>(select prior->>'attempt_id'from retry_preserved)and c#>>'{source,request_key}'<>(select prior->>'request_key'from retry_preserved)from next_quality),'retryclaim gets newUUID andnormalnewfundingkey');
create temporary table second_quality as select pg_temp.paid_clip((select c from next_quality))c;grant select on second_quality to service_role;
select pg_temp.retry_grant((select c from second_quality));
select pg_temp.refuse($q$select property_video_job_quality_retry((select(c#>>'{job,id}')::uuid from second_quality),(select(c#>>'{source,lease_token}')::uuid from second_quality),(select(c#>>'{source,attempt_id}')::uuid from second_quality))$q$,'RP409:','evenanotherterminalgrant cannot create thirdgeneration');
select pg_temp.ok((select count(*)=2 from app_video_cost_reservations where actor_id=(select actor from bf)and org_id=(select org from bf)and idempotency_key in((select prior->>'request_key'from retry_preserved),(select c#>>'{source,request_key}'from second_quality))),'both realgenerationliabilities remain recorded');
select property_video_job_cancel((select actor from bf),(select(c#>>'{job,id}')::uuid from second_quality));
create temporary table stopped_retry as select pg_temp.cpu_job(11)c;grant select on stopped_retry to service_role;select pg_temp.retry_grant((select c from stopped_retry));select property_video_job_cancel((select actor from bf),(select(c#>>'{job,id}')::uuid from stopped_retry));
select pg_temp.refuse($q$select property_video_job_quality_retry((select(c#>>'{job,id}')::uuid from stopped_retry),(select(c#>>'{source,lease_token}')::uuid from stopped_retry),(select(c#>>'{source,attempt_id}')::uuid from stopped_retry))$q$,'RP409:','cancelledjob cannot consume newpaidretry');
select pg_temp.ok(not has_function_privilege('authenticated','public.property_video_job_quality_retry(uuid,uuid,uuid)','execute')and not has_function_privilege('anon','public.property_video_quality_retry_evidence(uuid,uuid)','execute'),'paidretry authority serviceonly');

reset role;select jsonb_build_object('passed',true,'assertions',n)from checks;
rollback;
