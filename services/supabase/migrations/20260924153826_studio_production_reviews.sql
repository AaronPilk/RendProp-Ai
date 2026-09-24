-- Review authority is never accepted inside the author-editable document payload.
-- Existing document revisions remain the sole source of reel content.
begin;
alter table public.studio_documents drop constraint if exists studio_documents_kind_check;
alter table public.studio_documents add constraint studio_documents_kind_check
  check (kind in ('edit','planner','creative','native','production'));

create table if not exists public.studio_production_reviews (
  document_user_id uuid not null,
  org_id uuid not null,
  document_key text not null,
  listing_id uuid not null references public.listings(id) on delete cascade,
  revision integer not null check (revision > 0),
  document_revision integer not null check (document_revision > 0),
  status text not null check (status in ('draft','in_review','changes_requested','approved')),
  events jsonb not null default '[]' check (jsonb_typeof(events)='array' and jsonb_array_length(events)<=250 and octet_length(events::text)<=1048576),
  submitted_at timestamptz,
  updated_at timestamptz not null default now(),
  primary key (document_user_id,org_id,document_key),
  foreign key (document_user_id,org_id,document_key) references public.studio_documents(user_id,org_id,key) on delete cascade,
  check (document_key='edit:'||listing_id::text)
);
create index if not exists studio_production_reviews_queue on public.studio_production_reviews(org_id,updated_at desc,document_user_id,document_key);
alter table public.studio_production_reviews enable row level security;
-- No public table policy: only checked invoker RPCs called by the authenticated
-- Edge handler's service client can access review authority. No SECURITY DEFINER.
revoke all on public.studio_production_reviews from public,anon,authenticated;
grant select,insert,update,delete on public.studio_production_reviews to service_role;

-- Do not give service_role general access to Auth tables. This narrow predicate
-- reads only named-account/deletion state, never email or provider identities.
create or replace function public.studio_review_named_account(p_user uuid)
returns boolean language plpgsql stable security definer set search_path='' as $$
begin
  if current_setting('role',true) is distinct from 'service_role' then
    raise insufficient_privilege using message='service role required';
  end if;
  return exists(select 1 from auth.users where id=p_user and is_anonymous is false)
    and not exists(select 1 from public.deletion_requests where user_id=p_user and status in ('pending','processing'));
end;
$$;
revoke all on function public.studio_review_named_account(uuid) from public,anon,authenticated;
grant execute on function public.studio_review_named_account(uuid) to service_role;

create or replace function public.studio_review_permissions(p_actor uuid,p_author uuid,p_listing_agent uuid,p_role text,p_status text)
returns jsonb language sql immutable security invoker set search_path='' as $$
 select jsonb_build_object(
   'can_submit',p_actor=p_author and p_role in ('owner','admin','agent') and p_status<>'in_review',
   'can_withdraw',p_actor=p_author and p_role in ('owner','admin','agent') and p_status<>'draft',
   'can_comment',p_role in ('owner','admin','agent') and (p_actor=p_author or p_status<>'draft'),
   'can_request_changes',p_role in ('owner','admin','agent') and p_status in ('in_review','approved'),
   'can_approve',(p_role in ('owner','admin') or (p_role='agent' and p_actor=p_listing_agent)) and p_status='in_review'
 );
$$;
revoke all on function public.studio_review_permissions(uuid,uuid,uuid,text,text) from public,anon,authenticated;
grant execute on function public.studio_review_permissions(uuid,uuid,uuid,text,text) to service_role;

create or replace function public.studio_review_invalidate()
returns trigger language plpgsql security invoker set search_path='' as $$
begin
  if old.kind='edit' and old.key like 'edit:%' and
    (new.revision is distinct from old.revision or new.payload is distinct from old.payload or new.listing_id is distinct from old.listing_id or new.kind is distinct from old.kind) then
    if new.revision<=old.revision then raise exception 'RP409: Saved reel revisions must increase'; end if;
    -- The source UPDATE already owns its document lock, matching review RPC lock
    -- order. Approval cannot race past this reset. Old comments retain old revs.
    update public.studio_production_reviews set status='draft',document_revision=new.revision,
      revision=revision+1,updated_at=clock_timestamp()
      where document_user_id=old.user_id and org_id=old.org_id and document_key=old.key;
  end if;
  return new;
