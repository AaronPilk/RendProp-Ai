-- Future-only exact prompt recipe registry. No active selector/route/license,
-- current job, existing grant identity/scope/cap/expiry, quality limit or paid attempt is changed.
-- Generated with local Supabase CLI; all replacements require retained exact predecessor bodies.
do $predecessors$begin
if(select md5(prosrc)from pg_proc where oid='public.property_video_quality_freeze()'::regprocedure)is distinct from'a3dd833254a27901b7c79cc70f18ad61'then raise exception'Review changed predecessor: property_video_quality_freeze()';end if;
if(select md5(prosrc)from pg_proc where oid='public.property_video_job_admit(uuid,jsonb,numeric,text)'::regprocedure)is distinct from'2077ba4e86e2002e94fdc3e43cd8954d'then raise exception'Review changed predecessor: property_video_job_admit(uuid,jsonb,numeric,text)';end if;
if(select md5(prosrc)from pg_proc where oid='public.property_video_kie_dispatch_authority(uuid,uuid,uuid)'::regprocedure)is distinct from'b2e484036e8d6803afa40e30fb41fbcf'then raise exception'Review changed predecessor: property_video_kie_dispatch_authority(uuid,uuid,uuid)';end if;
if(select md5(prosrc)from pg_proc where oid='public.paid_quality_processing_budget(uuid)'::regprocedure)is distinct from'618a85ee6ec7e94fa6f0d2c02dab8188'then raise exception'Review changed predecessor: paid_quality_processing_budget(uuid)';end if;
if(select md5(prosrc)from pg_proc where oid='public.property_video_source_read_resume_proof(uuid)'::regprocedure)is distinct from'7d0bf45cded84425fcc9a125110c2a2d'then raise exception'Review changed predecessor: property_video_source_read_resume_proof(uuid)';end if;
end$predecessors$;

-- Original canonical v1 identity remains byte-exact. Only two complete values register.
create or replace function public.property_video_prompt_identity(p_revision text)returns jsonb language sql immutable set search_path=''as $$
 select case p_revision when 'v1'then public.property_video_quality_identity('kie-kling3-4k-steady-v1')
 when 'v2'then jsonb_set(jsonb_set(public.property_video_quality_identity('kie-kling3-4k-steady-v1'),'{prompt_profile}','"steady-property-v2-gentle-push-in"'::jsonb),'{prompt_template_sha256,push_in}','"58a03de3b9b55ea8174bcd7e6d4fe7eaa44c4bb4d251e50f8e187d544bcb5c2c"'::jsonb)end
$$;
create or replace function public.property_video_prompt_identity_registered(p_identity jsonb)returns boolean language sql immutable set search_path=''as $$
 select coalesce(p_identity=public.property_video_prompt_identity('v1')or p_identity=public.property_video_prompt_identity('v2'),false)
$$;
-- Optional explicit future v2 coverage of the SAME immutable existing grant.
-- No rows are inserted here. No actor/org/listing/source/operation/cap/expiry is copied or expanded.
create table public.property_video_kie_prompt_coverage(
 grant_id uuid primary key references public.property_video_kie_test_grants(id)on delete cascade,
 base_identity jsonb not null,recipe_identity jsonb not null,created_at timestamptz not null default now());
alter table public.property_video_kie_prompt_coverage enable row level security;
revoke all on table public.property_video_kie_prompt_coverage from public,anon,authenticated,service_role;
create or replace function public.property_video_kie_prompt_coverage_guard()returns trigger language plpgsql security definer set search_path=''as $$declare g public.property_video_kie_test_grants;begin
 if TG_OP='DELETE'then
  -- Privacy erasure may cascade an actually deleted parent grant; active coverage cannot be removed or rewritten.
  if not exists(select 1 from public.property_video_kie_test_grants where id=old.grant_id)then return old;end if;
  raise exception'RP409: Saved prompt coverage is immutable';
 end if;
 if TG_OP<>'INSERT'then raise exception'RP409: Saved prompt coverage is immutable';end if;
 select *into g from public.property_video_kie_test_grants where id=new.grant_id for share;
 if g.id is null or g.revoked_at is not null or g.expires_at<=now()or g.profile<>'kie-kling3-4k-steady-v1'
  or g.quality_identity is distinct from public.property_video_prompt_identity('v1')
  or new.base_identity is distinct from g.quality_identity or new.recipe_identity is distinct from public.property_video_prompt_identity('v2')then
  raise exception'RP403: Prompt coverage must retain the exact active existing grant and reviewed recipe';end if;
 return new;end$$;
