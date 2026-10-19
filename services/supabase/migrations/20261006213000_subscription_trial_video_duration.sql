begin;
-- Created with `supabase migration new subscription_trial_video_duration`,
-- renamed to the parent-assigned additive candidate order. No live application.
-- A client duration is never the authority for the bounded trial.
create table if not exists public.subscription_trial_video_attestations (
 -- Technical evidence follows asset cleanup; it is not a financial tombstone.
 asset_id uuid not null references public.capture_assets(id)on delete cascade,org_id uuid not null,listing_id uuid not null,actor_id uuid not null,
 bucket text not null check(bucket='renders'),storage_key text not null,
 etag text not null check(length(etag)between 1 and 256),bytes bigint not null check(bytes between 1 and 1073741824),
 checker text not null check(checker='mp4-timing-v1'),duration_s numeric not null,billable_s numeric not null,
 created_at timestamptz not null default clock_timestamp(),
 primary key(asset_id,etag,bytes,checker),
 check(duration_s>0 and billable_s>0 and duration_s<=90 and billable_s<=90)
);
alter table public.subscription_trial_video_attestations enable row level security;
revoke all on public.subscription_trial_video_attestations from public,anon,authenticated,service_role;
grant select on public.subscription_trial_video_attestations to service_role;

create or replace function public.subscription_trial_video_context(p_actor uuid,p_org uuid,p_listing uuid,p_asset uuid)
returns jsonb language plpgsql security definer set search_path='' as $$
declare a public.capture_assets;g public.subscription_trial_grants;r public.upload_reservations;op public.upload_operations;
begin
 if current_setting('role',true)is distinct from 'service_role'then raise insufficient_privilege;end if;
 if not exists(select 1 from public.orgs where id=p_org and deleted_at is null)
  or not exists(select 1 from public.listings where id=p_listing and org_id=p_org and deleted_at is null)
  or not exists(select 1 from public.memberships where org_id=p_org and user_id=p_actor and role in('owner','admin','agent'))
  or not exists(select 1 from auth.users where id=p_actor)
  or exists(select 1 from public.deletion_requests where user_id=p_actor and status in('pending','processing'))then
  raise exception 'RP403: Current video workspace authority is required';end if;
 if public.subscription_trial_paid_or_override(p_org)then return jsonb_build_object('required',false);end if;
 -- Preserve only the existing finite funded legacy trial, not a bare plan.
 if exists(select 1 from public.serving_funding f join public.serving_funding_slices s on s.funding_id=f.id and s.org_id=p_org
  where f.org_id=p_org and f.actor_id=p_actor and f.source='trial'and f.created_at<(select created_at from public.subscription_trial_config where singleton)
   and f.sponsored_cents>0 and f.revoked_at is null and f.starts_at<=now()and f.ends_at>now()
   and s.starts_at<=now()and s.ends_at>now()and s.total_budget_cents>0)then return jsonb_build_object('required',false);end if;
 g:=public.subscription_trial_active(p_org,p_actor);
 if g.id is null then raise exception 'RP402: An active funded trial is required';end if;
 select * into a from public.capture_assets where id=p_asset and listing_id=p_listing;
 if a.id is null or a.kind<>'video'or a.bucket<>'renders'or a.uploaded is not true or a.upload_aborted or a.transport_version<>2
  or a.bytes is null or a.bytes not between 1 and g.upload_budget_bytes
  or a.storage_key !~ ('^renders/'||p_org::text||'/'||p_listing::text||'/[A-Za-z0-9_-][A-Za-z0-9_.-]*[.]mp4$')
  or position('..'in a.storage_key)>0 then raise exception 'RP409: A finalized owned MP4 upload is required';end if;
 perform public.assert_studio_asset_quality(a.id);
 select * into r from public.upload_reservations where asset_id=a.id and org_id=p_org and listing_id=p_listing and actor_id=p_actor and state='completed';
 if r.asset_id is null then raise exception 'RP409: The finalized upload receipt is required';end if;
 select * into op from public.upload_operations where asset_id=a.id and kind in('copy','assemble')and state='retained'
  and bucket=a.bucket and object_key=a.storage_key and asset_kind='video'and expected_bytes=a.bytes
  and lower(split_part(content_type,';',1))='video/mp4'and etag is not null;
 if op.id is null or(select count(*)from public.upload_operations where asset_id=a.id and kind in('copy','assemble')and state='retained')<>1 then
  raise exception 'RP409: An exact retained video receipt is required';end if;
 return jsonb_build_object('required',true,'actor_id',p_actor,'org_id',p_org,'listing_id',p_listing,'asset_id',a.id,
  'bucket',a.bucket,'storage_key',a.storage_key,'etag',op.etag,'bytes',a.bytes,'max_video_seconds',least(90,g.max_video_seconds));
end$$;

create or replace function public.record_subscription_trial_video(p_actor uuid,p_org uuid,p_listing uuid,p_asset uuid,
 p_bucket text,p_key text,p_etag text,p_bytes bigint,p_duration numeric,p_billable numeric,p_checker text)
