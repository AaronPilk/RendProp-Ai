-- Actual current SQL authority with synthetic transport facts; no encoded media/model/network.
-- Driver reuses the existing owned-property/photo seed without replacing production functions.
create temporary table checks(n integer);insert into checks values(0);grant all on checks to service_role,authenticated;
create function pg_temp.ok(v boolean,label text)returns void language plpgsql as $$begin if v is distinct from true then raise exception'STEADY-V2 FAIL: %',label;end if;update checks set n=n+1;end$$;
create function pg_temp.refuse(command text,needle text,label text)returns void language plpgsql as $$begin begin execute command;exception when others then if position(needle in sqlerrm)>0 then perform pg_temp.ok(true,label);return;end if;raise;end;raise exception'STEADY-V2 FAIL: allowed %',label;end$$;
create function pg_temp.recipe(i integer,n integer default 2)returns jsonb language sql as $$
 select jsonb_set(jsonb_set(jsonb_set(m,'{operation_id}',to_jsonb(('f5700000-0000-4000-8000-'||lpad(i::text,12,'0'))::text)),'{sources}',(select jsonb_agg(value order by ord)from jsonb_array_elements(m->'sources')with ordinality e(value,ord)where ord<=n)),'{presentation,shot_labels}',(select jsonb_agg(null::text)from generate_series(1,n)))from bm
