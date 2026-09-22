-- Created with `supabase migration new upload_transport_budget`, then numbered
-- 0037 to match the repository's reserved migration order. No live application.
-- A reservation is not a refund counter: dispatch irrevocably consumes its
-- bytes, and only its still-held balance can be released exactly once.
alter table public.capture_assets add column if not exists transport_version smallint not null default 1;

create table if not exists public.upload_budget_windows (
  org_id uuid not null,
  day date not null,
  tickets integer not null default 0 check (tickets between 0 and 2000),
  held_bytes bigint not null default 0 check (held_bytes >= 0),
  spent_bytes bigint not null default 0 check (spent_bytes >= 0),
  primary key (org_id, day),
  check (held_bytes + spent_bytes <= 214748364800)
);
create table if not exists public.upload_reservations (
  asset_id uuid primary key,
  org_id uuid not null,
  listing_id uuid not null,
  actor_id uuid not null,
  day date not null,
  spec jsonb not null,
  held_bytes bigint not null check (held_bytes >= 0),
  spent_bytes bigint not null default 0 check (spent_bytes >= 0),
  state text not null default 'open' check (state in ('open','completed','cancelled')),
  expires_at timestamptz not null default (clock_timestamp() + interval '48 hours'),
  settled_at timestamptz,
  check ((state = 'open') = (settled_at is null))
);
-- No cascading FK: deleting a listing must not erase the only known R2 keys.
create table if not exists public.upload_operations (
  id uuid primary key default gen_random_uuid(),
  asset_id uuid not null references public.upload_reservations(asset_id),
  kind text not null check (kind in ('single','part','copy','init','assemble')),
  part integer not null default 0,
  bucket text not null check (bucket in ('uploads','renders')),
  object_key text not null,
  upload_id text,
  bytes bigint not null check (bytes between 0 and 67108864),
  expected_bytes bigint not null check (expected_bytes between 1 and 12884901888),
  content_type text not null,
  content_type_declared boolean not null,
  asset_kind text not null check (asset_kind in ('photo','video')),
  state text not null default 'planned' check (state in
    ('planned','dispatching','stored','uncertain','rejected','retained','cleaning','deleted')),
  claim uuid,
  etag text,
  created_at timestamptz not null default clock_timestamp(),
  expires_at timestamptz not null default (clock_timestamp() + interval '1 hour'),
  write_deadline timestamptz,
  cleanup_after timestamptz,
  cleanup_claim uuid,
  cleanup_attempts integer not null default 0,
  cleaned_at timestamptz,
  unique (asset_id, kind, part),
  check ((kind = 'part' and part between 1 and 384) or (kind <> 'part' and part = 0))
);
create index if not exists idx_upload_cleanup on public.upload_operations(cleanup_after)
  where cleanup_after is not null and state <> 'retained';
create index if not exists idx_upload_reservation_expiry on public.upload_reservations(expires_at)
  where state = 'open';
alter table public.upload_budget_windows enable row level security;
alter table public.upload_reservations enable row level security;
alter table public.upload_operations enable row level security;
revoke all on public.upload_budget_windows, public.upload_reservations, public.upload_operations from public, anon, authenticated;
grant select, insert, update on public.upload_budget_windows, public.upload_reservations, public.upload_operations to service_role;

create or replace function public.upload_service_only() returns void
language plpgsql security invoker set search_path = public as $$
begin
  if current_user <> 'service_role' then raise exception 'RP403: upload service role required'; end if;
end $$;

-- Every state transition uses listing -> asset -> reservation -> budget order.
-- Network/storage calls never occur inside these short transactions.
create or replace function public.lock_upload_asset(p_asset uuid) returns public.capture_assets
language plpgsql security invoker set search_path = public as $$
declare a public.capture_assets; l uuid;
begin
  perform public.upload_service_only();
  select listing_id into l from capture_assets where id = p_asset;
  if l is null then raise exception 'RP404: upload asset missing'; end if;
  perform 1 from listings where id = l for update;
  select * into strict a from capture_assets where id = p_asset for update;
  if a.transport_version <> 2 then raise exception 'RP409: legacy upload must be aborted and reticketed'; end if;
  return a;