create trigger property_video_kie_prompt_coverage_guard before insert or update or delete on public.property_video_kie_prompt_coverage for each row execute function public.property_video_kie_prompt_coverage_guard();
create or replace function public.property_video_kie_prompt_coverage_allows(p_grant uuid,p_identity jsonb)returns boolean language plpgsql stable security definer set search_path=''as $$declare g public.property_video_kie_test_grants;begin
 if current_setting('role',true)is distinct from'service_role'then raise insufficient_privilege;end if;
 select *into g from public.property_video_kie_test_grants where id=p_grant;
 if g.id is null or g.revoked_at is not null or g.expires_at<=now()or g.profile<>'kie-kling3-4k-steady-v1'or g.quality_identity is distinct from public.property_video_prompt_identity('v1')then return false;end if;
 if p_identity=g.quality_identity then return true;end if;
 return p_identity=public.property_video_prompt_identity('v2')and exists(select 1 from public.property_video_kie_prompt_coverage c where c.grant_id=g.id and c.base_identity=g.quality_identity and c.recipe_identity=p_identity);end$$;
-- Separate recipe revision, initialized v1. This does not activate/change the KIE provider selector.
insert into public.app_config(key,value)values('property_video_prompt_recipe','{"revision":"v1"}')on conflict(key)do nothing;
create or replace function public.property_video_prompt_recipe_quote(p_actor uuid,p_manifest jsonb,p_grant uuid)returns jsonb language plpgsql security definer set search_path=''as $$declare profile text;c jsonb;revision text;identity jsonb;begin
 if current_setting('role',true)is distinct from'service_role'then raise insufficient_privilege;end if;
 perform public.property_video_actor_org(p_actor,(p_manifest->>'expected_org_id')::uuid,(p_manifest->>'listing_id')::uuid);
 profile:=public.property_video_quality_profile_for(p_actor,p_manifest,p_grant);
 if profile<>'kie-kling3-4k-steady-v1'then raise exception'RP409: This recipe is limited to the existing Kie property profile';end if;
 -- Held through admission: a concurrent recipe cutover cannot silently reinterpret a quoted operation.
 select value into c from public.app_config where key='property_video_prompt_recipe'for share;
 if c not in('{"revision":"v1"}'::jsonb,'{"revision":"v2"}'::jsonb)or c is null then raise exception'RP503: The prompt recipe revision is unavailable';end if;
 revision:=c->>'revision';identity:=public.property_video_prompt_identity(revision);
 if p_grant is not null and not public.property_video_kie_prompt_coverage_allows(p_grant,identity)then raise exception'RP403: The existing owner permission does not cover this prompt revision';end if;
 return jsonb_build_object('profile',profile,'quality_identity',identity,'revision',revision,'quote_profile',case when revision='v1'then profile else profile||'@prompt-v2'end);end$$;
revoke all on function public.property_video_prompt_identity(text),public.property_video_prompt_identity_registered(jsonb),public.property_video_kie_prompt_coverage_guard(),public.property_video_kie_prompt_coverage_allows(uuid,jsonb),public.property_video_prompt_recipe_quote(uuid,jsonb,uuid)from public,anon,authenticated;
grant execute on function public.property_video_prompt_identity(text),public.property_video_prompt_identity_registered(jsonb),public.property_video_kie_prompt_coverage_allows(uuid,jsonb),public.property_video_prompt_recipe_quote(uuid,jsonb,uuid)to service_role;