end;
$$;
revoke all on function public.studio_review_invalidate() from public,anon,authenticated;
grant execute on function public.studio_review_invalidate() to service_role;
drop trigger if exists studio_review_invalidate on public.studio_documents;
create trigger studio_review_invalidate before update on public.studio_documents
for each row execute function public.studio_review_invalidate();

-- Immutable snapshots are retained for explicit submissions and before a
-- recipient replaces their current draft. No automatic edit-history churn.
create table if not exists public.studio_production_versions (
  id uuid primary key default gen_random_uuid(),
  document_user_id uuid not null,
  org_id uuid not null,
  document_key text not null,
  listing_id uuid not null references public.listings(id) on delete cascade,
  document_revision integer not null check(document_revision>0),
  reason text not null check(reason in ('submitted','before_replace')),
  brief jsonb check(brief is null or (jsonb_typeof(brief)='object' and octet_length(brief::text)<=131072)),
  payload jsonb not null check(jsonb_typeof(payload)='object' and octet_length(payload::text)<=2097152),
  created_at timestamptz not null default clock_timestamp(),
  unique(document_user_id,org_id,document_key,document_revision),
  foreign key(document_user_id,org_id,document_key) references public.studio_documents(user_id,org_id,key) on delete cascade,
  check(document_key='edit:'||listing_id::text)
);
alter table public.studio_production_versions enable row level security;
revoke all on public.studio_production_versions from public,anon,authenticated,service_role;
grant select,insert on public.studio_production_versions to service_role;
create or replace function public.studio_production_version_metadata(v public.studio_production_versions)
returns jsonb language sql immutable security invoker set search_path='' as $$
 select jsonb_build_object('id',v.id,'document_user_id',v.document_user_id,'org_id',v.org_id,'key',v.document_key,
 'listing_id',v.listing_id,'document_revision',v.document_revision,'reason',v.reason,'created_at',v.created_at);
$$;
revoke all on function public.studio_production_version_metadata(public.studio_production_versions) from public,anon,authenticated;
grant execute on function public.studio_production_version_metadata(public.studio_production_versions) to service_role;

create or replace function public.studio_production_review(
  p_actor uuid,p_org_id uuid,p_document_user_id uuid,p_key text,p_action text default 'get',
  p_expected_document_revision integer default null,p_expected_review_revision integer default null,
  p_message text default null,p_position_ms integer default null
) returns jsonb language plpgsql security invoker set search_path='' as $$
declare d public.studio_documents%rowtype; r public.studio_production_reviews%rowtype;
  v_role text; v_agent uuid; v_listing uuid; v_permissions jsonb; v_status text;
  v_event jsonb; v_review jsonb; v_document jsonb; v_now timestamptz:=clock_timestamp();