end $$;

create or replace function public.reserve_upload_assets(p_actor uuid, p_assets jsonb)
returns jsonb language plpgsql security invoker set search_path = public as $$
declare
  s jsonb; a public.capture_assets; r public.upload_reservations; w public.upload_budget_windows;
  l public.listings; result jsonb := '[]'; n bigint; hold bigint; d date := (clock_timestamp() at time zone 'UTC')::date;
  spec jsonb; idem text; prefix text;
begin
  perform public.upload_service_only();
  if jsonb_typeof(p_assets) is distinct from 'array' or jsonb_array_length(p_assets) not between 1 and 200 then
    raise exception 'RP400: expected 1..200 assets';
  end if;
  select * into l from listings where id = (p_assets->0->>'listing_id')::uuid and deleted_at is null for update;
  if l.id is null or not exists (select 1 from orgs where id = l.org_id and deleted_at is null)
     or not exists (select 1 from memberships where org_id = l.org_id and user_id = p_actor and role in ('owner','admin','agent'))
     or exists (select 1 from deletion_requests where user_id = p_actor and status <> 'completed') then
    raise exception 'RP403: upload workspace is not writable';
  end if;
  insert into upload_budget_windows(org_id,day) values(l.org_id,d) on conflict do nothing;
  select * into strict w from upload_budget_windows where org_id=l.org_id and day=d for update;
  for s in select value from jsonb_array_elements(p_assets) loop
    if (s->>'listing_id')::uuid <> l.id or jsonb_typeof(s->'bytes') is distinct from 'number'
       or (s->>'bytes')::numeric <> trunc((s->>'bytes')::numeric) then raise exception 'RP400: invalid asset identity/bytes'; end if;
    n := (s->>'bytes')::bigint;
    if n not between 1 and 12884901888 or s->>'kind' not in ('photo','video') or s->>'bucket' not in ('uploads','renders')
       or coalesce(s->>'content_type','') !~ '^[a-z0-9.+-]+/[a-z0-9.+-]+$' then raise exception 'RP400: invalid upload specification'; end if;
    if s->>'kind' = 'photo' and n > 52428800 then raise exception 'RP400: photo exceeds 50 MiB'; end if;
    if s->>'parts_total' is not null and (s->>'part_size' is null or (s->>'part_size')::bigint <> 33554432 or
       (s->>'parts_total')::integer <> ceil(n::numeric/33554432) or s->>'kind' <> 'video') then
      raise exception 'RP400: invalid bounded multipart shape';
    end if;
    if s->>'parts_total' is null and n > 67108864 then raise exception 'RP400: single upload exceeds 64 MiB'; end if;
    prefix := (s->>'bucket') || '/' || l.org_id || '/' || l.id || '/';
    if left(s->>'storage_key',length(prefix)) <> prefix or
       substring(s->>'storage_key' from length(prefix)+1) !~ ('^(original-|gallery-)?' || (s->>'id') || '\.[a-zA-Z0-9]{1,8}$') then
      raise exception 'RP400: invalid server-generated upload key';
    end if;
    if (s->>'kind'='video' and s->>'content_type' not in ('video/mp4','video/quicktime','video/x-m4v')) or
       (s->>'kind'='photo' and s->>'content_type' not in ('image/jpeg','image/png','image/webp','image/heic','image/heif')) or
       (s->>'kind'='photo' and s->>'bucket'='renders' and s->>'content_type' not in ('image/jpeg','image/png','image/webp')) or
       (s->>'kind'='photo' and s->>'bucket'='renders' and s->>'storage_key' not like '%/original-%' and n>10485760) then
      raise exception 'RP400: role-specific upload type or size denied';
    end if;
    idem := nullif(s->>'idem_key','');
    if idem is not null and length(idem) not between 8 and 128 then raise exception 'RP400: invalid idempotency key'; end if;
    -- Client computes this advisory digest asynchronously; it is not transport
    -- authority and may arrive on a later retry/complete request.
    spec := s - array['id','storage_key','idem_key','sha256'];
    -- Role-bearing prefix is part of request identity, not just bucket/type.
    spec := spec || jsonb_build_object('key_role', case when s->>'storage_key' like '%/original-%' then 'original'
      when s->>'storage_key' like '%/gallery-%' then 'gallery' else 'default' end);
    a := null;
    if idem is not null then
      select * into a from capture_assets where listing_id=l.id and idem_key=idem and not uploaded and not upload_aborted;
    end if;
    if a.id is not null then
      select * into r from upload_reservations where asset_id=a.id;
      if r.asset_id is null or r.spec is distinct from spec or r.state <> 'open' or r.expires_at <= clock_timestamp() then
        raise exception 'RP409: idempotency key conflicts with an existing or expired upload';
      end if;
      result := result || jsonb_build_array(to_jsonb(a) || '{"replayed":true}'::jsonb);
      continue;
    end if;
    hold := n * case when s->>'parts_total' is null then 2 else 1 end;
    if w.tickets + 1 > 2000 or w.held_bytes + w.spent_bytes + hold > 214748364800 then
      raise exception 'RP429: daily physical upload reservation budget exhausted';
    end if;
    insert into capture_assets(id,listing_id,kind,bucket,storage_key,sha256,bytes,content_type,content_type_declared,
      part_size,parts_total,idem_key,transport_version)
      values ((s->>'id')::uuid,l.id,s->>'kind',s->>'bucket',s->>'storage_key',s->>'sha256',n,s->>'content_type',
        (s->>'content_type_declared')::boolean,(s->>'part_size')::bigint,(s->>'parts_total')::integer,idem,2)
      returning * into a;
    insert into upload_reservations(asset_id,org_id,listing_id,actor_id,day,spec,held_bytes)
      values(a.id,l.org_id,l.id,p_actor,d,spec,hold);
    w.tickets := w.tickets+1; w.held_bytes := w.held_bytes+hold;
    result := result || jsonb_build_array(to_jsonb(a) || '{"replayed":false}'::jsonb);
  end loop;
  update upload_budget_windows set tickets=w.tickets,held_bytes=w.held_bytes where org_id=l.org_id and day=d;
  return result;
