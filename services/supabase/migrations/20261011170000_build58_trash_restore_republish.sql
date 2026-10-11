-- Build 58: a deleted listing can be restored for 30 days ("Recently deleted"),
-- and an already-published tour can be republished IN PLACE so the share link,
-- QR codes and MLS field never change.
--
-- Trash (listings.trash_expires_at):
--   * DELETE /listings/:id now sets deleted_at AND trash_expires_at = now()+30d.
--     While the window is open the storage-cleanup job is NOT queued; the
--     listing's media stays exactly where it is. When the window closes,
--     listing_trash_sweep() (hourly cron) queues the same cleanup the delete
--     trigger used to queue immediately — same payload, same ownership checks,
--     same manual-review rules (the trigger body moved verbatim into
--     queue_listing_media_cleanup(uuid); the trigger now calls it).
--   * Account deletion is unchanged and still immediate: prepare_account_deletion
--     gathers media from every listing in the solo orgs with no deleted_at
--     filter, and a trashed listing has no pending job to wait for.
--   * restore_listing(actor, listing): write access to the listing's logical
--     library (the same library_content_access predicate every write uses),
--     clears deleted_at/trash_expires_at, and re-publishes exactly the renders
--     the delete took down (renders.unpublished_by_delete_at, stamped by the
--     unpublish trigger). Client delivery links that were cancelled stay
--     cancelled — the response says so and the app tells the agent.
--   * list_trashed_listings(actor, org): what the "Recently deleted" screen shows.
--
-- Republish (republish_render): same authority as publish_render, same asset
-- checks, same server-derived `staged` rule; but instead of inserting a new
-- renders row with a new slug it moves the listing's CURRENT published render
-- onto the new job/asset in place. Replay-safe per job. With no published
-- render it falls back to publish_render (a first publish).
begin;

alter table public.listings add column if not exists trash_expires_at timestamptz;
alter table public.renders add column if not exists unpublished_by_delete_at timestamptz;
create index if not exists listings_trash_expires_idx on public.listings(trash_expires_at) where deleted_at is not null and trash_expires_at is not null;

-- ── 1. The unpublish trigger records WHICH renders it took down ─────────────
do $pin$declare h text;begin select md5(prosrc)into h from pg_catalog.pg_proc where oid='public.unpublish_deleted_listing_renders()'::regprocedure; if h not in('dfcfe5b22ecc548d9010561274a3f201','d74256a0c4649a8557f50b3ca301a0ea') then raise exception 'unpublish_deleted_listing_renders drifted from the reviewed body (%)',h;end if;end$pin$;
CREATE OR REPLACE FUNCTION public.unpublish_deleted_listing_renders()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  if new.deleted_at is not null and old.deleted_at is null then
    update renders set published_at = null, unpublished_by_delete_at = now()
     where listing_id = new.id and published_at is not null;
  end if;
  return new;
end;
$function$;

-- ── 2. The cleanup enqueue, callable by id (trigger body moved verbatim) ────
do $pin$declare h text;begin select md5(prosrc)into h from pg_catalog.pg_proc where oid='public.queue_deleted_listing_media()'::regprocedure; if h not in('5120c516c8d297aa46002d25a03e876e','9af9a8ab2186b4f94a2f14b510654d1e') then raise exception 'queue_deleted_listing_media drifted from the reviewed body (%)',h;end if;end$pin$;
create or replace function public.queue_listing_media_cleanup(p_listing uuid) returns void
 language plpgsql security definer set search_path to ''