CREATE OR REPLACE FUNCTION public.property_video_quality_freeze()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$declare expected text;quoted text;consent jsonb;begin
 if TG_OP='UPDATE'then
  if new.quality_profile is distinct from old.quality_profile then raise exception'RP409: A saved video quality profile is immutable';end if;
  if new.quality_identity::text is distinct from old.quality_identity::text then raise exception'RP409: A saved video quality identity is immutable';end if;
  if new.kie_test_grant_id is distinct from old.kie_test_grant_id or new.processor_consent::text is distinct from old.processor_consent::text
   or new.consent_revision is distinct from old.consent_revision then raise exception'RP409: A saved video permission or test scope is immutable';end if;return new;
 end if;
 expected:=public.property_video_quality_profile_for(new.actor_id,new.manifest,nullif(current_setting('rendprop.property_video_test_grant',true),'')::uuid);quoted:=nullif(current_setting('rendprop.property_video_quality_profile',true),'');
 if quoted is null then
  if expected<>'legacy'then raise exception'RP409: A new video requires its current quoted quality profile';end if;
  quoted:='legacy';
 end if;
 if quoted not in('legacy','fal-kling3-4k-v1','fal-kling3-4k-steady-v2','kie-kling3-4k-steady-v1')or quoted<>expected then raise exception'RP409: The video quality quote changed before admission';end if;
 new.quality_profile:=quoted;new.quality_identity:=case when quoted='kie-kling3-4k-steady-v1'then public.property_video_prompt_identity(coalesce(nullif(current_setting('rendprop.property_video_prompt_revision',true),''),'v1'))else public.property_video_quality_identity(quoted)end;
 -- Fresh processor permission (required for Kie, persisted, immutable) and the exact
 -- owner quality-test scope that property_video_quality_profile_for just validated.
 consent:=public.property_video_processor_consent_record(quoted,nullif(current_setting('rendprop.property_video_consent',true),'')::jsonb);
 new.consent_revision:=coalesce(consent->>'token',new.consent_revision);new.processor_consent:=consent;
 new.kie_test_grant_id:=case when quoted='kie-kling3-4k-steady-v1'then nullif(current_setting('rendprop.property_video_test_grant',true),'')::uuid end;
 if quoted in('fal-kling3-4k-v1','fal-kling3-4k-steady-v2')then new.deadline:=new.created_at+interval'24 hours';end if;
 if quoted='kie-kling3-4k-steady-v1'then new.deadline:=new.created_at+interval'24 hours';end if;
 return new;
end$function$
;