end $$;

create or replace function public.plan_upload_operation(p_asset uuid, p_kind text, p_part integer default 0)
returns jsonb language plpgsql security invoker set search_path = public as $$
declare a public.capture_assets; r public.upload_reservations; op public.upload_operations; n bigint; k text; uid uuid := gen_random_uuid();
begin
  a := public.lock_upload_asset(p_asset);
  select * into strict r from upload_reservations where asset_id=p_asset for update;
  if a.uploaded or a.upload_aborted or r.state <> 'open' or r.expires_at <= clock_timestamp() then
    raise exception 'RP409: upload is terminal or expired';
  end if;
  if not exists(select 1 from listings where id=a.listing_id and org_id=r.org_id and deleted_at is null)
     or not exists(select 1 from orgs where id=r.org_id and deleted_at is null) then raise exception 'RP403: workspace changed'; end if;
  select * into op from upload_operations where asset_id=p_asset and kind=p_kind and part=p_part;
  if op.id is not null then
    if op.state in ('planned','stored') then
      update upload_operations set expires_at=least(r.expires_at,clock_timestamp()+interval '1 hour') where id=op.id returning * into op;
    end if;
    return to_jsonb(op);
  end if;
  if p_kind = 'init' and a.parts_total is not null and p_part=0 and a.upload_id is null then n:=0; k:=a.storage_key;
  elsif p_kind = 'part' and a.upload_id is not null and p_part between 1 and a.parts_total then
    n:=least(a.part_size,a.bytes-(p_part-1)*a.part_size); k:=a.storage_key;
  elsif p_kind = 'single' and a.parts_total is null and p_part=0 then
    n:=a.bytes; k:='_staging/' || a.storage_key || '-' || uid;
  elsif p_kind = 'copy' and a.parts_total is null and p_part=0 and exists
    (select 1 from upload_operations where asset_id=p_asset and kind='single' and state='stored') then
    n:=a.bytes; k:=regexp_replace(a.storage_key,'(\.[^.]+)$','-complete-' || uid || '\1');
  elsif p_kind='assemble' and a.parts_total is not null and p_part=0 and a.completion_parts is not null then
    n:=0; k:=a.storage_key;
  else raise exception 'RP409: operation does not match the upload'; end if;
  insert into upload_operations(id,asset_id,kind,part,bucket,object_key,upload_id,bytes,expected_bytes,content_type,content_type_declared,asset_kind)
    values(uid,p_asset,p_kind,p_part,a.bucket,k,a.upload_id,n,a.bytes,a.content_type,a.content_type_declared,a.kind) returning * into op;
  if p_kind='copy' then
    update upload_operations set content_type=(select content_type from upload_operations where asset_id=p_asset and kind='single')
      where id=op.id returning * into op;
  end if;
  return to_jsonb(op);
