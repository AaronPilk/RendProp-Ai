-- New immutable reference profile only. Never rewrites old jobs or cpu_output.
begin;
set local lock_timeout='5s';set local statement_timeout='30s';
do $authority$declare sig text;expected text;begin
 for sig,expected in select*from(values
 ('public.property_video_aerial_policy()','737532778a9e96f730550ccc1e8bace6'),
 ('public.property_video_aerial_manifest(uuid,jsonb)','4cbb74d48376f5419be7255d9d3aec8e'),
 ('public.property_video_aerial_quote_check(jsonb,jsonb,jsonb)','b06b0987b02b982c4c97e263d98ee7a3'),
 ('public.property_video_aerial_admit(uuid,jsonb,jsonb,jsonb)','569814a26400b305fb5088768bc48578'),
 ('public.property_video_aerial_receipt(uuid,uuid,jsonb)','3884a297c2183717a5d0013bb6542ecf'),
 ('public.property_video_aerial_quality(uuid,uuid,jsonb)','b3cd8c3e3f079f02e74e5318085b037f'),
 ('public.property_video_aerial_opening_scope(jsonb,uuid,uuid,uuid,uuid,text)','7872a5af27161102e2eb42c435169164')
 )v(signature,source_md5)loop
 if not exists(select 1 from pg_proc where oid=to_regprocedure(sig)and md5(prosrc)=expected and prosecdef and pg_get_userbyid(proowner)='postgres'and proconfig=ARRAY['search_path=""']::text[]and proacl::text='{postgres=X/postgres,service_role=X/postgres}')then raise exception'RP409: Aerial reference predecessor changed: %',sig;end if;
 end loop;end$authority$;