$$;
select pg_temp.ok((select value->>'enabled'='false'from app_config where key='property_video_quality'),'new profile default OFF');
select pg_temp.ok((select count(*)=1 and min(unit_cents)=42 from ai_routes where task='video.property_reel_clip'and provider='fal'and model='fal-ai/kling-video/v3/4k/image-to-video'),'isolated ordinary task has exact42c catalog');
select pg_temp.ok(not exists(select 1 from ai_routes where task='video.reel_clip'and model='fal-ai/kling-video/v3/4k/image-to-video'),'legacy direct rows unchanged');
select pg_temp.ok(not has_function_privilege('authenticated','public.property_video_job_admit(uuid,jsonb,numeric,text)','execute')and not has_function_privilege('anon','public.property_video_quality_profile()','execute'),'profile admission and config service-only');
update app_config set value=jsonb_set(value,'{enabled}','true')where key='property_video_jobs';
set local role service_role;
select pg_temp.ok(property_video_quality_profile()='legacy','OFF resolves legacy');
create temporary table oldjob as select(property_video_job_enqueue((select actor from bf),pg_temp.recipe(1))).*;grant select on oldjob to service_role;
select pg_temp.ok((select quality_profile='legacy'and deadline=created_at+interval'4h'from oldjob),'legacy manifest retains4h');
select pg_temp.refuse($q$select property_video_job_admit((select actor from bf),pg_temp.recipe(2),500,'fal-kling3-4k-steady-v2')$q$,'RP409:','future profile while OFF is stale');
select pg_temp.ok(not exists(select 1 from property_video_jobs where operation_id=(pg_temp.recipe(2)->>'operation_id')::uuid),'stale quote creates no job');
-- Closed actual Apple receipt fixture, ordinaryStarter with no internal grant.
reset role;update app_config set value='{"mode":"ceiling","free_published_listings":1}'where key='serving_mode';
set local role service_role;
select apply_apple_entitlement_v2((select org from bf),(select actor from bf),'quality-original','quality-transaction','com.rendprop.app.starter.monthly','starter','Production','active',now()+interval'29 days',true,'DID_RENEW',now()-interval'1 day',now()-interval'30 seconds',now()-interval'30 seconds',now()-interval'30 seconds');
select pg_temp.ok(not org_has_internal_testing_grant((select org from bf))and(org_entitlement((select org from bf))).reels_per_month=30,'real ordinary capacity authority, no sponsored fixture');
reset role;
create temporary table original_paid_policy as select value from app_config where key='paid_quality_processing';
update app_config set value=jsonb_set(value,'{enabled}','true')where key='paid_quality_processing';
update app_config set value='{"enabled":false}'where key='photo_preservation_quality';
update app_config set value='{"enabled":true,"profile":"fal-kling3-4k-v1"}'where key='property_video_quality';set local role service_role;
select pg_temp.ok(property_video_quality_profile()='fal-kling3-4k-v1','v1 selector remains supported');
select pg_temp.ok(paid_quality_processing_budget((select org from bf))=6500,'v1 ordinary paid eligibility preserved');
create temporary table saved_v1 as select property_video_job_admit((select actor from bf),pg_temp.recipe(50),500,'fal-kling3-4k-v1')a;
select pg_temp.ok((select a#>>'{job,quality_profile}'='fal-kling3-4k-v1'and(a#>>'{job,deadline}')::timestamptz=(a#>>'{job,created_at}')::timestamptz+interval'24h'from saved_v1),'v1 creation preserves profile and24h');
reset role;update app_config set value='{"enabled":true,"profile":"fal-kling3-4k-steady-v2"}'where key='property_video_quality';set local role service_role;
select pg_temp.ok(property_video_quality_profile()='fal-kling3-4k-steady-v2','explicit ON selects v2');
select pg_temp.ok(paid_quality_processing_budget((select org from bf))=6500,'v2 recognizes same ordinary paid policy without changing budget');
select pg_temp.ok((select property_video_job_admit((select actor from bf),pg_temp.recipe(50),null,'unknown')->'job'=a->'job'from saved_v1),'existing v1 replay is byte-exact after v2 cutover');
select pg_temp.refuse($q$select property_video_job_admit((select actor from bf),pg_temp.recipe(3),500,'legacy')$q$,'RP409:','stale legacy quote after cutover refuses');
select pg_temp.refuse($q$select property_video_job_admit((select actor from bf),pg_temp.recipe(4),500)$q$,'RP409:','old3argument runtime cannot admit unpriced new profile');
select pg_temp.refuse($q$select property_video_job_enqueue((select actor from bf),pg_temp.recipe(5))$q$,'RP409:','direct enqueue cannot bypass quoted profile');
select pg_temp.refuse($q$select property_video_job_admit((select actor from bf),pg_temp.recipe(6),419,'fal-kling3-4k-steady-v2')$q$,'RP400:','underpriced profile refuses before capacity');
select pg_temp.refuse($q$select property_video_job_admit((select actor from bf),pg_temp.recipe(7),500,'unknown')$q$,'RP409:','unknown profile refuses');
select pg_temp.ok((property_video_job_admit((select actor from bf),pg_temp.recipe(1),null,'unknown')->>'accepted')::boolean,'existing legacy replay precedes default/quote check');
select pg_temp.ok((property_video_job_enqueue((select actor from bf),pg_temp.recipe(1))).manifest_sha256=(select manifest_sha256 from oldjob),'old saved manifest hash unchanged after default flip');
create temporary table accepted as select property_video_job_admit((select actor from bf),pg_temp.recipe(8),500,'fal-kling3-4k-steady-v2')a;grant select on accepted to service_role;
select pg_temp.ok((select a->>'accepted'='true'and a#>>'{job,quality_profile}'='fal-kling3-4k-steady-v2'from accepted),'new accepted job freezes v1');
select pg_temp.ok((select (a#>>'{job,deadline}')::timestamptz=(a#>>'{job,created_at}')::timestamptz+interval'24h'from accepted),'new profile bounded24h deadline');
select pg_temp.ok((select a#>'{job,manifest}'=pg_temp.recipe(8)and not(a#>'{job,manifest}'?'quality_profile')from accepted),'server metadata never rewrites user manifest');
select pg_temp.refuse($q$update property_video_jobs set quality_profile='legacy'where id=(select(a#>>'{job,id}')::uuid from accepted)$q$,'RP409:','saved profile cannot be changed');
select pg_temp.refuse($q$select property_video_job_enqueue((select actor from bf),pg_temp.recipe(9))$q$,'RP409:','admission context restored cannot leak to later direct enqueue');
select pg_temp.ok((select property_video_job_admit((select actor from bf),pg_temp.recipe(10,100),21000,'fal-kling3-4k-steady-v2')->>'operation_closed'='true'),'100 source funding refuses on ordinary plan without bypass');
select pg_temp.ok((select count(*)=0 from cost_ledger where feature in('reel','qc')),'profile admission never generates or spends');
-- Actual narration admission uses the frozen profile, not caller FPS.
create temporary table aud as select(property_video_audio_prepare((select actor from bf),jsonb_build_object('operation_id','f5900000-0000-4000-8000-000000000001','listing_id',(select listing from bf),'expected_org_id',(select org from bf),'bytes',100,'sha256',repeat('d',64),'mime','audio/mp4'))).*;
select property_video_audio_complete((select actor from bf),(select id from aud),'"audio-etag"');
create function pg_temp.voice(i integer,profile text,transition text,seconds numeric)returns jsonb language plpgsql as $$declare m jsonb;j public.property_video_jobs;c jsonb;begin
 m:=jsonb_set(jsonb_set(pg_temp.recipe(i),'{narration_asset_id}',to_jsonb((select id::text from aud))),'{presentation,transition}',to_jsonb(transition));
 j:=jsonb_populate_record(null::public.property_video_jobs,public.property_video_job_admit((select actor from bf),m,500,profile)->'job');
 c:=public.property_video_job_claim(j.id,'slot-0');
 if c->>'action'<>'inspect_audio'then raise exception'STEADY-V2 FAIL: narration lease must precede clips';end if;
 perform public.property_video_job_audio_source(j.id,(c#>>'{job,audio_lease}')::uuid,jsonb_build_object('bucket','renders','storage_key',(select storage_key from aud),'bytes',100,'sha256',repeat('d',64),'etag','"audio-etag"','content_type','audio/mp4'));
 j:=public.property_video_job_audio_preflight(j.id,(c#>>'{job,audio_lease}')::uuid,j.manifest_sha256,repeat('d',64),seconds,1);
 return j.audio_preflight;end$$;
select pg_temp.ok(pg_temp.voice(60,'fal-kling3-4k-steady-v2','dissolve',9.84)=jsonb_build_object('within_limit',true,'sha256',repeat('d',64),'duration_s',9.84,'audio_streams',1,'max_duration_s',9.75),'v2 dissolve exact6frames24fps admits within unchanged100ms padding');
select pg_temp.ok(pg_temp.voice(61,'fal-kling3-4k-steady-v2','dissolve',9.851)->'within_limit'='false'::jsonb,'v2 narration above exact limit still refuses before clip');
select pg_temp.ok(abs((pg_temp.voice(62,'fal-kling3-4k-steady-v2','whip',9)->>'max_duration_s')::numeric-(10-4/24.0))<.0000001,'v2 whip exact4frames24fps');
select pg_temp.ok((pg_temp.voice(63,'fal-kling3-4k-steady-v2','cut',10.05)->>'max_duration_s')::numeric=10,'v2 cut duration remains sourcecount times5');
reset role;update app_config set value='{"enabled":true,"profile":"fal-kling3-4k-v1"}'where key='property_video_quality';set local role service_role;
select pg_temp.ok(pg_temp.voice(64,'fal-kling3-4k-v1','dissolve',9.84)->'within_limit'='false'::jsonb,'v1 still uses8frames30fps and refuses same overlong take');
select pg_temp.ok(abs((pg_temp.voice(65,'fal-kling3-4k-v1','whip',9)->>'max_duration_s')::numeric-(10-5/30.0))<.0000001,'v1 whip remains5frames30fps');
-- Generate no real video: retained transport fixtures exercise the actual
-- paid-source/QC-refusal/approved-original fallback/output registration chain.
create function pg_temp.ready(i integer,profile text)returns jsonb language plpgsql as $$declare j public.property_video_jobs;c jsonb;o jsonb;n integer;begin
 j:=jsonb_populate_record(null::public.property_video_jobs,public.property_video_job_admit((select actor from bf),pg_temp.recipe(i),500,profile)->'job');
 for n in 1..2 loop c:=public.property_video_job_claim(j.id,'slot-0');if c->>'action'<>'dispatch'then raise exception'STEADY-V2 FAIL: output fixture requires actual source dispatch grant';end if;perform pg_temp.reject_claim(c);end loop;
 c:=public.property_video_job_claim(j.id,'slot-0');if c->>'action'<>'compose'then raise exception'STEADY-V2 FAIL: both paid rejected sources must retain exact approved originals';end if;
 o:=public.property_video_job_outputs_reserve(j.id,(c#>>'{job,compose_lease}')::uuid,2000,repeat('b',64),100,repeat('c',64));
 j:=public.property_video_job_finish(j.id,(c#>>'{job,compose_lease}')::uuid,jsonb_build_object('manifest_sha256',j.manifest_sha256,'asset_id',o->>'asset_id','poster_asset_id',o->>'poster_asset_id','bytes',2000,'sha256',repeat('b',64),'poster_bytes',100,'poster_sha256',repeat('c',64),'etag','"master-etag"','poster_etag','"poster-etag"','width',1920,'height',1080,'duration_s',10));
 return jsonb_build_object('id',j.id,'key',o->>'key','asset',o->>'asset_id');end$$;
create temporary table ready_v1 as select pg_temp.ready(70,'fal-kling3-4k-v1')o;
select pg_temp.ok(not(background_video_delivery((select actor from bf),(select org from bf),(select listing from bf),(select o->>'key'from ready_v1),0)?'quality_profile'),'v1 registered master response remains exact old schema');
reset role;update app_config set value='{"enabled":true,"profile":"fal-kling3-4k-steady-v2"}'where key='property_video_quality';set local role service_role;
create temporary table ready_v2 as select pg_temp.ready(71,'fal-kling3-4k-steady-v2')o;
select pg_temp.ok(background_video_delivery((select actor from bf),(select org from bf),(select listing from bf),(select o->>'key'from ready_v2),0)->>'quality_profile'='fal-kling3-4k-steady-v2','only authoritative v2 registered master projects frozen profile');
select pg_temp.ok(background_video_delivery(null,(select org from bf),(select listing from bf),(select o->>'key'from ready_v2),0)->>'quality_profile'='fal-kling3-4k-steady-v2','public existing authority projects same frozen v2 profile');
select pg_temp.ok(background_video_delivery(null,(select org from bf),(select listing from bf),(select o->>'key'||'-forged'from ready_v2),0)is null,'unregistered key does not gain a profile');
select pg_temp.refuse($q$select background_video_delivery((select other from bf),(select org from bf),(select listing from bf),(select o->>'key'from ready_v2),0)$q$,'RP404:','v2 master keeps current private reader scope');
select pg_temp.refuse($q$select background_video_delivery((select actor from bf),(select org from bf),(select listing from bf),(select o->>'key'from ready_v2),2001)$q$,'RP400:','v2 master cannot authorize bytes beyond exact object');
select pg_temp.ok((select jsonb_array_length(result->'sources')=2 and result->>'original_photo_count'='2'from property_video_jobs where id=(select(o->>'id')::uuid from ready_v2)),'v2 source order and honest fallback labels preserved');

-- Prepared derivatives are a CPU-only source step. The VIDEO creation using
-- that exact prepared asset still enters the same frozen profile admission.
reset role;update listings set gallery_asset_ids=array[md5('bg-photo:1')::uuid]where id=(select listing from bf);set local role service_role;
create temporary table prep as select property_video_preparation_enqueue((select actor from bf),jsonb_build_object('operation_id','f5500000-0000-4000-8000-000000000001','listing_id',(select listing from bf),'expected_org_id',(select org from bf),'photo_id','selected:1','photo_asset_id',md5('bg-photo:1')::uuid,'photo_version_id','asset:'||md5('bg-photo:1')::uuid,'photo_provenance_id',null))p;
create temporary table pc as select property_video_preparation_claim((select(p).id from prep))c;
select property_video_preparation_outputs((select(p).id from prep),(select(c#>>'{preparation,lease_token}')::uuid from pc),repeat('a',64),(select(c#>>'{preparation,asset_id}')::uuid from pc),100,repeat('e',64),2048,1536);
select property_video_preparation_finish((select(p).id from prep),(select(c#>>'{preparation,lease_token}')::uuid from pc),'"prepared-etag"');
create temporary table prepared_recipe as select jsonb_set(pg_temp.recipe(11,1),'{sources}',jsonb_build_array(jsonb_build_object('photo_id','selected:1','photo_asset_id',(select(c#>>'{preparation,asset_id}')::uuid from pc),'photo_version_id','asset:'||md5('bg-photo:1')::uuid,'photo_provenance_id',null,'motion','push_in')))m;
create temporary table prepared_job as select property_video_job_admit((select actor from bf),(select m from prepared_recipe),250,'fal-kling3-4k-steady-v2')a;
select pg_temp.ok((select a->>'accepted'='true'and a#>>'{job,quality_profile}'='fal-kling3-4k-steady-v2'and(a#>>'{job,deadline}')::timestamptz=(a#>>'{job,created_at}')::timestamptz+interval'24h'from prepared_job),'prepared-source job creation also freezes quality profile');
select pg_temp.ok((select sha256=repeat('a',64)and bytes=100 from capture_assets where id=md5('bg-photo:1')::uuid),'prepared profile never changes original master');
reset role;update app_config set value=jsonb_set(value,'{enabled}','false')where key='property_video_quality';set local role service_role;
select pg_temp.ok((select property_video_job_admit((select actor from bf),pg_temp.recipe(8),null,'unknown')#>>'{job,quality_profile}'='fal-kling3-4k-steady-v2'),'new accepted replay keeps v1 after rollback');
select pg_temp.ok((select (property_video_job_scope((a#>>'{job,id}')::uuid,(select actor from bf),true)).quality_profile='fal-kling3-4k-steady-v2'from accepted),'worker/recovery scope keeps saved profile');
select pg_temp.ok((select quality_profile='legacy'and deadline=created_at+interval'4h'from property_video_jobs where id=(select id from oldjob)),'historical deadline stays4h');
select pg_temp.refuse($q$select property_video_job_admit((select other from bf),pg_temp.recipe(8),500,'fal-kling3-4k-steady-v2')$q$,'RP403:','foreign actor cannot replay another property');
reset role;insert into deletion_requests(user_id,status)select actor,'pending'from bf;set local role service_role;
select pg_temp.refuse($q$select background_video_delivery((select actor from bf),(select org from bf),(select listing from bf),(select o->>'key'from ready_v2),0)$q$,'RP404:','pending account deletion still revokes v2 registered master');
reset role;select jsonb_build_object('passed',true,'assertions',(select n from checks));
rollback;