as $function$
declare new public.listings;payload jsonb;wait_until timestamptz;needs_review boolean:=false;
begin
 select * into new from public.listings where id=p_listing;
 if new.id is null or new.deleted_at is null then return;end if;
 select jsonb_build_object('r2',coalesce(jsonb_agg(distinct jsonb_build_object('bucket',q.bucket,'key',q.key)),'[]'::jsonb),
  'stream_uids',coalesce((select jsonb_agg(distinct stream_uid)from public.renders where listing_id=new.id and stream_uid is not null),'[]'::jsonb),'ghl_targets','[]'::jsonb)
 into payload from(
  select bucket,storage_key as key from public.capture_assets where listing_id=new.id
  union select case when starts_with(original_key,'uploads/')then 'uploads'else 'renders'end,original_key from public.photos where listing_id=new.id
  union select 'renders',enhanced_key from public.photos where listing_id=new.id
  union select 'renders',video_key from public.renders where listing_id=new.id
  union select 'renders',poster_key from public.renders where listing_id=new.id
  union select 'renders',hero_key from public.renders where listing_id=new.id
  union select 'renders',new.main_photo_key
  union select bucket,storage_key from public.private_ai_outputs where listing_id=new.id and org_id=new.org_id
  union select 'uploads',output_key from public.studio_presenter_jobs where listing_id=new.id and org_id=new.org_id
  union select 'renders',import_storage_key from public.studio_presenter_jobs where listing_id=new.id and org_id=new.org_id
 )q where q.key is not null and q.key<>'';
 if exists(select 1 from jsonb_array_elements(payload->'r2')t where t->>'bucket'not in('uploads','renders')or length(t->>'key')>4096 or t->>'key'~'(^|/)[.]{1,2}(/|$)'or not(
  starts_with(t->>'key',(t->>'bucket')||'/'||new.org_id||'/'||new.id||'/')or
  (t->>'bucket'='renders'and starts_with(t->>'key','renders/'||new.id||'/'))or
  exists(select 1 from public.private_ai_outputs p where p.org_id=new.org_id and p.listing_id=new.id and p.bucket=t->>'bucket'and p.storage_key=t->>'key')or
  exists(select 1 from public.studio_presenter_jobs j where j.org_id=new.org_id and j.listing_id=new.id and
   ((t->>'bucket'='uploads'and j.output_key=t->>'key'and j.output_key='presenter-private/'||new.org_id||'/'||j.id||'/output.mp4')or(t->>'bucket'='renders'and j.import_storage_key=t->>'key'and starts_with(j.import_storage_key,'renders/'||new.org_id||'/'||new.id||'/'))))))then needs_review:=true;end if;
 select greatest(now()+interval '1 hour',max(expires_at)+interval '1 hour')into wait_until
 from public.upload_reservations where listing_id=new.id;
 if exists(select 1 from public.capture_assets where listing_id=new.id and transport_version=1)then wait_until:=greatest(wait_until,now()+interval '75 minutes');end if;
 select greatest(wait_until,max(output_write_deadline)+interval '1 hour')into wait_until from public.studio_presenter_jobs where listing_id=new.id and org_id=new.org_id;
 if exists(select 1 from public.render_jobs where listing_id=new.id and source='worker'and status='processing')then needs_review:=true;end if;
 insert into public.privacy_cleanup_jobs(kind,org_id,source_id,source_user_id,payload,remaining,not_before,state,last_error)
 values('listing',new.org_id,new.id,new.agent_id,payload,payload,wait_until,case when needs_review then 'manual_review'else 'pending'end,case when needs_review then 'Storage ownership or an unjournaled worker requires assisted cleanup.'else null end)on conflict(kind,source_id)do nothing;
end$function$;
revoke all on function public.queue_listing_media_cleanup(uuid) from public,anon,authenticated;
grant execute on function public.queue_listing_media_cleanup(uuid) to service_role,postgres;

CREATE OR REPLACE FUNCTION public.queue_deleted_listing_media()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
begin
 if old.deleted_at is not null or new.deleted_at is null then return new;end if;
 -- An open restore window keeps the media. listing_trash_sweep() queues the
 -- cleanup when the window closes; a delete with no window queues it now.
 if new.trash_expires_at is not null and new.trash_expires_at>now() then return new;end if;
 perform public.queue_listing_media_cleanup(new.id);
 return new;
end$function$;

