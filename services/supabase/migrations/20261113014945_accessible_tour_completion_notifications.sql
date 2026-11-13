-- Preserve the worker publisher's owner/admin recipient policy, intersected
-- with current listing access. A Team seat is not shared-library authority.
begin;
set local lock_timeout = '5s';
set local statement_timeout = '60s';

do $patch$
declare
  signature regprocedure := 'public.publish_worker_render(uuid,text,integer,jsonb,jsonb,jsonb)'::regprocedure;
  body text;
  definition text;
  old_query text := '       where m.org_id = v_listing.org_id and m.role in (''owner'',''admin'')';
  new_query text;
begin
  if not exists (
    select 1 from pg_catalog.pg_proc p where p.oid = signature
      and p.proowner = 'postgres'::regrole and not p.prosecdef
      and p.proconfig = array['search_path=""']::text[]
      and p.proacl::text = '{postgres=X/postgres,service_role=X/postgres}'
  ) then
    raise exception 'Worker publication security or grants changed; review notification adoption';
  end if;
  select prosrc, pg_catalog.pg_get_functiondef(oid) into strict body, definition
    from pg_catalog.pg_proc where oid = signature;
  if md5(body) = '31df14b830c092d0b22ea1f8bf94f4c7' then return; end if;
  if md5(body) <> 'bde4637bd3f1e50fbe3323f0e084b1f0'
     or (length(body) - length(replace(body, old_query, ''))) / length(old_query) <> 1 then
    raise exception 'Worker publication predecessor changed; review notification adoption';
  end if;
  new_query := old_query || E'\n         and public.listing_content_access(m.user_id, v_listing.id, false)';
  execute replace(definition, old_query, new_query);
  if (select md5(prosrc) from pg_catalog.pg_proc where oid = signature)
       <> '31df14b830c092d0b22ea1f8bf94f4c7' then
    raise exception 'Worker publication notification patch did not match the reviewed body';
  end if;
end
$patch$;

-- The dispatcher supplies its claimed routing facts, so a changed outbox row
-- cannot authorize delivery of an earlier snapshot. No caller-supplied identity
-- grants access: both the saved row and current publication must agree.
create or replace function public.tour_notification_current(p_outbox uuid, p_expected jsonb)
returns boolean
language plpgsql
stable
security definer
set search_path = ''
as $function$
declare
  notice public.notification_outbox;
  facts jsonb;
  published public.renders;
  listing public.listings;
  expected jsonb;
  uuid_pattern constant text := '^[a-fA-F0-9]{8}(-[a-fA-F0-9]{4}){3}-[a-fA-F0-9]{12}$';
begin
  if current_setting('role', true) is distinct from 'service_role' then
    raise insufficient_privilege using message = 'service role required';
  end if;
  if p_outbox is null or jsonb_typeof(p_expected) is distinct from 'object'
     or octet_length(p_expected::text) > 4096 then return false; end if;
  select * into notice from public.notification_outbox where id = p_outbox;
  if notice.id is null or notice.category <> 'render_ready' or notice.state <> 'sending'
     or notice.channel not in ('push', 'email') or notice.user_id is null or notice.org_id is null
     or jsonb_typeof(notice.payload) is distinct from 'object' then return false; end if;
  facts := notice.payload -> 'data';
  if jsonb_typeof(facts) is distinct from 'object'
     or facts ?| array['property_video_job_id', 'reel_job_id', 'lead_id', 'workspace_id']
     or jsonb_typeof(facts -> 'render_id') is distinct from 'string'
     or jsonb_typeof(facts -> 'listing_id') is distinct from 'string'
     or jsonb_typeof(facts -> 'slug') is distinct from 'string'
     or (facts ->> 'render_id') !~ uuid_pattern or (facts ->> 'listing_id') !~ uuid_pattern
     or (facts ->> 'slug') !~ '^[A-Za-z0-9_-]{1,128}$'
     or jsonb_typeof(notice.payload -> 'deep_link') is distinct from 'string'
     or notice.payload ->> 'deep_link' <> '/f/' || (facts ->> 'slug') then return false; end if;

  select * into published from public.renders where id = (facts ->> 'render_id')::uuid;
  if published.id is null or published.published_at is null
     or published.listing_id <> (facts ->> 'listing_id')::uuid
     or published.slug <> (facts ->> 'slug') then return false; end if;
  select * into listing from public.listings where id = published.listing_id;
  if listing.id is null or listing.deleted_at is not null or listing.org_id <> notice.org_id
     or not public.listing_content_access(notice.user_id, listing.id, false) then return false; end if;

  expected := jsonb_build_object('outbox_id', notice.id, 'org_id', notice.org_id,
    'recipient_user_id', notice.user_id, 'render_id', published.id,
    'listing_id', listing.id, 'slug', published.slug, 'deep_link', '/f/' || published.slug);
  return p_expected = expected;