begin
  if p_key is null or p_key !~ '^edit:[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
    or p_action is null or p_action not in ('get','submit','comment','request_changes','approve','withdraw') then
    raise exception 'RP400: Choose a saved property reel and review action';
  end if;
  v_listing:=substring(p_key from 6)::uuid;
  if not public.studio_review_named_account(p_actor) then
    raise exception 'RP403: Your named account is unavailable';
  end if;
  select role into v_role from public.memberships where user_id=p_actor and org_id=p_org_id for share;
  if v_role is null then raise exception 'RP403: Workspace membership is required'; end if;
  perform 1 from public.orgs where id=p_org_id and deleted_at is null for share;
  if not found then raise exception 'RP404: Workspace is unavailable'; end if;
  select agent_id into v_agent from public.listings where id=v_listing and org_id=p_org_id and deleted_at is null for share;
  if not found then raise exception 'RP404: Property is unavailable'; end if;
  perform 1 from public.memberships m
    where m.user_id=p_document_user_id and m.org_id=p_org_id and public.studio_review_named_account(m.user_id)
    for share of m;
  if not found then raise exception 'RP404: Saved reel is unavailable'; end if;
  select * into d from public.studio_documents where user_id=p_document_user_id and org_id=p_org_id and key=p_key
    and kind='edit' and listing_id=v_listing for update;
  if not found then raise exception 'RP404: Save this property reel before requesting review'; end if;
  select * into r from public.studio_production_reviews where document_user_id=p_document_user_id and org_id=p_org_id and document_key=p_key for update;
  if p_actor<>p_document_user_id and r.submitted_at is null then raise exception 'RP404: This private reel has not been submitted'; end if;
  v_status:=coalesce(r.status,'draft');
  v_permissions:=public.studio_review_permissions(p_actor,p_document_user_id,v_agent,v_role,v_status);
  if p_action<>'get' then
    if p_expected_document_revision is null or p_expected_review_revision is null or p_expected_document_revision<1 or p_expected_review_revision<0 then
      raise exception 'RP400: Refresh saved reel and review revisions before changing them';
    end if;
    if p_expected_document_revision<>d.revision or p_expected_review_revision<>coalesce(r.revision,0) then
      raise exception 'RP409: This reel or review changed. Reload before continuing';
    end if;
    if coalesce((v_permissions->>('can_'||p_action))::boolean,false) is not true then
      raise exception 'RP403: Your role cannot perform this action in the current review state';
    end if;
    if p_message is not null and length(p_message)>2000 then
      raise exception 'RP400: Review comments must be 2000 characters or fewer';
    end if;
    if p_action in ('comment','request_changes') and coalesce(length(btrim(p_message)),0)=0 then
      raise exception 'RP400: Add a comment explaining the requested change';
    end if;
    if p_position_ms is not null and (p_position_ms<0 or p_position_ms>180000) then
      raise exception 'RP400: Comment time must be within the supported reel duration';
    end if;
    if jsonb_array_length(coalesce(r.events,'[]'::jsonb))>=250 then raise exception 'RP409: This review has reached its history limit'; end if;
    v_status:=case p_action when 'submit' then 'in_review' when 'approve' then 'approved' when 'request_changes' then 'changes_requested' when 'withdraw' then 'draft' else v_status end;
    v_event:=jsonb_build_object('id',gen_random_uuid(),'action',p_action,'author_id',p_actor,'created_at',v_now,
      'document_revision',d.revision,'message',nullif(btrim(p_message),''),'position_ms',p_position_ms);
    insert into public.studio_production_reviews(document_user_id,org_id,document_key,listing_id,revision,document_revision,status,events,submitted_at,updated_at)
      values(p_document_user_id,p_org_id,p_key,v_listing,coalesce(r.revision,0)+1,d.revision,v_status,coalesce(r.events,'[]'::jsonb)||jsonb_build_array(v_event),
        case when p_action='submit' then v_now else r.submitted_at end,v_now)
      on conflict(document_user_id,org_id,document_key) do update set revision=excluded.revision,document_revision=excluded.document_revision,
        status=excluded.status,events=excluded.events,submitted_at=excluded.submitted_at,updated_at=excluded.updated_at returning * into r;
    if p_action='submit' then
      insert into public.studio_production_versions(document_user_id,org_id,document_key,listing_id,document_revision,reason,payload,brief)
        values(d.user_id,d.org_id,d.key,d.listing_id,d.revision,'submitted',d.payload,(select payload from public.studio_documents where user_id=d.user_id and org_id=d.org_id and key='production:'||d.listing_id::text and kind='production' and listing_id=d.listing_id)) on conflict(document_user_id,org_id,document_key,document_revision) do nothing;
      if not exists(select 1 from public.studio_production_versions v where v.document_user_id=d.user_id and v.org_id=d.org_id
        and v.document_key=d.key and v.document_revision=d.revision and v.payload=d.payload and v.reason='submitted') then
        raise exception 'RP409: This saved revision has a different immutable version';
      end if;
    end if;
    v_permissions:=public.studio_review_permissions(p_actor,p_document_user_id,v_agent,v_role,v_status);
  end if;
  v_review:=jsonb_build_object('document_user_id',d.user_id,'org_id',d.org_id,'key',d.key,'listing_id',d.listing_id,
    'revision',coalesce(r.revision,0),'document_revision',d.revision,'status',v_status,'events',coalesce(r.events,'[]'::jsonb),
    'submitted_at',r.submitted_at,'updated_at',coalesce(r.updated_at,d.updated_at));
  -- New edits are private again. A prior submission only grants metadata/history
  -- access until the author explicitly submits the new saved revision.
  if p_actor=d.user_id or (v_status<>'draft' and r.document_revision=d.revision) then
    v_document:=jsonb_build_object('key',d.key,'kind',d.kind,'listing_id',d.listing_id,'revision',d.revision,'payload',d.payload,'updated_at',d.updated_at);
  end if;
  return jsonb_build_object('review',v_review,'document',v_document,'permissions',v_permissions,'source_revision',d.revision,
    'brief',(select v.brief from public.studio_production_versions v where v.document_user_id=d.user_id and v.org_id=d.org_id and v.document_key=d.key and v.document_revision=d.revision and v.reason='submitted'));