end $$;

create or replace function public.confirmed_upload_transfers(p_asset uuid)
returns jsonb language plpgsql security invoker set search_path=public as $$
declare a public.capture_assets; parts jsonb;
begin
  a:=public.lock_upload_asset(p_asset);
  select jsonb_agg(to_jsonb(o) order by part) into parts from upload_operations o
    where asset_id=a.id and kind in ('single','part') and state='stored';
  if parts is null or jsonb_array_length(parts)<>coalesce(a.parts_total,1) then
    raise exception 'RP409: every transfer needs its durable stored receipt before completion';
  end if;
  return parts;
end $$;

create or replace function public.claim_upload_operation(p_operation uuid, p_claim uuid)
returns jsonb language plpgsql security invoker set search_path = public as $$
declare op public.upload_operations; a public.capture_assets; r public.upload_reservations;
begin
  perform public.upload_service_only();
  select * into strict op from upload_operations where id=p_operation;
  a:=public.lock_upload_asset(op.asset_id);
  select * into strict r from upload_reservations where asset_id=a.id for update;
  select * into strict op from upload_operations where id=p_operation for update;
  if op.state in ('stored','retained') and r.state <> 'cancelled' then return to_jsonb(op) || jsonb_build_object('dispatch',false); end if;
  if a.uploaded or a.upload_aborted or r.state <> 'open' or r.expires_at <= clock_timestamp()
     or op.expires_at <= clock_timestamp() or op.state <> 'planned' then raise exception 'RP503: transfer unavailable; recover or cancel, no new dispatch'; end if;
  if not exists (select 1 from listings where id=a.listing_id and org_id=r.org_id and deleted_at is null)
     or not exists (select 1 from orgs where id=r.org_id and deleted_at is null)
     or not exists (select 1 from memberships where org_id=r.org_id and user_id=r.actor_id and role in ('owner','admin','agent'))
     or exists (select 1 from deletion_requests where user_id=r.actor_id and status <> 'completed') then
    raise exception 'RP403: original upload authority no longer valid';
  end if;
  if p_claim is null or r.held_bytes < op.bytes then raise exception 'RP409: no held upload byte authority'; end if;
  update upload_budget_windows set held_bytes=held_bytes-op.bytes,spent_bytes=spent_bytes+op.bytes where org_id=r.org_id and day=r.day;
  update upload_reservations set held_bytes=held_bytes-op.bytes,spent_bytes=spent_bytes+op.bytes where asset_id=a.id;
  update upload_operations set state='dispatching',claim=p_claim,write_deadline=clock_timestamp()+interval '15 minutes'
    where id=op.id returning * into op;
  return to_jsonb(op) || jsonb_build_object('dispatch',true);
end $$;