end
$function$;
revoke all on function public.tour_notification_current(uuid, jsonb) from public, anon, authenticated;
grant execute on function public.tour_notification_current(uuid, jsonb) to service_role;
comment on function public.tour_notification_current(uuid, jsonb) is
  'Service-only claimed tour notification access and exact route recheck; private video jobs use their own actor-scoped authority.';

-- Keep notification_outbox SELECT-only for service_role. The only fallback
-- write capability derives its twin from an exact, locked, still-owned claim.
create or replace function public.notification_email_fallback_enqueue(
  p_push uuid, p_attempt integer, p_expected jsonb, p_reason text
) returns text
language plpgsql security definer set search_path = ''
as $fallback$
declare
  notice public.notification_outbox;
  twin public.notification_outbox;
  facts jsonb;
  scope jsonb;
  permitted boolean := false;
  inserted uuid;
  uuid_pattern constant text := '^[a-fA-F0-9]{8}(-[a-fA-F0-9]{4}){3}-[a-fA-F0-9]{12}$';
begin
  if current_setting('role', true) is distinct from 'service_role' then
    raise insufficient_privilege using message = 'service role required';
  end if;
  if p_push is null or p_attempt is null or p_attempt < 1
     or jsonb_typeof(p_expected) is distinct from 'object'
     or p_reason is null or length(p_reason) > 500
     or not (p_reason = 'no live device for this user'
       or p_reason like 'every device token for this user was rejected by APNs%') then return 'stale'; end if;
  select * into notice from public.notification_outbox where id = p_push for update;
  if notice.id is null or notice.state <> 'sending' or notice.attempts <> p_attempt
     or notice.channel <> 'push' or notice.category not in ('lead_received','render_ready','upload_stuck')
     or notice.user_id is null or notice.org_id is null or notice.to_email is not null
     or p_expected is distinct from jsonb_build_object('outbox_id',notice.id,'org_id',notice.org_id,
       'recipient_user_id',notice.user_id,'category',notice.category,'channel',notice.channel,
       'dedupe_key',notice.dedupe_key,'payload',notice.payload,'to_email',notice.to_email) then return 'stale'; end if;
  facts := notice.payload -> 'data';
  if jsonb_typeof(facts) = 'object' then
    if notice.category = 'render_ready' and facts ? 'property_video_job_id' then
      if jsonb_typeof(facts->'property_video_job_id') = 'string' and (facts->>'property_video_job_id') ~ uuid_pattern
         and jsonb_typeof(facts->'reel_job_id') = 'string' and (facts->>'reel_job_id') ~ uuid_pattern
         and jsonb_typeof(facts->'listing_id') = 'string' and (facts->>'listing_id') ~ uuid_pattern
         and not facts ?| array['render_id','slug','lead_id','workspace_id']
         and (notice.payload->'deep_link' is null or notice.payload->'deep_link' = 'null'::jsonb) then
        if (facts->>'property_video_job_id')::uuid = (facts->>'reel_job_id')::uuid then
          permitted := exists(select 1 from public.property_video_jobs j
            where j.id=(facts->>'property_video_job_id')::uuid and j.actor_id=notice.user_id
            and j.org_id=notice.org_id and j.listing_id=(facts->>'listing_id')::uuid)
            and public.property_video_notification_current((facts->>'property_video_job_id')::uuid,notice.user_id);
        end if;
      end if;
    elsif notice.category = 'render_ready' then
      permitted := public.tour_notification_current(notice.id,jsonb_build_object('outbox_id',notice.id,
        'org_id',notice.org_id,'recipient_user_id',notice.user_id,'render_id',facts->>'render_id',
        'listing_id',facts->>'listing_id','slug',facts->>'slug','deep_link',notice.payload->>'deep_link'));
    elsif notice.category = 'lead_received' then
      if jsonb_typeof(facts->'lead_id') = 'string' and (facts->>'lead_id') ~ uuid_pattern
         and jsonb_typeof(facts->'listing_id') = 'string' and (facts->>'listing_id') ~ uuid_pattern then
        begin
          scope := public.lead_library_scope(notice.user_id,(facts->>'lead_id')::uuid);
          permitted := scope->>'actor_id'=notice.user_id::text and scope->>'lead_id'=facts->>'lead_id'
            and scope->>'listing_id'=facts->>'listing_id' and scope->>'org_id'=notice.org_id::text
            and scope->'can_read'='true'::jsonb;
        exception when raise_exception then
          if sqlerrm !~ '\mRP40[34]:' then raise; end if;
        end;
      end if;
    elsif notice.category = 'upload_stuck' then
      if jsonb_typeof(facts->'asset_id') = 'string' and (facts->>'asset_id') ~ uuid_pattern then
        permitted := exists(select 1 from public.upload_reservations r
          join public.memberships m on m.org_id=r.org_id and m.user_id=r.actor_id
          join public.orgs o on o.id=r.org_id and o.deleted_at is null
          where r.asset_id=(facts->>'asset_id')::uuid and r.actor_id=notice.user_id
          and r.org_id=notice.org_id and r.state='open' and r.expires_at<now());
      end if;
    end if;
  end if;
  if permitted is not true then
    perform public.notification_mark(notice.id,'skipped','Notification or account access changed before email fallback.',null);
    return 'denied';
  end if;
  begin
    insert into public.notification_outbox(org_id,user_id,category,channel,dedupe_key,payload)
      values(notice.org_id,notice.user_id,notice.category,'email',notice.dedupe_key||':email-fallback',notice.payload)
      on conflict(dedupe_key) do nothing returning id into inserted;
    select * into strict twin from public.notification_outbox
      where dedupe_key=notice.dedupe_key||':email-fallback' for update;
    if twin.org_id is distinct from notice.org_id or twin.user_id is distinct from notice.user_id
       or twin.category is distinct from notice.category or twin.channel <> 'email'
       or twin.payload is distinct from notice.payload or twin.to_email is not null
       or twin.client_delivery_id is not null or twin.client_verification_id is not null then
      raise exception 'Conflicting notification email fallback';
    end if;
    perform public.notification_mark(notice.id,'skipped',p_reason,null);
    return case when inserted is null then 'duplicate' else 'queued' end;
  exception when others then
    -- This subtransaction rolls a partial twin back. Failure marking happens
    -- while the same original claim lock is still held, never by ID-only JS.
    perform public.notification_mark(notice.id,'failed','Email fallback could not be queued ('||sqlstate||').',null);
    return 'retry';
  end;
end
$fallback$;
revoke all on function public.notification_email_fallback_enqueue(uuid,integer,jsonb,text) from public,anon,authenticated;
grant execute on function public.notification_email_fallback_enqueue(uuid,integer,jsonb,text) to service_role;

commit;