returns jsonb language plpgsql security definer set search_path='' as $$
declare ctx jsonb;prior public.subscription_trial_video_attestations;
begin
 if current_setting('role',true)is distinct from 'service_role'then raise insufficient_privilege;end if;
 -- Lock the current identities; a concurrent deletion or receipt rewrite cannot
 -- turn a network observation into authority for a different object.
 perform 1 from public.orgs where id=p_org for share;
 perform 1 from public.listings where id=p_listing for share;
 perform 1 from public.capture_assets where id=p_asset for share;
 perform 1 from public.memberships where org_id=p_org and user_id=p_actor for share;
 perform 1 from public.upload_reservations where asset_id=p_asset for share;
 perform 1 from public.upload_operations where asset_id=p_asset and kind in('copy','assemble')for share;
 ctx:=public.subscription_trial_video_context(p_actor,p_org,p_listing,p_asset);
 if ctx->>'required' is distinct from 'true' or row(p_bucket,p_key,p_etag,p_bytes)
  is distinct from row(ctx->>'bucket',ctx->>'storage_key',ctx->>'etag',(ctx->>'bytes')::bigint)then
  raise exception 'RP409: The video changed while its duration was checked';end if;
 if p_checker is distinct from 'mp4-timing-v1'or p_duration is null or p_billable is null
  or p_duration::text in('NaN','Infinity','-Infinity')or p_billable::text in('NaN','Infinity','-Infinity')
  or p_duration<=0 or p_billable<=0 or greatest(p_duration,p_billable)>(ctx->>'max_video_seconds')::numeric then
  raise exception 'RP402: The trial walkthrough must be within its verified video duration limit';end if;
 insert into public.subscription_trial_video_attestations(asset_id,org_id,listing_id,actor_id,bucket,storage_key,etag,bytes,checker,duration_s,billable_s)
 values(p_asset,p_org,p_listing,p_actor,p_bucket,p_key,p_etag,p_bytes,p_checker,p_duration,p_billable)on conflict do nothing;
 select * into prior from public.subscription_trial_video_attestations where asset_id=p_asset and etag=p_etag and bytes=p_bytes and checker=p_checker;
 if row(prior.org_id,prior.listing_id,prior.actor_id,prior.bucket,prior.storage_key,prior.duration_s,prior.billable_s)
  is distinct from row(p_org,p_listing,p_actor,p_bucket,p_key,p_duration,p_billable)then raise exception 'RP409: The video duration attestation is immutable';end if;
 return jsonb_build_object('attested',true,'duration_s',prior.duration_s,'billable_s',prior.billable_s);
end$$;

create or replace function public.assert_subscription_trial_video(p_actor uuid,p_org uuid,p_listing uuid,p_asset uuid,p_max integer)
returns numeric language plpgsql security definer set search_path='' as $$
declare verified numeric;
begin
 select t.duration_s into verified from public.subscription_trial_video_attestations t
  join public.capture_assets a on a.id=t.asset_id and a.listing_id=t.listing_id
  join public.upload_reservations r on r.asset_id=a.id and r.actor_id=t.actor_id and r.org_id=t.org_id and r.listing_id=t.listing_id and r.state='completed'
  join public.upload_operations op on op.asset_id=a.id and op.kind in('copy','assemble')and op.state='retained'
   and op.bucket=t.bucket and op.object_key=t.storage_key and op.etag=t.etag and op.expected_bytes=t.bytes and op.asset_kind='video'
  where t.actor_id=p_actor and t.org_id=p_org and t.listing_id=p_listing and t.asset_id=p_asset and t.checker='mp4-timing-v1'
   and a.kind='video'and a.bucket=t.bucket and a.storage_key=t.storage_key and a.bytes=t.bytes and a.uploaded is true
   and a.upload_aborted is false and a.transport_version=2
   and greatest(t.duration_s,t.billable_s)<=least(90,p_max)
   and lower(split_part(op.content_type,';',1))='video/mp4'
   and exists(select 1 from public.orgs where id=p_org and deleted_at is null)
   and exists(select 1 from public.listings where id=p_listing and org_id=p_org and deleted_at is null)
   and exists(select 1 from public.memberships where user_id=p_actor and org_id=p_org and role in('owner','admin','agent'))
   and exists(select 1 from auth.users where id=p_actor and is_anonymous is false)
   and not exists(select 1 from public.deletion_requests where user_id=p_actor and status in('pending','processing'))
   and(select count(*)from public.upload_operations where asset_id=a.id and kind in('copy','assemble')and state='retained')=1;
 if verified is null then raise exception 'RP402: A matching verified trial-video duration is required';end if;
 perform public.assert_studio_asset_quality(p_asset);
 return verified;
end$$;

-- Patch the actual action boundary before either action is consumed. Existing
-- job/render fast-path replays do not insert and keep their recorded results.
do $patch$declare d text;b text;needle text;begin
 select pg_get_functiondef(oid),prosrc into d,b from pg_proc where oid='public.subscription_trial_render_guard()'::regprocedure;
 if position('assert_subscription_trial_video'in b)=0 then
  needle:=E' if tg_table_name=''render_jobs''then\n  if new.source';
  if(length(b)-length(replace(b,needle,'')))/length(needle)<>1 then raise exception 'Unknown trial render admission body';end if;
  execute replace(d,needle,E' if tg_table_name=''renders''then new.duration_s:=public.assert_subscription_trial_video(auth.uid(),org,listing,asset,g.max_video_seconds);\n else perform public.assert_subscription_trial_video(auth.uid(),org,listing,asset,g.max_video_seconds);end if;\n'||needle);
 end if;
end$patch$;
revoke all on function public.subscription_trial_video_context(uuid,uuid,uuid,uuid),
 public.record_subscription_trial_video(uuid,uuid,uuid,uuid,text,text,text,bigint,numeric,numeric,text),
 public.assert_subscription_trial_video(uuid,uuid,uuid,uuid,integer)from public,anon,authenticated,service_role;
grant execute on function public.subscription_trial_video_context(uuid,uuid,uuid,uuid),
 public.record_subscription_trial_video(uuid,uuid,uuid,uuid,text,text,text,bigint,numeric,numeric,text)to service_role;
commit;