create or replace function public.finish_upload_operation(p_operation uuid, p_claim uuid, p_result text, p_etag text default null, p_upload_id text default null, p_content_type text default null)
returns jsonb language plpgsql security invoker set search_path = public as $$
declare op public.upload_operations; a public.capture_assets; r public.upload_reservations;
begin
  perform public.upload_service_only();
  select * into strict op from upload_operations where id=p_operation;
  a:=public.lock_upload_asset(op.asset_id);
  select * into strict r from upload_reservations where asset_id=a.id for update;
  select * into strict op from upload_operations where id=p_operation for update;
  if op.claim is distinct from p_claim or p_result not in ('stored','uncertain','rejected') then raise exception 'RP409: operation claim/result mismatch'; end if;
  if op.state <> 'dispatching' then
    if op.state=p_result and op.etag is not distinct from p_etag and (op.kind<>'init' or op.upload_id is not distinct from p_upload_id) then return to_jsonb(op); end if;
    raise exception 'RP409: operation already settled';
  end if;
  if p_result='stored' and (p_etag is null or length(p_etag) not between 1 and 256) then raise exception 'RP400: receipt ETag required'; end if;
  if p_content_type is not null and (p_content_type !~ '^[a-z0-9.+-]+/[a-z0-9.+-]+$' or
     (op.content_type_declared and p_content_type <> op.content_type)) then raise exception 'RP400: receipt type mismatch'; end if;
  if op.kind='init' and p_result='stored' then
    if p_upload_id is null or length(p_upload_id) not between 1 and 2048 then raise exception 'RP400: upload ID required'; end if;
    update capture_assets set upload_id=p_upload_id where id=a.id and not uploaded;
  end if;
  update upload_operations set state=p_result,etag=p_etag,upload_id=coalesce(p_upload_id,upload_id),content_type=coalesce(p_content_type,content_type),
    cleanup_after=case when r.state='cancelled' and kind not in ('part','assemble') then greatest(clock_timestamp(),write_deadline)+interval '1 hour' else null end
    where id=op.id returning * into op;
  return to_jsonb(op);
end $$;

-- Only the trusted server may acknowledge a read-only storage observation for
-- this immutable, pre-dispatch identity. It never grants a second write.
create or replace function public.recover_upload_operation(p_operation uuid,p_etag text,p_upload_id text default null,p_content_type text default null)
returns jsonb language plpgsql security invoker set search_path=public as $$
declare op public.upload_operations; a public.capture_assets; r public.upload_reservations;
begin
  perform public.upload_service_only();
  select * into strict op from upload_operations where id=p_operation;
  a:=public.lock_upload_asset(op.asset_id);
  select * into strict r from upload_reservations where asset_id=a.id for update;
  select * into strict op from upload_operations where id=p_operation for update;
  if r.state<>'open' or a.uploaded or a.upload_aborted or r.expires_at<=clock_timestamp() then raise exception 'RP409: recovery is terminal or expired'; end if;
  if op.state='stored' then
    if op.etag is distinct from p_etag or (op.kind='init' and op.upload_id is distinct from p_upload_id) then raise exception 'RP409: recovery receipt changed'; end if;
    return to_jsonb(op);
  end if;
  if op.state not in ('dispatching','uncertain') or op.claim is null or p_etag is null or length(p_etag) not between 1 and 256 then
    raise exception 'RP409: no uncertain recorded dispatch to recover';
  end if;
  if p_content_type is not null and (p_content_type !~ '^[a-z0-9.+-]+/[a-z0-9.+-]+$' or
    (op.content_type_declared and p_content_type<>op.content_type)) then raise exception 'RP400: recovered type mismatch'; end if;
  if op.kind='init' then
    if p_upload_id is null or length(p_upload_id) not between 1 and 2048 then raise exception 'RP400: recovered multipart ID required'; end if;
    update capture_assets set upload_id=p_upload_id where id=a.id;
  end if;
  update upload_operations set state='stored',etag=p_etag,upload_id=coalesce(p_upload_id,upload_id),
    content_type=coalesce(p_content_type,content_type),cleanup_after=null where id=op.id returning * into op;
  return to_jsonb(op);
end $$;