end;
$$;
revoke all on function public.studio_production_review(uuid,uuid,uuid,text,text,integer,integer,text,integer) from public,anon,authenticated;
grant execute on function public.studio_production_review(uuid,uuid,uuid,text,text,integer,integer,text,integer) to service_role;

create or replace function public.studio_production_review_queue(p_actor uuid,p_org_id uuid,p_listing_id uuid default null,p_offset integer default 0)
returns jsonb language plpgsql security invoker set search_path='' as $$
declare v_role text; v_rows jsonb;
begin
  if p_offset is null or p_offset<0 or p_offset>10000 or p_offset%50<>0 then raise exception 'RP400: Invalid review queue page'; end if;
  if not public.studio_review_named_account(p_actor) then
    raise exception 'RP403: Your named account is unavailable';
  end if;
  select m.role into v_role from public.memberships m join public.orgs o on o.id=m.org_id and o.deleted_at is null
    where m.user_id=p_actor and m.org_id=p_org_id;
  if v_role is null then raise exception 'RP403: Workspace membership is required'; end if;
  if p_listing_id is not null and not exists(select 1 from public.listings where id=p_listing_id and org_id=p_org_id and deleted_at is null) then
    raise exception 'RP404: Property is unavailable';
  end if;
  select coalesce(jsonb_agg(x.value order by x.updated_at desc,x.author,x.key),'[]'::jsonb) into v_rows from (
    select jsonb_build_object('review',jsonb_build_object('document_user_id',r.document_user_id,'org_id',r.org_id,'key',r.document_key,'listing_id',r.listing_id,
      'revision',r.revision,'document_revision',d.revision,'status',r.status,'submitted_at',r.submitted_at,'updated_at',r.updated_at,
      'events','[]'::jsonb,'event_count',jsonb_array_length(r.events)),'source_revision',d.revision,
      'permissions',public.studio_review_permissions(p_actor,d.user_id,l.agent_id,v_role,r.status)) as value,
      r.updated_at,r.document_user_id as author,r.document_key as key
    from public.studio_production_reviews r
    join public.studio_documents d on d.user_id=r.document_user_id and d.org_id=r.org_id and d.key=r.document_key and d.listing_id=r.listing_id and d.kind='edit'
    join public.listings l on l.id=r.listing_id and l.org_id=r.org_id and l.deleted_at is null
    join public.memberships m on m.user_id=d.user_id and m.org_id=d.org_id
    where r.org_id=p_org_id and (p_listing_id is null or r.listing_id=p_listing_id)
      and (r.submitted_at is not null or r.document_user_id=p_actor)
      and public.studio_review_named_account(d.user_id)
    order by r.updated_at desc,r.document_user_id,r.document_key limit 51 offset p_offset
  ) x;
  if jsonb_array_length(v_rows)>50 and p_offset=10000 then raise exception 'RP422: Review queue is too large to load completely'; end if;
  return jsonb_build_object('reviews',(select coalesce(jsonb_agg(value),'[]'::jsonb) from jsonb_array_elements(v_rows) with ordinality x(value,n) where n<=50),
    'next_offset',case when jsonb_array_length(v_rows)>50 then p_offset+50 else null end);
end;
$$;
revoke all on function public.studio_production_review_queue(uuid,uuid,uuid,integer) from public,anon,authenticated;
grant execute on function public.studio_production_review_queue(uuid,uuid,uuid,integer) to service_role;