CREATE OR REPLACE FUNCTION public.property_video_job_admit(p_actor uuid, p_manifest jsonb, p_quote numeric, p_quality_profile text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$declare j public.property_video_jobs;r public.property_video_refused_operations;h text;message text;prior text;prior_prompt text;prompt jsonb;begin
 if current_setting('role',true)is distinct from'service_role'then raise insufficient_privilege;end if;
 perform public.property_video_actor_org(p_actor,(p_manifest->>'expected_org_id')::uuid,(p_manifest->>'listing_id')::uuid);
 perform pg_advisory_xact_lock(hashtextextended('property-video-operation:'||p_actor||':'||(p_manifest->>'operation_id'),79));
 h:=encode(pg_catalog.sha256(pg_catalog.convert_to(p_manifest::text,'UTF8')),'hex');
 select *into j from public.property_video_jobs where actor_id=p_actor and operation_id=(p_manifest->>'operation_id')::uuid;
 if j.id is not null then j:=public.property_video_job_enqueue(p_actor,p_manifest);return jsonb_build_object('accepted',true,'job',to_jsonb(j));end if;
 select *into r from public.property_video_refused_operations where actor_id=p_actor and operation_id=(p_manifest->>'operation_id')::uuid;
 if r.operation_id is not null then if r.manifest_sha256<>h then raise exception'RP409: The refused operation has different saved inputs';end if;return jsonb_build_object('accepted',false,'message',r.message,'operation_closed',true);end if;
 if p_quality_profile in('kie-kling3-4k-steady-v1','kie-kling3-4k-steady-v1@prompt-v2')then
  prompt:=public.property_video_prompt_recipe_quote(p_actor,p_manifest,nullif(current_setting('rendprop.property_video_test_grant',true),'')::uuid);
  if p_quality_profile is distinct from prompt->>'quote_profile'then raise exception'RP409: The video prompt quote changed before admission';end if;
  p_quality_profile:='kie-kling3-4k-steady-v1';
 end if;
 if p_quality_profile is null or p_quality_profile not in('legacy','fal-kling3-4k-v1','fal-kling3-4k-steady-v2','kie-kling3-4k-steady-v1')or p_quality_profile<>public.property_video_quality_profile_for(p_actor,p_manifest,nullif(current_setting('rendprop.property_video_test_grant',true),'')::uuid)then raise exception'RP409: The video quality quote changed before admission';end if;
 -- These are generation-only minima, not permission to bypass the complete
 -- normal quote/capacity checks or automatic retry funding.
 if p_quality_profile in('fal-kling3-4k-v1','fal-kling3-4k-steady-v2')and(p_quote is null or p_quote<210*jsonb_array_length(p_manifest->'sources'))then raise exception'RP400: The property-video quality quote is incomplete';end if;
 -- Kie 4K: 67 credits/s x 5 s = 167.5 cents per source, exact numeric.
 if p_quality_profile='kie-kling3-4k-steady-v1'and(p_quote is null or p_quote<167.5*jsonb_array_length(p_manifest->'sources'))then raise exception'RP400: The property-video quality quote is incomplete';end if;
 -- The pinned route row must still equal the frozen identity. FOR SHARE holds
 -- it through the job insert, so a concurrent route edit cannot pass a stale quote.
 if p_quality_profile='kie-kling3-4k-steady-v1'then
  perform 1 from public.ai_routes route,(select public.property_video_quality_identity('kie-kling3-4k-steady-v1')kie)pinned
   where route.id=(pinned.kie->>'route_id')::uuid and route.task=pinned.kie->>'task'and route.provider=pinned.kie->>'provider'and route.model=pinned.kie->>'model'
    and route.unit=pinned.kie->>'unit'and route.unit_cents=(pinned.kie->>'unit_cents')::numeric and route.params=jsonb_build_object('kie_mode',pinned.kie->'mode','sound',pinned.kie->'sound')
    and route.enabled and route.privacy_tier=pinned.kie->>'privacy_tier'and(route.retire_after is null or route.retire_after>(now()at time zone'UTC')::date)for share of route;
  if not found then raise exception'RP409: The Kie property-video route changed before admission';end if;
 end if;
 begin perform public.property_video_recipe_capacity(p_actor,(p_manifest->>'listing_id')::uuid,jsonb_array_length(p_manifest->'sources'),p_quote);
 exception when others then get stacked diagnostics message=message_text;if position('RP402:'in message)<>1 then raise;end if;
 insert into public.property_video_refused_operations(actor_id,operation_id,listing_id,library_org_id,manifest_sha256,message)values(p_actor,(p_manifest->>'operation_id')::uuid,(p_manifest->>'listing_id')::uuid,public.listing_owner_library((p_manifest->>'listing_id')::uuid),h,substr(message,8,1000));return jsonb_build_object('accepted',false,'message',substr(message,8,1000),'operation_closed',true);end;
 prior:=current_setting('rendprop.property_video_quality_profile',true);prior_prompt:=current_setting('rendprop.property_video_prompt_revision',true);
 perform set_config('rendprop.property_video_prompt_revision',coalesce(prompt->>'revision',''),true);
 perform set_config('rendprop.property_video_quality_profile',p_quality_profile,true);
 j:=public.property_video_job_enqueue(p_actor,p_manifest);
 perform set_config('rendprop.property_video_quality_profile',coalesce(prior,''),true);
 perform set_config('rendprop.property_video_prompt_revision',coalesce(prior_prompt,''),true);
 return jsonb_build_object('accepted',true,'job',to_jsonb(j));
end$function$
;

CREATE OR REPLACE FUNCTION public.property_video_kie_dispatch_authority(p_job uuid, p_lease uuid, p_attempt uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$declare j public.property_video_jobs;s public.property_video_job_sources;g public.property_video_kie_test_grants;u public.property_video_kie_test_grant_uses;src public.property_video_job_sources;e jsonb;cost numeric;begin
 if current_setting('role',true)is distinct from'service_role'then raise insufficient_privilege;end if;
 perform public.property_video_job_worker_scope(p_job,p_lease,p_attempt);
 select *into j from public.property_video_jobs where id=p_job;
 select *into s from public.property_video_job_sources where job_id=p_job and attempt_id=p_attempt;
 if j.quality_profile is distinct from'kie-kling3-4k-steady-v1'or not public.property_video_prompt_identity_registered(j.quality_identity)
  or j.consent_revision is distinct from'property-video-jobs-v2'or jsonb_typeof(j.processor_consent)is distinct from'object'then
  raise exception'RP409: This saved video is not an exact native-4K Kie recipe with its processor permission';end if;
 if s.state is distinct from'dispatching'or s.receipt is not null or s.request_key is distinct from'bgvideo:'||s.attempt_id::text then
  raise exception'RP409: Only an unsent clip can ask for supplier authority';end if;
 if j.kie_test_grant_id is null then return jsonb_build_object('authority','activated_profile','job_id',j.id,'attempt_id',s.attempt_id);end if;
 select *into g from public.property_video_kie_test_grants where id=j.kie_test_grant_id for update;
 select *into u from public.property_video_kie_test_grant_uses where grant_id=g.id and attempt_id=s.attempt_id;
 -- An existing use is accounting only. Every prospective unsent POST still
 -- requires an active grant, including a lost-authority-reply recovery.
 if g.id is null or g.revoked_at is not null or g.expires_at<=now()then raise exception'RP403: The owner quality-test permission has ended. No new clip was sent.';end if;
 if u.grant_id is not null then
  if u.job_id<>j.id or u.request_key<>s.request_key then raise exception'RP409: Owner quality-test authority changed';end if;
  return jsonb_build_object('authority','owner_quality_test','grant_id',g.id,'attempt_id',s.attempt_id,'creates_used',g.creates_used,'cents_used',g.cents_used,'replayed',true);
 end if;
 if g.actor_id<>j.actor_id or g.listing_id<>j.listing_id or g.library_org_id<>j.library_org_id or not(j.operation_id=any(g.operation_ids))
  or not public.property_video_kie_prompt_coverage_allows(g.id,j.quality_identity) or jsonb_array_length(g.sources)<>j.source_count then
  raise exception'RP403: This clip is outside the owner quality-test permission';end if;
 for src in select *from public.property_video_job_sources where job_id=p_job order by position loop
  e:=g.sources->src.position;
  if e is null or e->>'photo_asset_id'is distinct from src.asset_id::text or e->>'photo_version_id'is distinct from src.version_id
   or e->>'photo_provenance_id'is distinct from src.photo_provenance_id::text or e->>'sha256'is distinct from src.source->>'sha256'then
   raise exception'RP403: This clip is outside the owner quality-test permission';end if;
 end loop;
 cost:=(j.quality_identity->>'attempt_cents')::numeric;
 if g.creates_used+1>g.max_creates or g.cents_used+cost>g.max_cents then raise exception'RP403: The owner quality-test budget is used up. No new clip was sent.';end if;
 insert into public.property_video_kie_test_grant_uses(grant_id,job_id,attempt_id,request_key,cents)values(g.id,j.id,s.attempt_id,s.request_key,cost);
 update public.property_video_kie_test_grants set creates_used=creates_used+1,cents_used=cents_used+cost where id=g.id returning *into g;
 return jsonb_build_object('authority','owner_quality_test','grant_id',g.id,'attempt_id',s.attempt_id,'creates_used',g.creates_used,'cents_used',g.cents_used,'replayed',false);end$function$
;

CREATE OR REPLACE FUNCTION public.paid_quality_processing_budget(p_org uuid)
 RETURNS integer
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare b uuid;o public.orgs;s public.apple_subscriptions;c jsonb;v jsonb;p jsonb;selected_plan text;amount numeric;quality boolean:=false;begin
 if public.serving_mode()<>'ceiling'then return 0;end if;
 select value into c from public.app_config where key='paid_quality_processing';
 if c is null or c->'enabled'='false'::jsonb then return 0;end if;
 if c->'enabled' is distinct from 'true'::jsonb or c->>'policy' is distinct from 'bounded-paid-quality-v1'then raise exception'RP503: Paid processing policy is unavailable';end if;
 select value into v from public.app_config where key='property_video_quality';
 quality:=coalesce(v->'enabled'='true'::jsonb and(v->>'profile'in('fal-kling3-4k-v1','fal-kling3-4k-steady-v2')or(v->>'profile'='kie-kling3-4k-steady-v1'and v->'vendor_content_license'=public.property_video_quality_identity('kie-kling3-4k-steady-v1')->'content_license_ack')),false);
 -- Admitted Kie work keeps this bounded floor after the selector changes (default
 -- rollback, new-admission hold or an owner quality-test window), but only for this
 -- billing org's own not-cancelled, pre-deadline Kie jobs whose frozen identity is
 -- exactly the reviewed one. FAL accounting is unchanged: it follows the selector.
 if not quality then quality:=exists(select 1 from public.property_video_jobs j where j.quality_profile='kie-kling3-4k-steady-v1'and public.property_video_prompt_identity_registered(j.quality_identity)
  and j.state in('queued','generating','quality_review','composing','failed')and j.cancelled_at is null and j.deadline>now()and public.library_billing_org(j.org_id)=public.library_billing_org(p_org));end if;
 select value into p from public.app_config where key='photo_preservation_quality';
 if p->'enabled'='true'::jsonb and p->>'profile'='gemini-pro-4k-preservation-v1'and jsonb_typeof(p->'tasks')='array'then
  if jsonb_array_length(p->'tasks')between 1 and 2 and(p->'tasks')<@'["photo.stage","photo.declutter"]'::jsonb
   and(select count(distinct x)=jsonb_array_length(p->'tasks')from jsonb_array_elements_text(p->'tasks')x)then quality:=true;end if;
 end if;
 if not quality then return 0;end if;
 b:=public.library_billing_org(p_org);select *into o from public.orgs where id=b and deleted_at is null;
 if o.id is null or o.plan_source is distinct from'apple'or o.plan_expires_at is null or o.plan_expires_at<=now()then return 0;end if;
 selected_plan:=public.effective_plan_before_team(b);
 if selected_plan not in('starter','solo','pro','team')or public.org_has_app_review_funding(b)then return 0;end if;
 select *into s from public.apple_subscriptions where org_id=b and environment='Production'and status='active'
  and product_id=o.apple_product_id and plan=selected_plan and expires_at=o.plan_expires_at and expires_at>now()
  and transaction_purchased_at is not null and transaction_purchased_at<=now()and transaction_signed_at is not null
  and expires_at>transaction_purchased_at+interval'8 days'order by expires_at desc limit 1;
 if s.original_transaction_id is null then return 0;end if;
 if jsonb_typeof(c->(selected_plan||'_cents'))is distinct from'number'then raise exception'RP503: Paid processing allowance is unavailable';end if;
 amount:=(c->>(selected_plan||'_cents'))::numeric;
 if amount<>trunc(amount)or amount<1 or amount>100000 then raise exception'RP503: Paid processing allowance is unavailable';end if;
 return amount::integer;
end$function$
;

create or replace function public.property_video_source_read_resume_proof(p_job uuid) returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare j public.property_video_jobs;s public.property_video_job_sources;rows jsonb;failed integer;payload jsonb;c jsonb;m jsonb;permission_at timestamptz;
begin
 if current_setting('role',true) is distinct from 'service_role' then raise insufficient_privilege;end if;
 j:=public.property_video_job_scope(p_job,null,false);
 if j.state<>'failed' or j.cancelled_at is not null or j.deadline<=now() then return null;end if;
 -- This recovery is the exact activated Kie recipe only. Owner-test grants and
 -- other profiles retain their existing, separate authorities and limits.
 if j.quality_profile is distinct from 'kie-kling3-4k-steady-v1'
  or not public.property_video_prompt_identity_registered(j.quality_identity)
  or j.kie_test_grant_id is not null or j.consent_revision is distinct from 'property-video-jobs-v2'
  or jsonb_typeof(j.processor_consent) is distinct from 'object' then return null;end if;
 if (j.processor_consent-array['token','disclosure_revision','processors','recorded_at'])<>'{}'::jsonb
  or jsonb_typeof(j.processor_consent->'recorded_at') is distinct from 'string' then return null;end if;
 begin permission_at:=(j.processor_consent->>'recorded_at')::timestamptz;
 exception when invalid_datetime_format or datetime_field_overflow then return null;end;
 if not isfinite(permission_at) or permission_at>now() or permission_at<j.created_at-interval '5 minutes' or permission_at>j.created_at+interval '5 minutes' then return null;end if;
 c:=public.property_video_processor_consent_current();
 if c is null or j.processor_consent->'token' is distinct from c->'token'
  or j.processor_consent->'disclosure_revision' is distinct from c->'disclosure_revision'
  or j.processor_consent->'processors' is distinct from c->'processors' then return null;end if;
 if jsonb_typeof(j.manifest->'sources') is distinct from 'array' or jsonb_array_length(j.manifest->'sources')<>j.source_count
  or j.source_count not between 1 and 100 or j.manifest->>'operation_id' is distinct from j.operation_id::text
  or j.manifest->>'listing_id' is distinct from j.listing_id::text
  or j.manifest_sha256 is distinct from encode(pg_catalog.sha256(pg_catalog.convert_to(j.manifest::text,'UTF8')),'hex') then return null;end if;
 if j.result is not null or j.compose_attempts<>0 or j.output_asset_id is not null or j.poster_asset_id is not null then return null;end if;
 select count(*) into failed from public.property_video_job_sources where job_id=p_job and state='failed';
 -- One closed failure; an ambiguous or unrelated failure must be reconciled.
 if failed<>1 or exists(select 1 from public.property_video_job_sources where job_id=p_job and state not in('pending','processing','quality_review','ready','original_photo','failed')) then return null;end if;
 for s in select * from public.property_video_job_sources where job_id=p_job order by position loop
  m:=j.manifest->'sources'->s.position;
  if m is null or m->>'photo_id' is distinct from s.photo_id or m->>'photo_asset_id' is distinct from s.asset_id::text
   or m->>'photo_version_id' is distinct from s.version_id or m->>'photo_provenance_id' is distinct from s.photo_provenance_id::text
   or m->>'motion' is distinct from s.motion then return null;end if;
  begin
   if public.property_photo_reference(j.actor_id,j.listing_id,s.asset_id,s.photo_provenance_id) is distinct from s.source then return null;end if;
  exception when sqlstate 'P0001' then
   if sqlerrm like 'RP403:%' or sqlerrm like 'RP404:%' or sqlerrm like 'RP409:%' then return null;end if;raise;
  end;
  if s.state<>'failed' then continue;end if;
  if s.last_error is distinct from 'source_unavailable' or s.attempt_id is null or s.request_key is distinct from 'bgvideo:'||s.attempt_id::text
   or s.receipt is not null or s.clip is not null or s.generation_provenance_id is not null or s.provider_terminal_at is not null
   or s.lease_until>now() or s.admission_retries>=3
   or exists(select 1 from jsonb_array_elements(s.non_dispatch_history) h where h->>'reason'='source_unavailable')
   or exists(select 1 from public.property_video_source_read_retired_keys r where r.request_key=s.request_key) then return null;end if;
  -- No held, rejected, settled, accepted or otherwise uncertain supplier row
  -- may be treated as a failed local read. Even a released hold is ineligible.
  if exists(select 1 from public.app_video_cost_reservations r where r.actor_id=j.actor_id and r.org_id=j.org_id and r.idempotency_key=s.request_key)
   or exists(select 1 from public.serving_cost_reservations r where r.actor_id=j.actor_id and r.org_id=j.org_id and r.request_key=s.request_key)
   or exists(select 1 from public.serving_operations r where r.actor_id=j.actor_id and r.org_id=j.org_id and r.request_key=s.request_key)
   or exists(select 1 from public.serving_operation_results r where r.actor_id=j.actor_id and r.org_id=j.org_id and r.request_key=s.request_key)
   or exists(select 1 from public.app_video_submission_receipts r where r.actor_id=j.actor_id and r.org_id=j.org_id and r.operation_id=s.request_key)
   or exists(select 1 from public.cost_ledger r where r.org_id=j.org_id and (r.meta->>'request_key'=s.request_key or r.idempotency_key=s.request_key))
   or exists(select 1 from public.property_video_kie_test_grant_uses r where r.job_id=p_job and (r.attempt_id=s.attempt_id or r.request_key=s.request_key)) then return null;end if;
 end loop;
 select jsonb_agg(to_jsonb(x) order by position) into rows from public.property_video_job_sources x where job_id=p_job;
 if jsonb_array_length(rows) is distinct from j.source_count then return null;end if;
 payload:=jsonb_build_object('schema',1,'job',to_jsonb(j),'sources',rows,'failed_positions',(select jsonb_agg(position order by position) from public.property_video_job_sources where job_id=p_job and state='failed'));
 return payload||jsonb_build_object('proof_sha256',encode(pg_catalog.sha256(pg_catalog.convert_to(payload::text,'UTF8')),'hex'));
end$$;