-- Publication and cancellation settle the SAME reservation under the SAME lock.
-- Uncertain/dispatched bytes are never refunded, even after successful deletion.
create or replace function public.settle_upload_reservation(p_asset uuid, p_complete boolean, p_operation uuid default null, p_metadata jsonb default '{}')
returns jsonb language plpgsql security invoker set search_path = public as $$
declare a public.capture_assets; r public.upload_reservations; op public.upload_operations; manifest jsonb;
begin
  a:=public.lock_upload_asset(p_asset);
  if p_complete is null or jsonb_typeof(p_metadata) is distinct from 'object' then raise exception 'RP400: invalid settlement'; end if;
  select * into strict r from upload_reservations where asset_id=a.id for update;
  if r.state <> 'open' then
    if (r.state='completed') <> p_complete then raise exception 'RP409: opposing terminal settlement'; end if;
    return to_jsonb(a);
  end if;
  if p_complete then
    if a.upload_aborted or r.expires_at <= clock_timestamp() then raise exception 'RP409: upload expired or cancelled'; end if;
    if not exists(select 1 from listings where id=a.listing_id and org_id=r.org_id and deleted_at is null)
       or not exists(select 1 from orgs where id=r.org_id and deleted_at is null)
       or not exists(select 1 from memberships where org_id=r.org_id and user_id=r.actor_id and role in ('owner','admin','agent'))
       or exists(select 1 from deletion_requests where user_id=r.actor_id and status <> 'completed') then
      raise exception 'RP403: original upload authority no longer valid';
    end if;
    if a.parts_total is null then
      select * into op from upload_operations where id=p_operation and asset_id=a.id and kind='copy' and state='stored' for update;
      if op.id is null then raise exception 'RP409: confirmed copy receipt required'; end if;
    else
      if not exists(select 1 from upload_operations where id=p_operation and asset_id=a.id and kind='assemble' and state='stored') then
        raise exception 'RP409: confirmed assembly receipt required';
      end if;
      select jsonb_agg(jsonb_build_object('number',part,'etag',etag) order by part) into manifest
        from upload_operations where asset_id=a.id and kind='part' and state='stored';
      if manifest is null or jsonb_array_length(manifest)<>a.parts_total or manifest is distinct from a.completion_parts then
        raise exception 'RP409: multipart publication requires every confirmed transfer receipt';
      end if;
    end if;
    update capture_assets set uploaded=true,upload_id=null,storage_key=coalesce(op.object_key,storage_key),
      duration_s=coalesce((p_metadata->>'duration_s')::numeric,duration_s),fps=coalesce((p_metadata->>'fps')::numeric,fps),
      width=coalesce((p_metadata->>'width')::integer,width),height=coalesce((p_metadata->>'height')::integer,height),
      content_type=coalesce(op.content_type,content_type),
      sha256=coalesce(p_metadata->>'sha256',sha256),
      codec=coalesce(p_metadata->>'codec',codec),is_drone=coalesce((p_metadata->>'is_drone')::boolean,is_drone),
      has_gyro=coalesce((p_metadata->>'has_gyro')::boolean,has_gyro)
      where id=a.id returning * into a;
    update upload_operations set state='retained',cleanup_after=null where asset_id=a.id and
      ((kind='copy' and id=p_operation) or (a.parts_total is not null and kind in ('init','part','assemble')));
  else
    if a.uploaded then raise exception 'RP409: completed upload cannot be cancelled'; end if;
    update capture_assets set upload_aborted=true,idem_key=null where id=a.id returning * into a;
  end if;
  update upload_budget_windows set held_bytes=held_bytes-r.held_bytes where org_id=r.org_id and day=r.day;
  update upload_reservations set held_bytes=0,state=case when p_complete then 'completed' else 'cancelled' end,
    settled_at=clock_timestamp() where asset_id=a.id;
  update upload_operations set cleanup_after=greatest(clock_timestamp(),coalesce(write_deadline,clock_timestamp()))+interval '1 hour'
    where asset_id=a.id and state<>'retained' and kind not in ('part','assemble');
  return to_jsonb(a);
end $$;