-- ── 3. Hourly: trash whose window closed gets the cleanup it was owed ───────
create or replace function public.listing_trash_sweep() returns integer
 language plpgsql security definer set search_path to ''
as $function$
declare r record;n integer:=0;
begin
 if current_setting('role',true)is distinct from 'service_role'and session_user<>'postgres'then raise insufficient_privilege using message='service role required';end if;
 for r in select id from public.listings where deleted_at is not null and trash_expires_at is not null and trash_expires_at<=now()
   and not exists(select 1 from public.privacy_cleanup_jobs j where j.kind='listing'and j.source_id=listings.id)order by trash_expires_at,id limit 200 loop
  perform public.queue_listing_media_cleanup(r.id);
  update public.listings set trash_expires_at=null where id=r.id;
  n:=n+1;
 end loop;
 return n;
end$function$;
revoke all on function public.listing_trash_sweep() from public,anon,authenticated;
grant execute on function public.listing_trash_sweep() to service_role,postgres;
do $cron$begin
 if exists(select 1 from pg_catalog.pg_extension where extname='pg_cron')then
  perform cron.unschedule(jobid)from cron.job where jobname='listing-trash-sweep';
  perform cron.schedule('listing-trash-sweep','23 * * * *','set role service_role;select public.listing_trash_sweep();');
 end if;
end$cron$;

-- ── 4. The logical library of a listing, deleted or not ─────────────────────
-- listing_owner_library() answers null for a deleted row on purpose (every
-- live-content predicate must fail for it). Restore needs the same mapping
-- without that filter; nothing else may use this.
create or replace function public.trashed_listing_library(p_listing uuid) returns uuid
 language sql stable security definer set search_path to ''
as $function$
 select case when exists(select 1 from public.org_invites i where i.org_id=l.org_id and i.accepted_by=l.agent_id and i.accepted_at is not null)
 then public.agent_private_library(l.agent_id)else l.org_id end from public.listings l where l.id=p_listing and l.deleted_at is not null;
$function$;
revoke all on function public.trashed_listing_library(uuid) from public,anon,authenticated;
grant execute on function public.trashed_listing_library(uuid) to service_role,postgres;

-- ── 5. Recently deleted: list + restore ─────────────────────────────────────
create or replace function public.list_trashed_listings(p_actor uuid,p_org uuid) returns jsonb
 language plpgsql stable security definer set search_path to ''
as $function$
declare rows jsonb;
begin
 if current_setting('role',true)not in('service_role','postgres','supabase_admin')and not(current_setting('role',true)='none'and session_user in('postgres','supabase_admin'))then raise insufficient_privilege;end if;
 if not public.library_content_access(p_actor,p_org,false)then raise exception 'RP403: This listing library is not available to this account';end if;
 select coalesce(jsonb_agg(jsonb_build_object('id',l.id,'org_id',l.org_id,'library_org_id',p_org,'agent_id',l.agent_id,'address',l.address,'space_type',l.space_type,
   'main_photo_key',l.main_photo_key,'deleted_at',l.deleted_at,'trash_expires_at',l.trash_expires_at,
   'had_published_tour',exists(select 1 from public.renders r where r.listing_id=l.id and r.unpublished_by_delete_at is not null),
   'can_restore',public.library_content_access(p_actor,p_org,true))order by l.deleted_at desc),'[]'::jsonb)
 into rows from public.listings l where l.deleted_at is not null and l.trash_expires_at is not null and l.trash_expires_at>now()
  and public.trashed_listing_library(l.id)=p_org and not exists(select 1 from public.privacy_cleanup_jobs j where j.kind='listing'and j.source_id=l.id);
 return jsonb_build_object('actor_id',p_actor,'org_id',p_org,'listings',rows);
end$function$;
revoke all on function public.list_trashed_listings(uuid,uuid) from public,anon,authenticated;
grant execute on function public.list_trashed_listings(uuid,uuid) to service_role,postgres;