create or replace function public.studio_production_versions_read(p_actor uuid,p_org_id uuid,p_document_user_id uuid,p_key text,p_document_revision integer default null,p_offset integer default 0)
returns jsonb language plpgsql security invoker set search_path='' as $$
declare v public.studio_production_versions%rowtype; rows jsonb;
begin
  -- Reuse live account/org/listing/author checks, including private draft gate.
  perform public.studio_production_review(p_actor,p_org_id,p_document_user_id,p_key);
  if p_offset is null or p_offset<0 or p_offset>10000 or p_offset%50<>0 then raise exception 'RP400: Invalid version history page'; end if;
  if p_document_revision is not null then
    if p_document_revision<1 then raise exception 'RP400: Choose a saved version'; end if;
    select * into v from public.studio_production_versions where document_user_id=p_document_user_id and org_id=p_org_id and document_key=p_key
      and document_revision=p_document_revision and (p_actor=p_document_user_id or reason='submitted');
    if not found then raise exception 'RP404: This saved version is unavailable'; end if;
    return jsonb_build_object('version',public.studio_production_version_metadata(v),'brief',v.brief,'document',jsonb_build_object('key',v.document_key,
      'kind','edit','listing_id',v.listing_id,'revision',v.document_revision,'payload',v.payload,'updated_at',v.created_at));
  end if;
  select coalesce(jsonb_agg(x.value order by x.rev desc),'[]'::jsonb) into rows from (
    select public.studio_production_version_metadata(entry) as value,entry.document_revision as rev from public.studio_production_versions entry
    where entry.document_user_id=p_document_user_id and entry.org_id=p_org_id and entry.document_key=p_key and (p_actor=p_document_user_id or entry.reason='submitted')
    order by entry.document_revision desc limit 51 offset p_offset
  ) x;
  if jsonb_array_length(rows)>50 and p_offset=10000 then raise exception 'RP422: Version history is too large to load completely'; end if;
  return jsonb_build_object('versions',(select coalesce(jsonb_agg(value order by n),'[]'::jsonb) from jsonb_array_elements(rows) with ordinality x(value,n) where n<=50),
    'next_offset',case when jsonb_array_length(rows)>50 then p_offset+50 else null end);
end;
$$;
revoke all on function public.studio_production_versions_read(uuid,uuid,uuid,text,integer,integer) from public,anon,authenticated;
grant execute on function public.studio_production_versions_read(uuid,uuid,uuid,text,integer,integer) to service_role;

create or replace function public.studio_review_media_key(p_key text,p_org uuid,p_listing uuid)
returns boolean language sql immutable security invoker set search_path='' as $$
 select coalesce(length(p_key) between 1 and 1024 and strpos(p_key,chr(92))=0 and p_key !~ '[%?#[:cntrl:]]'
   and not exists(select 1 from unnest(string_to_array(p_key,'/')) s where s in ('','.','..'))
   and (starts_with(p_key,'uploads/'||p_org::text||'/'||p_listing::text||'/') or starts_with(p_key,'renders/'||p_org::text||'/'||p_listing::text||'/')),false);
$$;
revoke all on function public.studio_review_media_key(text,uuid,uuid) from public,anon,authenticated;
grant execute on function public.studio_review_media_key(text,uuid,uuid) to service_role;

create or replace function public.studio_production_copy(p_actor uuid,p_org_id uuid,p_document_user_id uuid,p_key text,p_document_revision integer,p_expected_target_revision integer)
returns jsonb language plpgsql security invoker set search_path='' as $$
declare source public.studio_production_versions%rowtype; target public.studio_documents%rowtype;
  preserved public.studio_production_versions%rowtype; voice public.studio_creative_results%rowtype;
  v_listing uuid; v_role text; v_payload jsonb; item jsonb; media jsonb; v_asset uuid; v_kind text;
  v_voice_id uuid; v_alias uuid; v_now timestamptz:=clock_timestamp();