-- Cleanup is a lease on a non-publishable operation. Never mark it gone before
-- storage confirms deletion. Deleted rows remain journaled for audit/rechecks.
create or replace function public.claim_upload_cleanup(p_operation uuid, p_claim uuid)
returns jsonb language plpgsql security invoker set search_path = public as $$
declare op public.upload_operations; a public.capture_assets;
begin
  perform public.upload_service_only();
  select * into strict op from upload_operations where id=p_operation;
  if exists(select 1 from capture_assets where id=op.asset_id) then a:=public.lock_upload_asset(op.asset_id); end if;
  perform 1 from upload_reservations where asset_id=op.asset_id for update;
  select * into strict op from upload_operations where id=p_operation for update;
  if p_claim is null or op.state='retained' or op.cleanup_after is null or op.cleanup_after>clock_timestamp() or
     exists(select 1 from upload_reservations where asset_id=op.asset_id and state='open') or
     exists(select 1 from capture_assets where uploaded and storage_key=op.object_key and bucket=op.bucket) then
    raise exception 'RP409: operation is not eligible for cleanup';
  end if;
  update upload_operations set state='cleaning',cleanup_claim=p_claim,cleanup_attempts=cleanup_attempts+1,
    cleanup_after=clock_timestamp()+interval '15 minutes' where id=op.id returning * into op;
  return to_jsonb(op);
end $$;
create or replace function public.finish_upload_cleanup(p_operation uuid,p_claim uuid,p_deleted boolean)
returns boolean language plpgsql security invoker set search_path = public as $$
begin
  perform public.upload_service_only();
  update upload_operations set state=case when p_deleted then 'deleted' else 'uncertain' end,
    cleaned_at=case when p_deleted then clock_timestamp() else cleaned_at end,
    cleanup_after=case when p_deleted then null else clock_timestamp()+interval '1 hour' end
    where id=p_operation and state='cleaning' and cleanup_claim=p_claim;
  if not found then raise exception 'RP409: cleanup claim changed'; end if;
  if p_deleted then
    update upload_operations set state='deleted',cleaned_at=clock_timestamp(),cleanup_after=null
      where asset_id=(select asset_id from upload_operations where id=p_operation and kind='init')
      and kind in ('part','assemble') and state<>'retained';
  end if;
  return true;
end $$;

create or replace function public.upload_maintenance_batch()
returns jsonb language plpgsql security invoker set search_path=public as $$
begin
  perform public.upload_service_only();
  return jsonb_build_object('expire',coalesce((select jsonb_agg(asset_id) from
    (select asset_id from upload_reservations where state='open' and
      (expires_at<=clock_timestamp() or not exists(select 1 from capture_assets where id=asset_id))
      order by expires_at,asset_id limit 16) q),'[]'::jsonb),
    'cleanup',coalesce((select jsonb_agg(id) from
    (select o.id from upload_operations o join upload_reservations r on r.asset_id=o.asset_id
      where r.state<>'open' and o.cleanup_after<=clock_timestamp() and o.state<>'retained'
      order by o.cleanup_after,o.id limit 16) q),'[]'::jsonb));
end $$;