create or replace function public.restore_listing(p_actor uuid,p_listing uuid) returns jsonb
 language plpgsql security definer set search_path to ''
as $function$
declare l public.listings;library uuid;republished integer:=0;cancelled_deliveries integer;
begin
 if current_setting('role',true)not in('service_role','postgres','supabase_admin')and not(current_setting('role',true)='none'and session_user in('postgres','supabase_admin'))then raise insufficient_privilege;end if;
 if p_actor is null or p_listing is null then raise exception 'RP400: Choose a valid listing';end if;
 select * into l from public.listings where id=p_listing for update;
 if l.id is null then raise exception 'RP404: Listing not found';end if;
 if l.deleted_at is null then raise exception 'RP409: This listing is not deleted';end if;
 if exists(select 1 from public.deletion_requests d where d.user_id=p_actor and d.status in('pending','processing'))then raise exception 'RP409: This account is being deleted';end if;
 library:=public.trashed_listing_library(l.id);
 if library is null or not public.library_content_access(p_actor,library,true)then raise exception 'RP403: Your role does not permit restoring this listing';end if;
 if l.trash_expires_at is null or l.trash_expires_at<=now() or exists(select 1 from public.privacy_cleanup_jobs j where j.kind='listing'and j.source_id=l.id)then
  raise exception 'RP410: The restore window for this listing has closed';
 end if;
 if exists(select 1 from public.orgs o where o.id=l.org_id and o.deleted_at is not null)then raise exception 'RP403: This listing library is unavailable';end if;
 update public.listings set deleted_at=null,trash_expires_at=null where id=l.id;
 update public.renders set published_at=now(),unpublished_by_delete_at=null where listing_id=l.id and unpublished_by_delete_at is not null and published_at is null;
 get diagnostics republished=row_count;
 -- Deliveries the delete skipped stay skipped: the client contact must be re-enabled by the agent.
 select count(*)into cancelled_deliveries from public.client_lead_deliveries d where d.listing_id=l.id and d.state='skipped'and d.reason='The listing was deleted.';
 return jsonb_build_object('ok',true,'actor_id',p_actor,'listing_id',l.id,'org_id',l.org_id,'library_org_id',library,'address',l.address,
  'republished_renders',republished,'cancelled_client_deliveries',cancelled_deliveries,'restored_at',now());
end$function$;
revoke all on function public.restore_listing(uuid,uuid) from public,anon,authenticated;
grant execute on function public.restore_listing(uuid,uuid) to service_role,postgres;

-- ── 6. Republish in place ───────────────────────────────────────────────────
do $pin$declare h text;begin select md5(prosrc)into h from pg_catalog.pg_proc where oid='public.publish_render(uuid,numeric,numeric,jsonb,uuid)'::regprocedure; if h<>'356cdfa9a44b88f628d08af9fee72c13' then raise exception 'publish_render drifted from the reviewed body (%)',h;end if;end$pin$;
create or replace function public.republish_render(p_job uuid,p_duration numeric default null,p_speed numeric default 2.0,p_chapters jsonb default '[]'::jsonb,p_poster_asset uuid default null)
 returns public.renders
 language plpgsql security definer set search_path to 'public'
as $function$
declare
  v_job render_jobs; v_org uuid; v_role text; v_asset capture_assets; v_poster capture_assets; v_poster_key text := null;
  v_render renders; v_current renders; v_dur numeric; v_staged boolean; v_style text;
