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

commit;