-- Retired v1 tickets can be cancelled, never given another host-only URL.
-- This inventories their known transport key/session, not unknown historical
-- completion candidates. Legacy physical spend is UNKNOWN, not refunded.
create or replace function public.cancel_legacy_upload(p_asset uuid,p_actor uuid)
returns jsonb language plpgsql security invoker set search_path=public as $$
declare a public.capture_assets; l public.listings; d date:=(clock_timestamp() at time zone 'UTC')::date; uid uuid:=gen_random_uuid();
begin
  perform public.upload_service_only();
  select * into l from listings where id=(select listing_id from capture_assets where id=p_asset) for update;
  select * into strict a from capture_assets where id=p_asset for update;
  if a.uploaded then raise exception 'RP409: completed upload cannot be cancelled'; end if;
  if a.transport_version=2 then return public.settle_upload_reservation(p_asset,false); end if;
  if not exists(select 1 from memberships where org_id=l.org_id and user_id=p_actor and role in ('owner','admin','agent')) then
    raise exception 'RP403: legacy upload is not writable'; end if;
  insert into upload_budget_windows(org_id,day) values(l.org_id,d) on conflict do nothing;
  insert into upload_reservations(asset_id,org_id,listing_id,actor_id,day,spec,held_bytes,state,settled_at)
    values(a.id,l.org_id,l.id,p_actor,d,'{"legacy_physical_bytes":"unknown"}',0,'cancelled',clock_timestamp());
  insert into upload_operations(id,asset_id,kind,bucket,object_key,upload_id,bytes,expected_bytes,content_type,content_type_declared,asset_kind,state,claim,cleanup_after)
    values(uid,a.id,case when a.upload_id is null then 'single' else 'init' end,a.bucket,
      case when a.upload_id is null then '_staging/'||a.storage_key else a.storage_key end,a.upload_id,0,
      greatest(1,coalesce(a.bytes,1)),coalesce(a.content_type,'application/octet-stream'),coalesce(a.content_type_declared,false),
      a.kind,'uncertain',gen_random_uuid(),clock_timestamp()+interval '2 hours');
  update capture_assets set upload_aborted=true,idem_key=null,transport_version=2 where id=a.id returning * into a;
  return to_jsonb(a);
end $$;

create or replace function public.expire_upload_reservation(p_asset uuid)
returns boolean language plpgsql security invoker set search_path=public as $$
declare r public.upload_reservations; a public.capture_assets;
begin
  perform public.upload_service_only();
  select * into strict r from upload_reservations where asset_id=p_asset;
  perform 1 from listings where id=r.listing_id for update;
  select * into a from capture_assets where id=p_asset for update;
  select * into strict r from upload_reservations where asset_id=p_asset for update;
  if r.state<>'open' then return true; end if;
  if a.id is not null then
    if r.expires_at>clock_timestamp() then raise exception 'RP409: reservation has not expired'; end if;
    perform public.settle_upload_reservation(p_asset,false);
  else
    -- Deletion must not erase the journal or leave undispatched budget held.
    update upload_budget_windows set held_bytes=held_bytes-r.held_bytes where org_id=r.org_id and day=r.day;
    update upload_reservations set held_bytes=0,state='cancelled',settled_at=clock_timestamp() where asset_id=p_asset;
    update upload_operations set cleanup_after=greatest(clock_timestamp(),coalesce(write_deadline,clock_timestamp()))+interval '1 hour'
      where asset_id=p_asset and state<>'retained' and kind not in ('part','assemble');
  end if;
  return true;
end $$;

revoke execute on function public.upload_service_only(), public.lock_upload_asset(uuid),
  public.reserve_upload_assets(uuid,jsonb), public.plan_upload_operation(uuid,text,integer), public.confirmed_upload_transfers(uuid),
  public.claim_upload_operation(uuid,uuid), public.finish_upload_operation(uuid,uuid,text,text,text,text),
  public.recover_upload_operation(uuid,text,text,text), public.settle_upload_reservation(uuid,boolean,uuid,jsonb), public.claim_upload_cleanup(uuid,uuid),
  public.finish_upload_cleanup(uuid,uuid,boolean),public.upload_maintenance_batch(),public.expire_upload_reservation(uuid),public.cancel_legacy_upload(uuid,uuid) from public,anon,authenticated;
grant execute on function public.upload_service_only(), public.lock_upload_asset(uuid),
  public.reserve_upload_assets(uuid,jsonb), public.plan_upload_operation(uuid,text,integer), public.confirmed_upload_transfers(uuid),
  public.claim_upload_operation(uuid,uuid), public.finish_upload_operation(uuid,uuid,text,text,text,text),
  public.recover_upload_operation(uuid,text,text,text), public.settle_upload_reservation(uuid,boolean,uuid,jsonb), public.claim_upload_cleanup(uuid,uuid),
  public.finish_upload_cleanup(uuid,uuid,boolean),public.upload_maintenance_batch(),public.expire_upload_reservation(uuid),public.cancel_legacy_upload(uuid,uuid) to service_role;