begin
  select rj.* into v_job from render_jobs rj where rj.id = p_job;
  if not found then raise exception 'RP404: render job not found'; end if;
  select l.org_id into v_org from listings l where l.id = v_job.listing_id and l.deleted_at is null;
  if v_org is null then raise exception 'RP404: listing not found'; end if;
  v_role := public.library_scope_role(auth.uid(),v_org,v_job.listing_id);
  if v_role is null then raise exception 'RP403: not a member of this workspace'; end if;
  if v_role not in ('owner','admin','agent') then raise exception 'RP403: your role does not permit publishing renders'; end if;
  if v_job.capture_asset_id is not null and not public.studio_presenter_media_access(v_job.capture_asset_id) then raise exception 'RP409: Presenter source approval is no longer available'; end if;
  if p_poster_asset is not null then
    select a.* into v_poster from capture_assets a where a.id = p_poster_asset;
    if not found or v_poster.listing_id <> v_job.listing_id or coalesce(v_poster.bucket,'uploads') <> 'renders' or v_poster.uploaded is not true or v_poster.kind <> 'photo' then
      raise exception 'RP400: poster_asset_id must be an uploaded photo in the renders bucket for this listing';
    end if;
    v_poster_key := v_poster.storage_key;
  end if;

  -- One publish at a time per listing; the per-job lock publish_render takes is
  -- also taken so the two cannot interleave on the same job.
  perform pg_advisory_xact_lock(hashtextextended('republish_render:' || v_job.listing_id::text, 42));
  perform pg_advisory_xact_lock(hashtextextended('publish_render:' || p_job::text, 42));

  -- Replay: this job already carries the live render.
  select r.* into v_render from renders r where r.job_id = p_job;
  if found then
    if v_poster_key is not null and v_render.poster_key is null then
      update renders set poster_key = v_poster_key where id = v_render.id returning * into v_render;
    end if;
    return v_render;
  end if;

  -- The listing's current public tour. None → an ordinary first publish.
  select r.* into v_current from renders r where r.listing_id = v_job.listing_id and r.published_at is not null order by r.published_at desc, r.created_at desc limit 1;
  if not found then
    return public.publish_render(p_job, p_duration, p_speed, p_chapters, p_poster_asset);
  end if;

  if v_job.capture_asset_id is null then raise exception 'RP400: job has no capture asset'; end if;
  select a.* into v_asset from capture_assets a where a.id = v_job.capture_asset_id;
  if not found then raise exception 'RP404: capture asset not found'; end if;
  if coalesce(v_asset.bucket,'uploads') <> 'renders' then raise exception 'RP400: the job asset is not a role=render upload'; end if;
  if v_asset.uploaded is not true then raise exception 'RP409: the render upload is not complete'; end if;
  v_dur := coalesce(p_duration, v_asset.duration_s);
  if v_dur is null or v_dur <= 0 or v_dur > 7200 then raise exception 'RP400: duration_s is required (0 < s <= 7200)'; end if;

  -- Same server-derived disclosure rule as publish_render (see its comment).
  v_style := lower(trim(coalesce(v_job.enhancements->>'style', '')));
  if v_job.enhancement_result is not null and v_job.enhancement_result ? 'staged' then
    v_staged := coalesce((v_job.enhancement_result->>'staged')::boolean, false);
  elsif coalesce(v_job.source, 'worker') = 'app' then
    v_staged := false;
  else
    v_staged := coalesce((v_job.enhancements->>'declutter')::boolean, false) or (v_style <> '' and v_style not in ('as_is','as-is','asis','none'));
  end if;

  perform replace_asset_chapters(v_asset.id, p_chapters);

  -- The slug, the row and the first published_at stay; the media behind them moves.
  update renders set job_id = v_job.id, duration_s = v_dur, speed_factor = greatest(0.25, least(8.0, coalesce(p_speed, 2.0))),
    video_key = v_asset.storage_key, stream_uid = null, poster_key = coalesce(v_poster_key, poster_key), staged = v_staged
   where id = v_current.id returning * into v_render;

  update render_jobs set status = 'ready', progress = 1, finished_at = now(), error = null where id = v_job.id;
  update listings set status = 'ready' where id = v_job.listing_id;
  return v_render;
end;
$function$;
revoke all on function public.republish_render(uuid,numeric,numeric,jsonb,uuid) from public,anon;
grant execute on function public.republish_render(uuid,numeric,numeric,jsonb,uuid) to authenticated,service_role;

commit;