CREATE OR REPLACE FUNCTION public.property_video_aerial_policy()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare c jsonb;r public.ai_routes;a public.ai_routes;q public.ai_routes;processors jsonb;begin
 select value into c from public.app_config where key='property_video_aerial_opening';
 if jsonb_typeof(c)is distinct from'object' or c->'enabled'is distinct from'true'::jsonb
 or not coalesce(c->>'profile'in('kie-kling3-4k-aerial-opening-v1','kie-kling3-pro-aerial-opening-v1','kie-kling3-omni-reference-aerial-opening-v1'),false)
 or c->>'vendor_content_license'is distinct from'kie-terms-2025-08-01-section-3-owner-accepted'
 or coalesce(c->>'rate_evidence_sha256','')!~'^[a-f0-9]{64}$'
 or jsonb_typeof(c->'maximum_operation_cents')is distinct from'number'
 or not((c->>'maximum_operation_cents')::numeric between (case c->>'profile'when'kie-kling3-omni-reference-aerial-opening-v1'then 45 when'kie-kling3-pro-aerial-opening-v1'then 45 else 167.5 end) and 10000000)
 or coalesce(c->>'assessment_route_id','')!~'^[a-f0-9-]{36}$'or coalesce(c->>'quality_route_id','')!~'^[a-f0-9-]{36}$'
 or jsonb_typeof(c->'processor_consent')is distinct from'object'
 or(select count(*)from jsonb_object_keys(c->'processor_consent'))<>3
 or c#>>'{processor_consent,token}'is distinct from'aerial-opening-v1'
 or coalesce(c#>>'{processor_consent,disclosure_revision}','')!~'^[!-~]{1,200}$'
 or jsonb_typeof(c#>'{processor_consent,processors}')is distinct from'array'
 or jsonb_typeof(c->'producer_identity')is distinct from'object'
 or coalesce(c#>>'{producer_identity,image_uri}','')!~'^registry\.cloudflare\.com/[a-f0-9]{32}/[a-z0-9][a-z0-9._/-]{0,180}@sha256:[a-f0-9]{64}$'
 or coalesce(c#>>'{producer_identity,controller_sha256}','')!~'^[a-f0-9]{64}$'
 or coalesce(c#>>'{producer_identity,renderer_source_sha256}','')!~'^[a-f0-9]{64}$'
 or(select count(*)from jsonb_object_keys(c->'producer_identity'))<>3
 then raise exception'RP503: Aerial openings are waiting for their verified route and renderer';end if;
 select*into r from public.ai_routes where id=(c->>'route_id')::uuid;
 if r.id is null or not r.enabled or r.retire_after<=now() or r.task is distinct from(case c->>'profile'when'kie-kling3-omni-reference-aerial-opening-v1'then'video.aerial_opening_kie_omni_reference'when'kie-kling3-pro-aerial-opening-v1'theN'video.aerial_opening_kie_pro'else'video.aerial_opening_kie'end)
 or r.provider is distinct from'kie' or r.model is distinct from(case when c->>'profile'='kie-kling3-omni-reference-aerial-opening-v1'then'kling-3.0-omni/reference-to-video'else'kling-3.0/video'end) or r.unit is distinct from'second'
 or r.unit_cents is distinct from(case c->>'profile'when'kie-kling3-omni-reference-aerial-opening-v1'then 9 when'kie-kling3-pro-aerial-opening-v1'then 9 else 33.5 end) or r.privacy_tier is distinct from'trains_by_default'
 or not(r.capabilities @> case c->>'profile'when'kie-kling3-omni-reference-aerial-opening-v1'then array['reference_images','1080p','5s']when'kie-kling3-pro-aerial-opening-v1'then array['i2v','1080p','5s','preserve_photo']else array['i2v','1080p','5s','native4k','preserve_photo']end)
 or r.params is distinct from (case when c->>'profile'='kie-kling3-omni-reference-aerial-opening-v1'then jsonb_build_object('audio',false,'customize_multi_shots',false,'prefer_multi_shots',false,'resolution','1080p','aerial_opening_profile',c->>'profile')else jsonb_build_object('sound',false,'kie_mode',case c->>'profile'when'kie-kling3-pro-aerial-opening-v1'then'pro'else'4K'end,'aerial_opening_profile',c->>'profile')end)
 then raise exception'RP503: No exact grounded KIE aerial opening route is qualified';end if;
 select*into a from public.ai_routes where id=(c->>'assessment_route_id')::uuid;
 select*into q from public.ai_routes where id=(c->>'quality_route_id')::uuid;
 if a.id is null or q.id is null or not a.enabled or not q.enabled or a.retire_after<=now()or q.retire_after<=now()
 or a.provider not in('openai','anthropic')or q.provider not in('openai','anthropic')
 then raise exception'RP503: Source and finished-opening checks need their current qualified vision routes';end if;
 select jsonb_agg(v order by v)into processors from(select distinct v from unnest(array['kie',a.provider,q.provider])v)t;
 if(select jsonb_agg(value order by value)from jsonb_array_elements(c#>'{processor_consent,processors}'))is distinct from processors
 then raise exception'RP503: The aerial disclosure must name exactly its actual processors';end if;
 return c||jsonb_build_object('route',to_jsonb(r),'assessment_route',to_jsonb(a),'quality_route',to_jsonb(q));
end$function$;

CREATE OR REPLACE FUNCTION public.property_video_aerial_manifest(p_actor uuid, p_manifest jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$declare ctx jsonb;c jsonb;w bigint;h bigint;x bigint;y bigint;sw bigint;sh bigint;begin
 if current_setting('role',true)is distinct from'service_role'then raise insufficient_privilege;end if;
 if jsonb_typeof(p_manifest)is distinct from'object'or(select count(*)from jsonb_object_keys(p_manifest))<>10
 or exists(select 1 from jsonb_object_keys(p_manifest)k where k not in('schema','profile','operation_id','listing_id','expected_org_id','source','role','aspect','seconds','reviewed_crop'))
 or p_manifest->'schema'is distinct from'1'::jsonb or not coalesce(p_manifest->>'profile'in('kie-kling3-4k-aerial-opening-v1','kie-kling3-pro-aerial-opening-v1','kie-kling3-omni-reference-aerial-opening-v1'),false)
 or p_manifest->>'role'is distinct from'front_of_home' or p_manifest->>'aspect'not in('16:9','9:16')or p_manifest->'seconds'is distinct from'5'::jsonb
 or jsonb_typeof(p_manifest->'reviewed_crop')is distinct from'object' or(select count(*)from jsonb_object_keys(p_manifest->'reviewed_crop'))<>6
 or exists(select 1 from jsonb_object_keys(p_manifest->'reviewed_crop')k where k not in('x','y','width','height','source_width','source_height'))
 then raise exception'RP400: Choose one original front-of-home photo and review its opening crop';end if;
 perform(p_manifest->>'operation_id')::uuid;
 c:=p_manifest->'reviewed_crop';
 if exists(select 1 from jsonb_each(c)e where jsonb_typeof(e.value)<>'number'or e.value::text!~'^[0-9]{1,6}$')then raise exception'RP400: Use the exact reviewed raster crop';end if;
 x:=(c->>'x')::bigint;y:=(c->>'y')::bigint;w:=(c->>'width')::bigint;h:=(c->>'height')::bigint;sw:=(c->>'source_width')::bigint;sh:=(c->>'source_height')::bigint;
 if w<=0 or h<=0 or sw not between 1 and 20000 or sh not between 1 and 20000 or sw*sh>100000000 or x+w>sw or y+h>sh
 or(case when p_manifest->>'aspect'='16:9'then w*9<>h*16 or w<1920 or h<1080 else w*16<>h*9 or w<1080 or h<1920 end)
 then raise exception'RP400: The reviewed crop needs native1080p pixels in the selected aspect';end if;
 ctx:=public.property_video_aerial_original(p_actor,(p_manifest->>'expected_org_id')::uuid,(p_manifest->>'listing_id')::uuid,p_manifest->'source');
 return ctx;
end$function$;

CREATE OR REPLACE FUNCTION public.property_video_aerial_quote_check(p_manifest jsonb, p_quote jsonb, p_policy jsonb)
 RETURNS boolean
 LANGUAGE plpgsql
 IMMUTABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$declare g numeric;a numeric;q numeric;p numeric;total numeric;begin
 if jsonb_typeof(p_quote->'generation_cents')is distinct from'number'or jsonb_typeof(p_quote->'processing_cents')is distinct from'number'or jsonb_typeof(p_quote->'maximum_total_cents')is distinct from'number'or jsonb_typeof(p_quote#>'{assessment,cents}')is distinct from'number'or jsonb_typeof(p_quote#>'{quality,cents}')is distinct from'number'or jsonb_typeof(p_quote)is distinct from'object'or (select count(*)from jsonb_object_keys(p_quote))<>14
 or exists(select 1 from jsonb_object_keys(p_quote)k where k not in('schema','profile','manifest_sha256','route_id','generation_cents','assessment','quality','processing_cents','maximum_total_cents','tariff_version','rate_evidence_sha256','processor_consent','expires_at','privacy_stop_at'))
 or not(p_quote?'privacy_stop_at')or(p_quote->'privacy_stop_at'<>'null'::jsonb and jsonb_typeof(p_quote->'privacy_stop_at')is distinct from'string')
 or p_quote->'schema'is distinct from'1'::jsonb or p_quote->>'profile'is distinct from p_manifest->>'profile'or p_manifest->>'profile'is distinct from p_policy->>'profile'
 or p_quote->>'manifest_sha256'is distinct from encode(sha256(convert_to(p_manifest::text,'UTF8')),'hex')
 or p_quote->>'route_id'is distinct from p_policy->>'route_id'
 or p_quote->>'rate_evidence_sha256'is distinct from p_policy->>'rate_evidence_sha256'
 or p_quote->>'tariff_version'is distinct from'published-standard-20261006'
 or p_quote->'processor_consent'is distinct from p_policy->'processor_consent'
 then raise exception'RP409: Restore the exact current aerial quote and processor disclosure';end if;
 g:=(p_quote->>'generation_cents')::numeric;a:=(p_quote#>>'{assessment,cents}')::numeric;q:=(p_quote#>>'{quality,cents}')::numeric;p:=(p_quote->>'processing_cents')::numeric;total:=(p_quote->>'maximum_total_cents')::numeric;
 if not coalesce(p_manifest->>'profile'in('kie-kling3-4k-aerial-opening-v1','kie-kling3-pro-aerial-opening-v1','kie-kling3-omni-reference-aerial-opening-v1'),false)or g is distinct from(case p_manifest->>'profile'when'kie-kling3-omni-reference-aerial-opening-v1'then 45 when'kie-kling3-pro-aerial-opening-v1'then 45 else 167.5 end) or a is null or q is null or p is null or total is null
 or a<=0 or q<=0 or a>100 or q>100 or p<2*1260*.006112 or p>100
 or total is distinct from g+a+q+p or total>(p_policy->>'maximum_operation_cents')::numeric
 or total::text in('NaN','Infinity','-Infinity')
 or p_quote#>>'{assessment,route_id}'is distinct from p_policy->>'assessment_route_id'
 or p_quote#>>'{quality,route_id}'is distinct from p_policy->>'quality_route_id'
 or p_quote#>>'{assessment,provider}'is distinct from p_policy#>>'{assessment_route,provider}'or p_quote#>>'{assessment,model}'is distinct from p_policy#>>'{assessment_route,model}'
 or p_quote#>>'{quality,provider}'is distinct from p_policy#>>'{quality_route,provider}'or p_quote#>>'{quality,model}'is distinct from p_policy#>>'{quality_route,model}'
 then raise exception'RP503: Every aerial assessment,processing,generation and quality stage needs a bounded quote';end if;
 return true;
end$function$;

CREATE OR REPLACE FUNCTION public.property_video_aerial_admit(p_actor uuid, p_manifest jsonb, p_quote jsonb, p_consent jsonb)
 RETURNS property_video_aerial_openings
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare j public.property_video_aerial_openings;ctx jsonb;c jsonb;org uuid;billing uuid;h text;ent public.plan_entitlements;mr jsonb;br jsonb;begin
 if current_setting('role',true)is distinct from'service_role'then raise insufficient_privilege;end if;
 perform pg_advisory_xact_lock(hashtextextended('aerial-privacy:'||p_actor,79));
 perform pg_advisory_xact_lock(hashtextextended('aerial-opening:'||p_actor||':'||(p_manifest->>'operation_id'),79));
 h:=encode(sha256(convert_to(p_manifest::text,'UTF8')),'hex');
 select*into j from public.property_video_aerial_openings where actor_id=p_actor and operation_id=(p_manifest->>'operation_id')::uuid;
 if j.id is not null then if j.manifest is distinct from p_manifest or j.consent is distinct from p_consent then raise exception'RP409: This aerial operation has different saved inputs or permission';end if;return public.property_video_aerial_scope(j.id,p_actor);end if;
 if exists(select 1 from public.property_video_aerial_stops where actor_id=p_actor and operation_id=(p_manifest->>'operation_id')::uuid)then raise exception'RP409: This aerial operation was stopped before admission. Keep its stop receipt and use a new operation for a new choice';end if;
 org:=public.property_video_actor_org(p_actor,(p_manifest->>'expected_org_id')::uuid,(p_manifest->>'listing_id')::uuid);billing:=public.library_actor_billing_org(p_actor,org);
 perform pg_advisory_xact_lock(hashtextextended('serving:'||billing,72452));perform pg_advisory_xact_lock(hashtextextended('serving:'||org,72452));perform pg_advisory_xact_lock(hashtextextended('org_month_spend:'||billing,42));
 perform 1 from auth.users where id=p_actor for share;perform 1 from public.orgs where id=billing and deleted_at is null for update;if not found then raise exception'RP404: Aerial billing library unavailable';end if;
 perform 1 from public.orgs where id=org and deleted_at is null for update;if not found then raise exception'RP404: Aerial library unavailable';end if;
 perform 1 from public.listings where id=(p_manifest->>'listing_id')::uuid and deleted_at is null for share;if not found then raise exception'RP404: Aerial property unavailable';end if;
 perform 1 from public.capture_assets where id=(p_manifest#>>'{source,photo_asset_id}')::uuid for share;
 ctx:=public.property_video_aerial_manifest(p_actor,p_manifest);c:=public.property_video_aerial_policy();perform public.property_video_aerial_quote_check(p_manifest,p_quote,c);
 if(p_quote->>'privacy_stop_at')::timestamptz is distinct from(select max(created_at)from public.property_video_stop_operations where actor_id=p_actor)then raise exception'RP409: Privacy permission changed after this aerial quote. Review a fresh operation before sending more media';end if;
 if(p_quote->>'expires_at')::timestamptz<=now()or(p_quote->>'expires_at')::timestamptz>now()+interval'15 minutes'
 or p_consent is distinct from p_quote->'processor_consent'then raise exception'RP409: Allow the listed processors for this exact current aerial quote';end if;
 ent:=public.org_entitlement(billing);
 if ent.aerials_per_month<=0 or public.org_month_spend_cents(billing)+(p_quote->>'maximum_total_cents')::numeric>ent.cogs_ceiling_cents then raise exception'RP402: This aerial opening exceeds the current plan or processing capacity';end if;
 if public.serving_mode()='ceiling'then perform public.library_serving_envelope_admit(org,billing,(p_quote->>'maximum_total_cents')::numeric,null);end if;
 mr:=public.bump_rate_receipt('aerialmo:'||billing,2592000,ent.aerials_per_month,1);br:=public.bump_rate_receipt('aivideo:'||billing,300,12,1);
 if mr->'accepted'is distinct from'true'::jsonb or br->'accepted'is distinct from'true'::jsonb then raise exception'RP402: The current aerial allowance is unavailable';end if;
 -- A distinct normal hold per possible stage, all before any asynchronous work.
 perform public.serving_cost_reserve(p_actor,org,'aerial-opening:'||(p_manifest->>'operation_id'),'aerial_input','cloudflare','container-standard-3',h,(p_quote->>'processing_cents')::numeric/2,'container-standard3-20261021');
 perform public.serving_cost_reserve(p_actor,org,'aerial-opening:'||(p_manifest->>'operation_id'),'aerial_qualification','cloudflare','container-standard-3',h,(p_quote->>'processing_cents')::numeric/2,'container-standard3-20261021');
 perform public.serving_cost_reserve(p_actor,org,'aerial-opening:'||(p_manifest->>'operation_id'),'aerial_assessment',p_quote#>>'{assessment,provider}',p_quote#>>'{assessment,model}',h,(p_quote#>>'{assessment,cents}')::numeric,p_quote->>'tariff_version');
 perform public.serving_cost_reserve(p_actor,org,'aerial-opening:'||(p_manifest->>'operation_id'),'aerial_quality',p_quote#>>'{quality,provider}',p_quote#>>'{quality,model}',h,(p_quote#>>'{quality,cents}')::numeric,p_quote->>'tariff_version');
 perform public.serving_cost_reserve(p_actor,org,'aerial-opening:'||(p_manifest->>'operation_id'),'aerial','kie',(case when p_manifest->>'profile'='kie-kling3-omni-reference-aerial-opening-v1'then'kling-3.0-omni/reference-to-video'else'kling-3.0/video'end),h,(p_quote->>'generation_cents')::numeric,p_quote->>'tariff_version');
 perform public.app_video_cost_reserve_v2(p_actor,org,'aerial-opening:'||(p_manifest->>'operation_id'),'aerial','kie',(case when p_manifest->>'profile'='kie-kling3-omni-reference-aerial-opening-v1'then'kling-3.0-omni/reference-to-video'else'kling-3.0/video'end),h,(p_quote->>'generation_cents')::numeric,5,(c#>>'{route,unit_cents}')::numeric,
 jsonb_build_object('task',c#>>'{route,task}','route_id',c->>'route_id','unit','second','grounded',true,'seconds',5,'aspect',p_manifest->>'aspect','price_estimated',true),(mr->>'window_start')::timestamptz,(br->>'window_start')::timestamptz,(p_manifest->>'listing_id')::uuid);
 insert into public.property_video_aerial_openings(operation_id,actor_id,org_id,billing_org_id,policy,library_org_id,listing_id,manifest,manifest_sha256,original_source,quote,consent)
 values((p_manifest->>'operation_id')::uuid,p_actor,org,billing,c,public.listing_owner_library((p_manifest->>'listing_id')::uuid),(p_manifest->>'listing_id')::uuid,p_manifest,h,ctx,p_quote,p_consent)returning*into j;return j;
end$function$;

CREATE OR REPLACE FUNCTION public.property_video_aerial_receipt(p_id uuid, p_lease uuid, p_receipt jsonb)
 RETURNS boolean
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$declare j public.property_video_aerial_openings;begin
 if current_setting('role',true)is distinct from'service_role'then raise insufficient_privilege;end if;
 select*into j from public.property_video_aerial_openings where id=p_id;
 if j.id is null then raise exception'RP404: Aerial receipt unavailable';end if;
 perform pg_advisory_xact_lock(hashtextextended('serving:'||j.billing_org_id,72452));perform pg_advisory_xact_lock(hashtextextended('serving:'||j.org_id,72452));
 select*into j from public.property_video_aerial_openings where id=p_id for update;
 if j.id is null or j.generation_lease is distinct from p_lease or j.generation_claimed_at is null
 or jsonb_typeof(p_receipt)is distinct from'object' or(select count(*)from jsonb_object_keys(p_receipt))<>5
 or exists(select 1 from jsonb_object_keys(p_receipt)k where k not in('provider','model','id','submitted_at','poll_url'))
 or p_receipt->>'provider'is distinct from'kie'or p_receipt->>'model'is distinct from(case when j.manifest->>'profile'='kie-kling3-omni-reference-aerial-opening-v1'then'kling-3.0-omni/reference-to-video'else'kling-3.0/video'end)
 or coalesce(p_receipt->>'id','')!~'^[A-Za-z0-9_-]{1,200}$'
 or p_receipt->>'poll_url'is distinct from'https://api.kie.ai/api/v1/jobs/recordInfo?taskId='||(p_receipt->>'id')
 then raise exception'RP409: Keep the exact original KIE aerial receipt';end if;
 perform(p_receipt->>'submitted_at')::timestamptz;
 if j.provider_receipt is not null then if j.provider_receipt is distinct from p_receipt then raise exception'RP409: Aerial acceptance is immutable';end if;return true;end if;
 update public.property_video_aerial_openings set provider_receipt=p_receipt,state=case when cancel_requested_at is null then'processing'else'cancelled'end,updated_at=now()where id=p_id;
 perform public.app_video_cost_settle(j.actor_id,j.org_id,'aerial-opening:'||j.operation_id,p_receipt->>'id');
 perform public.serving_cost_finish(j.actor_id,j.org_id,'aerial-opening:'||j.operation_id,'aerial','succeeded',null);return true;
end$function$;

CREATE OR REPLACE FUNCTION public.property_video_aerial_quality(p_id uuid, p_lease uuid, p_quality jsonb)
 RETURNS boolean
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$declare j public.property_video_aerial_openings;c public.cost_ledger;pass boolean;begin
 if current_setting('role',true)is distinct from'service_role'then raise insufficient_privilege;end if;
 select*into j from public.property_video_aerial_openings where id=p_id for update;j:=public.property_video_aerial_scope(p_id);
 if p_lease is distinct from j.quality_lease or j.qualified_output->>'etag'is null
 or p_quality->>'source_sha256'is distinct from j.manifest#>>'{source,sha256}'or p_quality->>'output_sha256'is distinct from j.qualified_output->>'sha256'
 or p_quality->'frame_indices'is distinct from j.qualified_output->'frame_indices' or p_quality->'frame_sha256s'is distinct from j.qualified_output->'frame_sha256s'
 or p_quality->>'action'not in('accept','hold','retry','refuse')or p_quality->>'verdict'not in('pass','hold','fail')or jsonb_typeof(p_quality->'publishable')is distinct from'boolean'
 then raise exception'RP409: Bind the quality check to the exact retained opening and measured three frames';end if;
 select*into c from public.cost_ledger where id=(p_quality->>'ledger_id')::uuid;
 if c.id is null or c.org_id<>j.org_id or c.billing_org_id<>j.billing_org_id or c.meta->>'request_key'is distinct from'aerial-opening:'||j.operation_id
 or c.meta->>'stage'is distinct from'aerial_quality' or c.provider is distinct from j.quote#>>'{quality,provider}'or c.model is distinct from j.quote#>>'{quality,model}'or c.total_cents<=0 or c.total_cents>(j.quote#>>'{quality,cents}')::numeric then raise exception'RP409: The exact finished-opening quality receipt is unavailable';end if;
 if j.quality is not null then if j.quality is distinct from p_quality then raise exception'RP409: Opening quality is immutable';end if;return true;end if;
 pass:=p_quality->>'action'='accept'and p_quality->>'verdict'='pass'and p_quality->'publishable'='true'::jsonb;
 if pass then insert into public.media_provenance(id,org_id,listing_id,kind,label,model_id,original_key,altered_key,disclosure,qc)
  values((j.qualified_output->>'provenance_id')::uuid,j.org_id,j.listing_id,'aerial','AI aerial-style opening',(case when j.manifest->>'profile'='kie-kling3-omni-reference-aerial-opening-v1'then'kling-3.0-omni/reference-to-video'else'kling-3.0/video'end),j.original_source->>'storage_key',j.qualified_output->>'storage_key','AI-generated aerial-style opening based on the chosen front exterior photo. It is not captured drone footage or a3D representation.',p_quality);
 end if;
 update public.property_video_aerial_openings set quality=p_quality,state=case when cancel_requested_at is not null then'cancelled'when pass then'ready_for_acceptance'else'failed'end,message=case when pass then'Review the generated opening before using it.'else'The generated opening did not pass its property quality check. No replacement was submitted.'end,updated_at=now()where id=p_id;return true;
end$function$;

CREATE OR REPLACE FUNCTION public.property_video_aerial_opening_scope(p_ref jsonb, p_actor uuid, p_org uuid, p_selected_library uuid, p_listing uuid, p_aspect text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$declare j public.property_video_aerial_openings;o jsonb;ref jsonb;a public.capture_assets;g public.media_provenance;r public.app_video_cost_reservations;c public.cost_ledger;begin
 if current_setting('role',true)is distinct from'service_role'and(p_actor is null or auth.uid()is distinct from p_actor)then raise insufficient_privilege;end if;
 if jsonb_typeof(p_ref)is distinct from'object'or(select count(*)from jsonb_object_keys(p_ref))<>7 or exists(select 1 from jsonb_object_keys(p_ref)k where k not in('aerial_job_id','asset_id','provenance_id','sha256','bytes','visible_frames','source')) then raise exception'RP400: Choose one exact accepted aerial opening';end if;
 j:=public.property_video_aerial_scope((p_ref->>'aerial_job_id')::uuid,p_actor);o:=j.qualified_output;
 if row(j.org_id,j.library_org_id,j.listing_id)is distinct from row(p_org,p_selected_library,p_listing)or j.manifest->>'aspect'is distinct from p_aspect
 or j.state is distinct from'accepted'or j.accepted_at is null or j.eligibility->'exterior'is distinct from'true'::jsonb or j.eligibility->'uncertain'is distinct from'false'::jsonb
 or j.quality->>'action'is distinct from'accept'or j.quality->>'verdict'is distinct from'pass' or j.quality->'publishable'is distinct from'true'::jsonb
 or j.quality->>'output_sha256'is distinct from o->>'sha256' or j.quality->>'source_sha256'is distinct from j.manifest#>>'{source,sha256}'
 or j.provider_receipt is null or o is null or o->'producer_identity'is distinct from j.policy->'producer_identity'or o->'fps'is distinct from'24'::jsonb or coalesce((o->>'available_frames')::integer,0)not in(120,121)
 or coalesce(abs((o->>'duration_s')::numeric-(o->>'available_frames')::numeric/24),1)>.000001 or (o->>'bytes')::bigint not between 1 and 134217728
 or o->>'content_type'is distinct from'video/mp4' or o->>'codec'is distinct from'h264' or o->>'pix_fmt'is distinct from'yuv420p'
 or o->>'color_space'is distinct from'bt709'or o->>'sample_aspect_ratio'is distinct from'1:1'or o->'rotation'is distinct from'0'::jsonb or o->'audio_streams'is distinct from'0'::jsonb
 or o->'width'is distinct from to_jsonb(case when p_aspect='16:9'then 1920 else 1080 end)or o->'height'is distinct from to_jsonb(case when p_aspect='16:9'then 1080 else 1920 end)
 then raise exception'RP409: The aerial opening no longer has an exact accepted quality and timeline receipt';end if;
 ref:=jsonb_build_object('aerial_job_id',j.id,'asset_id',o->'asset_id','provenance_id',o->'provenance_id','sha256',o->'sha256','bytes',o->'bytes','visible_frames',o->'available_frames','source',j.manifest->'source');
 if p_ref is distinct from ref then raise exception'RP409: The accepted aerial reference changed';end if;
 select*into a from public.capture_assets where id=(o->>'asset_id')::uuid and listing_id=p_listing and kind='video'and bucket='renders'and uploaded and not upload_aborted;
 select*into g from public.media_provenance where id=(o->>'provenance_id')::uuid and org_id=p_org and listing_id=p_listing and kind='aerial';
 select*into r from public.app_video_cost_reservations where actor_id=p_actor and org_id=p_org and idempotency_key='aerial-opening:'||j.operation_id;
 select*into c from public.cost_ledger where id=r.cost_ledger_id;
 if a.id is null or row(a.storage_key,a.sha256,a.bytes)is distinct from row(o->>'storage_key',o->>'sha256',(o->>'bytes')::bigint)
 or g.id is null or(j.manifest->>'profile'='kie-kling3-omni-reference-aerial-opening-v1'and(g.model_id is distinct from'kling-3.0-omni/reference-to-video'or j.provider_receipt->>'model'is distinct from'kling-3.0-omni/reference-to-video')) or g.altered_key is distinct from a.storage_key or g.original_key is distinct from j.original_source->>'storage_key' or g.qc is distinct from j.quality
 or r.provider is distinct from'kie'or r.model is distinct from(case when j.manifest->>'profile'='kie-kling3-omni-reference-aerial-opening-v1'then'kling-3.0-omni/reference-to-video'else'kling-3.0/video'end)or r.feature is distinct from'aerial'or r.provider_request_id is distinct from j.provider_receipt->>'id'
 or r.settled_at is null or r.released_at is not null or c.id is null or not coalesce(j.manifest->>'profile'in('kie-kling3-4k-aerial-opening-v1','kie-kling3-pro-aerial-opening-v1','kie-kling3-omni-reference-aerial-opening-v1'),false)or j.quote->>'profile'is distinct from j.manifest->>'profile'or j.policy->>'profile'is distinct from j.manifest->>'profile'or(j.quote->>'generation_cents')::numeric is distinct from(case j.manifest->>'profile'when'kie-kling3-omni-reference-aerial-opening-v1'then 45 when'kie-kling3-pro-aerial-opening-v1'then 45 else 167.5 end)or c.total_cents is distinct from(j.quote->>'generation_cents')::numeric
 or c.org_id is distinct from j.org_id or c.billing_org_id is distinct from r.billing_org_id or c.provider is distinct from r.provider or c.model is distinct from r.model or c.feature is distinct from'aerial'
 or c.meta->>'request_key'is distinct from r.idempotency_key or c.meta->>'app_video_reservation_id'is distinct from r.id::text or c.meta->>'request_id'is distinct from r.provider_request_id
 then raise exception'RP409: The accepted aerial custody,provenance or paid receipt changed';end if;
 perform public.assert_studio_asset_quality(a.id);
 if not public.studio_presenter_key_access(p_listing,a.storage_key)then raise exception'RP404: The accepted aerial opening was withdrawn';end if;
 return jsonb_build_object('opening',ref||jsonb_build_object('schema',1,'kind','aerial_opening','position',0,'scope',jsonb_build_object('actor_id',j.actor_id,'org_id',j.org_id,'selected_library_org_id',j.library_org_id,'listing_id',j.listing_id),'aspect',p_aspect,'fps',24,'available_frames',o->'available_frames','width',o->'width','height',o->'height','duration_s',o->'duration_s','disclosure',g.disclosure,'accepted_at',j.accepted_at),
 'media',jsonb_build_object('bucket','renders','storage_key',a.storage_key,'content_type','video/mp4','sha256',a.sha256,'bytes',a.bytes,'etag',o->>'etag'));
end$function$;
commit;