begin
  if p_key is null or p_key !~ '^edit:[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
    or p_document_revision is null or p_document_revision<1 or p_expected_target_revision is null or p_expected_target_revision<0 or p_expected_target_revision>=2147483647 then
    raise exception 'RP400: Choose a saved version and the current target revision';
  end if;
  v_listing:=substring(p_key from 6)::uuid;
  if not public.studio_review_named_account(p_actor) then raise exception 'RP403: Your named account is unavailable'; end if;
  select role into v_role from public.memberships where user_id=p_actor and org_id=p_org_id for share;
  if v_role is null or v_role not in ('owner','admin','agent') then raise exception 'RP403: Your role cannot make an editable copy'; end if;
  perform 1 from public.orgs where id=p_org_id and deleted_at is null for share;
  if not found then raise exception 'RP404: Workspace is unavailable'; end if;
  perform 1 from public.listings where id=v_listing and org_id=p_org_id and deleted_at is null for share;
  if not found then raise exception 'RP404: Property is unavailable'; end if;
  perform 1 from public.memberships where user_id=p_document_user_id and org_id=p_org_id and public.studio_review_named_account(user_id) for share;
  if not found then raise exception 'RP404: The source author is unavailable'; end if;
  -- Deterministic ordering prevents reciprocal reviewer copies deadlocking.
  perform 1 from public.studio_documents where org_id=p_org_id and key=p_key and user_id in (p_actor,p_document_user_id) order by user_id for update;
  if not exists(select 1 from public.studio_documents where user_id=p_document_user_id and org_id=p_org_id and key=p_key and kind='edit' and listing_id=v_listing) then
    raise exception 'RP404: This saved source is unavailable';
  end if;
  select * into source from public.studio_production_versions where document_user_id=p_document_user_id and org_id=p_org_id and document_key=p_key
    and listing_id=v_listing and document_revision=p_document_revision and (p_actor=p_document_user_id or reason='submitted');
  if not found then raise exception 'RP404: This saved version is unavailable'; end if;
  select * into target from public.studio_documents where user_id=p_actor and org_id=p_org_id and key=p_key;
  if coalesce(target.revision,0)<>p_expected_target_revision then raise exception 'RP409: Your current draft changed. Reload before making this copy'; end if;
  if target.key is not null and (target.kind<>'edit' or target.listing_id<>v_listing) then raise exception 'RP409: The target draft has a different property binding'; end if;
  v_payload:=source.payload;
  if v_payload->>'listingId' is distinct from v_listing::text or jsonb_typeof(v_payload->'draft') is distinct from 'object'
    or jsonb_typeof(v_payload->'sources') is distinct from 'array' or jsonb_typeof(v_payload#>'{draft,clips}') is distinct from 'array'
    or (v_payload#>'{draft,overlays}' is not null and jsonb_typeof(v_payload#>'{draft,overlays}') is distinct from 'array') then
    raise exception 'RP400: The saved reel has an invalid edit or source list';
  end if;
  if jsonb_array_length(v_payload->'sources')>24 or jsonb_array_length(v_payload#>'{draft,clips}')>12
    or jsonb_array_length(coalesce(v_payload#>'{draft,overlays}','[]'))>12 then
    raise exception 'RP400: The saved reel exceeds supported source limits';
  end if;
  for media in select value from jsonb_array_elements((v_payload#>'{draft,clips}')||coalesce(v_payload#>'{draft,overlays}','[]')) loop
    if coalesce(media#>>'{source,sha256}','') !~ '^[0-9a-f]{64}$' or coalesce(media#>>'{source,kind}','') not in ('image','video')
      or not exists(select 1 from jsonb_array_elements(v_payload->'sources') s where s->>'sha256'=media#>>'{source,sha256}') then
      raise exception 'RP422: Upload every original file before handing off this reel';
    end if;
  end loop;
  for item in select value from jsonb_array_elements(v_payload->'sources') loop
    if item->>'listingId' is distinct from v_listing::text or coalesce(item->>'assetId','') !~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
      or coalesce(item->>'sha256','') !~ '^[0-9a-f]{64}$' then raise exception 'RP400: A saved source belongs to another property'; end if;
    v_asset:=(item->>'assetId')::uuid;
    -- References not used by the current cut still need valid listing ownership.
    if not exists(select 1 from public.capture_assets a where a.id=v_asset and a.listing_id=v_listing and a.uploaded
      and public.studio_review_media_key(a.storage_key,p_org_id,v_listing) and starts_with(a.storage_key,a.bucket||'/'))
      and not exists(select 1 from public.photos p where p.id=v_asset and p.listing_id=v_listing and
        (public.studio_review_media_key(p.original_key,p_org_id,v_listing) or public.studio_review_media_key(p.enhanced_key,p_org_id,v_listing)))
      and not exists(select 1 from public.renders r where r.id=v_asset and r.listing_id=v_listing and public.studio_review_media_key(r.video_key,p_org_id,v_listing)) then
      raise exception 'RP422: An original file is no longer available in this property';
    end if;
    for media in select value from jsonb_array_elements((v_payload#>'{draft,clips}')||coalesce(v_payload#>'{draft,overlays}','[]')) where value#>>'{source,sha256}'=item->>'sha256' loop
      v_kind:=case media#>>'{source,kind}' when 'image' then 'photo' else 'video' end;
      if not exists(select 1 from public.capture_assets a where a.id=v_asset and a.listing_id=v_listing and a.kind=v_kind and a.uploaded)
        and not (v_kind='photo' and exists(select 1 from public.photos p where p.id=v_asset and p.listing_id=v_listing))
        and not (v_kind='video' and exists(select 1 from public.renders r where r.id=v_asset and r.listing_id=v_listing)) then
        raise exception 'RP422: A saved source has a different media type';
      end if;
    end loop;
  end loop;
  if v_payload#>'{draft,narration}' is not null and v_payload#>'{draft,narration}'<>'null'::jsonb then
    if coalesce(v_payload#>>'{draft,narration,resultId}','') !~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then raise exception 'RP400: The saved narration reference is invalid'; end if;
    v_voice_id:=(v_payload#>>'{draft,narration,resultId}')::uuid;
    select * into voice from public.studio_creative_results where id=v_voice_id and user_id=p_document_user_id and org_id=p_org_id and listing_id=v_listing and kind='voice' for share;
    if not found or voice.metadata->>'state' is distinct from 'completed' or voice.bucket is distinct from 'uploads'
      or voice.storage_key is null or voice.storage_key !~ ('^ai-voice/'||p_org_id::text||'/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}[.]mp3$') then
      raise exception 'RP422: The saved narration is no longer available for handoff';
    end if;
    if p_actor<>p_document_user_id then
      v_alias:=gen_random_uuid();
      insert into public.studio_creative_results(id,user_id,org_id,listing_id,kind,storage_key,bucket,provenance_id,request_key,metadata)
        values(v_alias,p_actor,p_org_id,v_listing,'voice',voice.storage_key,'uploads',voice.provenance_id,'review-copy:'||v_alias::text,
          (voice.metadata-'request_id')||jsonb_build_object('copied_from_result_id',voice.id,'copied_from_version_id',source.id));
      v_payload:=jsonb_set(v_payload,'{draft,narration,resultId}',to_jsonb(v_alias::text));
    end if;
  end if;
  if target.key is not null then
    insert into public.studio_production_versions(document_user_id,org_id,document_key,listing_id,document_revision,reason,payload,brief)
      values(target.user_id,target.org_id,target.key,target.listing_id,target.revision,'before_replace',target.payload,(select payload from public.studio_documents where user_id=target.user_id and org_id=target.org_id and key='production:'||target.listing_id::text and kind='production' and listing_id=target.listing_id))
      on conflict(document_user_id,org_id,document_key,document_revision) do nothing;
    select * into preserved from public.studio_production_versions where document_user_id=target.user_id and org_id=target.org_id and document_key=target.key and document_revision=target.revision;
    if preserved.payload is distinct from target.payload then raise exception 'RP409: The current draft conflicts with its immutable version'; end if;
    update public.studio_documents set revision=target.revision+1,payload=v_payload,updated_at=v_now where user_id=p_actor and org_id=p_org_id and key=p_key returning * into target;
  else
    begin
      insert into public.studio_documents(user_id,org_id,key,kind,listing_id,revision,payload,updated_at)
        values(p_actor,p_org_id,p_key,'edit',v_listing,1,v_payload,v_now) returning * into target;
    exception when unique_violation then raise exception 'RP409: Your current draft changed. Reload before making this copy'; end;
  end if;
  return jsonb_build_object('document',jsonb_build_object('key',target.key,'kind',target.kind,'listing_id',target.listing_id,'revision',target.revision,'payload',target.payload,'updated_at',target.updated_at),
    'source_version',public.studio_production_version_metadata(source)||jsonb_build_object('brief',source.brief),
    'preserved_version',case when preserved.id is not null then public.studio_production_version_metadata(preserved) else null end);
end;
$$;
revoke all on function public.studio_production_copy(uuid,uuid,uuid,text,integer,integer) from public,anon,authenticated;
grant execute on function public.studio_production_copy(uuid,uuid,uuid,text,integer,integer) to service_role;

commit;
