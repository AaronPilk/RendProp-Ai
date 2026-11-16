-- Private, immutable native Photo Studio lineage. The API commits this only
-- after both exact-byte uploads have completed; it is not gallery publication.
begin;
-- This migration owns one relation, its three indexes and four privileged
-- functions. A replay may reuse only the exact objects installed by the first
-- application; a partial or changed set must stop before any DDL can repair it.
do $own_replay_guard$
declare
  e record; p pg_catalog.pg_proc; rel oid; owner_expected oid; service_oid oid;
  present integer; shape text; constraints text; not_null_constraints text; indexes text;
begin
  select proowner into owner_expected from pg_catalog.pg_proc
    where oid = to_regprocedure('public.client_listing_access(uuid,uuid,uuid,boolean)');
  select oid into service_oid from pg_catalog.pg_roles where rolname = 'service_role';
  if owner_expected is null or service_oid is null then
    raise exception 'Native photo backup needs listing authority and service_role';
  end if;
  rel := to_regclass('public.native_photo_backup_versions');
  present := (select count(*) from pg_catalog.pg_proc
    where pronamespace = 'public'::regnamespace and proname in
      ('native_photo_backup_asset_ready','native_photo_backup_commit',
       'native_photo_backup_read','native_photo_backup_download'))
    + (select count(*) from pg_catalog.pg_class
    where relnamespace = 'public'::regnamespace and relname in
      ('native_photo_backup_versions','native_photo_backup_versions_pkey',
       'native_photo_backup_listing_page_idx','native_photo_backup_listing_family_idx'));
  if present = 0 then return; end if;
  if present <> 8 then
    raise exception 'Review partial or unknown native photo backup objects (% present, 8 expected)', present;
  end if;
  for e in select * from (values
    ('public.native_photo_backup_asset_ready(uuid,uuid,jsonb,uuid)',
      '64c79a0bfaf0da9ec78819b1761451a3','boolean','s',
      array['p_org','p_listing','p_receipt','p_actor'],
      'p_org uuid, p_listing uuid, p_receipt jsonb, p_actor uuid DEFAULT NULL::uuid',false),
    ('public.native_photo_backup_commit(uuid,uuid,uuid,uuid,jsonb)',
      'e89723d138d8e88b3890a4d096d0ee48','jsonb','v',
      array['p_actor','p_org','p_library','p_listing','p_manifest'],
      'p_actor uuid, p_org uuid, p_library uuid, p_listing uuid, p_manifest jsonb',true),
    ('public.native_photo_backup_read(uuid,uuid,uuid,uuid,text,integer)',
      'a716ca368d09bc20b9e159bd98dda319','jsonb','s',
      array['p_actor','p_org','p_library','p_listing','p_version','p_offset'],
      'p_actor uuid, p_org uuid, p_library uuid, p_listing uuid, p_version text DEFAULT NULL::text, p_offset integer DEFAULT 0',true),
    ('public.native_photo_backup_download(uuid,uuid,uuid,uuid,uuid)',
      'e8ebc533aa6451d8371afe14c1feb569','jsonb','s',
      array['p_actor','p_org','p_library','p_listing','p_asset'],
      'p_actor uuid, p_org uuid, p_library uuid, p_listing uuid, p_asset uuid',true)
  ) v(signature,body_md5,result_type,volatility,arg_names,args,service_execute) loop
    select * into p from pg_catalog.pg_proc where oid = to_regprocedure(e.signature);
    if not found or md5(p.prosrc) <> e.body_md5 or p.proowner <> owner_expected
      or p.prokind <> 'f' or p.prolang <> (select oid from pg_catalog.pg_language where lanname = 'plpgsql')
      or not p.prosecdef or p.provolatile <> e.volatility or p.proisstrict or p.proleakproof
      or p.proparallel <> 'u' or p.proretset or p.proconfig is distinct from array['search_path=""']::text[]
      or p.proargnames is distinct from e.arg_names or p.proargmodes is not null
      or p.proallargtypes is not null or p.provariadic <> 0
      or pg_get_function_arguments(p.oid) is distinct from e.args
      or p.prorettype is distinct from to_regtype(e.result_type)::oid
      or exists (select 1 from aclexplode(coalesce(p.proacl,acldefault('f',p.proowner))) a
        where a.grantor <> owner_expected or a.privilege_type <> 'EXECUTE' or a.is_grantable
          or a.grantee not in (owner_expected,service_oid)
          or (a.grantee = service_oid and not e.service_execute))
      or not exists (select 1 from aclexplode(coalesce(p.proacl,acldefault('f',p.proowner))) a
        where a.grantee = owner_expected and a.privilege_type = 'EXECUTE')
      or (e.service_execute and not exists (select 1
        from aclexplode(coalesce(p.proacl,acldefault('f',p.proowner))) a
        where a.grantee = service_oid and a.privilege_type = 'EXECUTE')) then
      raise exception 'Review changed native photo backup helper: %', e.signature;
    end if;
  end loop;
  select string_agg(a.attname || ' ' || format_type(a.atttypid,a.atttypmod)
      || case when a.attnotnull then ' not null' else '' end
      || coalesce(' default ' || pg_get_expr(d.adbin,d.adrelid),''),', ' order by a.attnum)
    into shape from pg_catalog.pg_attribute a
    left join pg_catalog.pg_attrdef d on d.adrelid = a.attrelid and d.adnum = a.attnum
    where a.attrelid = rel and a.attnum > 0 and not a.attisdropped;
  select string_agg(conname || ': ' || pg_get_constraintdef(oid),'; ' order by conname)
    into constraints from pg_catalog.pg_constraint where conrelid = rel and contype <> 'n';
  -- PostgreSQL 18 catalogs named NOT NULL constraints separately. Pin their
  -- exact names there; older supported servers expose only attnotnull.
  select string_agg(conname || ': ' || pg_get_constraintdef(oid),'; ' order by conname)
    into not_null_constraints from pg_catalog.pg_constraint where conrelid = rel and contype = 'n';
  select string_agg(pg_get_indexdef(indexrelid),'; ' order by indexrelid::regclass::text)
    into indexes from pg_catalog.pg_index where indrelid = rel;
  if shape is distinct from
      'listing_id uuid not null, version_id text not null, family_id text not null, actor_id uuid not null, org_id uuid not null, library_org_id uuid not null, image_asset_id uuid not null, original_asset_id uuid not null, manifest jsonb not null, committed_at timestamp with time zone not null default clock_timestamp()'
    or constraints is distinct from
      'native_photo_backup_versions_check: CHECK ((((length(version_id) >= 1) AND (length(version_id) <= 128)) AND ((length(family_id) >= 1) AND (length(family_id) <= 128)))); native_photo_backup_versions_listing_id_fkey: FOREIGN KEY (listing_id) REFERENCES listings(id) ON DELETE CASCADE; native_photo_backup_versions_manifest_check: CHECK ((jsonb_typeof(manifest) = ''object''::text)); native_photo_backup_versions_pkey: PRIMARY KEY (listing_id, version_id)'
    or (current_setting('server_version_num')::integer < 180000 and not_null_constraints is not null)
    or (current_setting('server_version_num')::integer >= 180000 and not_null_constraints is distinct from
      'native_photo_backup_versions_actor_id_not_null: NOT NULL actor_id; native_photo_backup_versions_committed_at_not_null: NOT NULL committed_at; native_photo_backup_versions_family_id_not_null: NOT NULL family_id; native_photo_backup_versions_image_asset_id_not_null: NOT NULL image_asset_id; native_photo_backup_versions_library_org_id_not_null: NOT NULL library_org_id; native_photo_backup_versions_listing_id_not_null: NOT NULL listing_id; native_photo_backup_versions_manifest_not_null: NOT NULL manifest; native_photo_backup_versions_org_id_not_null: NOT NULL org_id; native_photo_backup_versions_original_asset_id_not_null: NOT NULL original_asset_id; native_photo_backup_versions_version_id_not_null: NOT NULL version_id')
    or indexes is distinct from
      'CREATE INDEX native_photo_backup_listing_family_idx ON public.native_photo_backup_versions USING btree (listing_id, family_id); CREATE INDEX native_photo_backup_listing_page_idx ON public.native_photo_backup_versions USING btree (listing_id, committed_at, version_id); CREATE UNIQUE INDEX native_photo_backup_versions_pkey ON public.native_photo_backup_versions USING btree (listing_id, version_id)'
    or exists (select 1 from pg_catalog.pg_attribute a where a.attrelid = rel and a.attnum > 0
      and (a.attisdropped or a.attacl is not null or a.attidentity <> '' or a.attgenerated <> ''))
    or exists (select 1 from pg_catalog.pg_constraint c where c.conrelid = rel
      and (not c.convalidated or c.condeferrable or c.condeferred or not c.conislocal))
    or exists (select 1 from pg_catalog.pg_index i where i.indrelid = rel
      and (not i.indisvalid or not i.indisready or not i.indislive))
    or exists (select 1 from pg_catalog.pg_class c where c.oid in
      (select indexrelid from pg_catalog.pg_index where indrelid = rel)
      and (c.relkind <> 'i' or c.relpersistence <> 'p' or c.relowner <> owner_expected
        or c.reloptions is not null))
    or exists (select 1 from pg_catalog.pg_trigger t where t.tgrelid = rel and not t.tgisinternal)
    or exists (select 1 from pg_catalog.pg_policy where polrelid = rel)
    or exists (select 1 from pg_catalog.pg_rewrite where ev_class = rel)
    or exists (select 1 from pg_catalog.pg_class c where c.oid = rel
      and (c.relkind <> 'r' or c.relpersistence <> 'p' or c.relowner <> owner_expected
        or not c.relrowsecurity or c.relforcerowsecurity or c.relreplident <> 'd'
        or c.relacl is distinct from acldefault('r',owner_expected)
        or c.reloptions is not null)) then
    raise exception 'Review changed native photo backup relation: public.native_photo_backup_versions';
  end if;
end$own_replay_guard$;

create table if not exists public.native_photo_backup_versions (
  listing_id uuid not null references public.listings(id) on delete cascade,
  version_id text not null,
  family_id text not null,
  -- Snapshot identities remain after an uploader leaves; current access is
  -- always rechecked through the live listing/library authorization RPC.
  actor_id uuid not null,
  org_id uuid not null,
  library_org_id uuid not null,
  image_asset_id uuid not null,
  original_asset_id uuid not null,
  manifest jsonb not null check (jsonb_typeof(manifest) = 'object'),
  committed_at timestamptz not null default clock_timestamp(),
  primary key (listing_id, version_id),
  check (length(version_id) between 1 and 128 and length(family_id) between 1 and 128)
);
create index if not exists native_photo_backup_listing_page_idx
  on public.native_photo_backup_versions(listing_id, committed_at, version_id);
create index if not exists native_photo_backup_listing_family_idx
  on public.native_photo_backup_versions(listing_id, family_id);
alter table public.native_photo_backup_versions enable row level security;
revoke all on public.native_photo_backup_versions from public, anon, authenticated, service_role;

-- A completed upload is a server-observed R2 length/type/ETag receipt. SHA-256
-- remains advisory until a separate server byte readback is introduced.
create or replace function public.native_photo_backup_asset_ready(
  p_org uuid, p_listing uuid, p_receipt jsonb,
  p_actor uuid default null
) returns boolean language plpgsql stable security definer set search_path = '' as $$
declare asset uuid; n bigint; mime text; digest text;
begin
  if jsonb_typeof(p_receipt) is distinct from 'object'
    or (select count(*) from jsonb_object_keys(p_receipt)) <> 4
    or not (p_receipt ?& array['asset_id','sha256','bytes','content_type'])
    or coalesce(p_receipt->>'asset_id','') !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
    or coalesce(p_receipt->>'sha256','') !~ '^[a-f0-9]{64}$'
    or jsonb_typeof(p_receipt->'bytes') is distinct from 'number'
    or coalesce(p_receipt->>'bytes','') !~ '^[0-9]{1,8}$'
    or p_receipt->>'content_type' not in ('image/jpeg','image/png','image/webp','image/heic','image/heif')
  then return false; end if;
  asset := (p_receipt->>'asset_id')::uuid;
  n := (p_receipt->>'bytes')::bigint;
  digest := p_receipt->>'sha256';
  mime := p_receipt->>'content_type';
  if n not between 1 and 52428800 then return false; end if;
  return exists (
    select 1 from public.capture_assets a
    join public.upload_reservations r on r.asset_id = a.id
    where a.id = asset and a.listing_id = p_listing and a.kind = 'photo'
      and a.bucket = 'uploads' and a.uploaded is true and a.upload_aborted is false
      and a.transport_version = 2 and a.content_type_declared is true
      and a.sha256 = digest and a.bytes = n and a.content_type = mime
      and a.storage_key ~ ('^uploads/' || p_org || '/' || p_listing || '/' || asset ||
        '(-complete-[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})?\.(jpg|jpeg|png|webp|heic|heif)$')
      and r.org_id = p_org and r.listing_id = p_listing and r.state = 'completed'
      and (p_actor is null or r.actor_id = p_actor)
      and r.spec->>'kind' = 'photo' and r.spec->>'bucket' = 'uploads'
      and r.spec->>'key_role' = 'default' and r.spec->>'content_type' = mime
      and r.spec->>'content_type_declared' = 'true'
      and (r.spec->>'bytes')::bigint = n
      and exists (select 1 from public.upload_operations op where op.asset_id = a.id
        and op.state = 'retained' and op.object_key = a.storage_key
        and op.kind in ('copy','assemble') and nullif(op.etag,'') is not null)
  );
end$$;
revoke all on function public.native_photo_backup_asset_ready(uuid,uuid,jsonb,uuid)
  from public, anon, authenticated, service_role;

create or replace function public.native_photo_backup_commit(
  p_actor uuid, p_org uuid, p_library uuid, p_listing uuid, p_manifest jsonb
) returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v text; family text; edit text; prior public.native_photo_backup_versions;
  root public.native_photo_backup_versions; parent public.native_photo_backup_versions;
  source public.native_photo_backup_versions; ref public.native_photo_backup_versions;
  replay boolean := false; ext text;
begin
  if current_setting('role',true) is distinct from 'service_role' then raise insufficient_privilege; end if;
  if p_actor is null or p_org is null or p_library is null or p_listing is null
    or jsonb_typeof(p_manifest) is distinct from 'object'
    or (select count(*) from jsonb_object_keys(p_manifest)) <> 19
    or not (p_manifest ?& array['schema','listing_id','version_id','family_id','image_file','original_file',
      'image','original','parent_id','source_id','staging_base_id','staging_reference_id',
      'edit','style','effects','disclosure','provenance_id','provenance_recorded','created_at'])
    or p_manifest->'schema' <> '1'::jsonb
    or p_manifest->>'listing_id' is distinct from p_listing::text
    or coalesce(p_manifest->>'version_id','') !~ '^[A-Za-z0-9-]{1,128}$'
    or coalesce(p_manifest->>'family_id','') !~ '^[A-Za-z0-9-]{1,128}$'
    or jsonb_typeof(p_manifest->'effects') is distinct from 'array'
    or jsonb_array_length(p_manifest->'effects') > 12
    or jsonb_typeof(p_manifest->'provenance_recorded') is distinct from 'boolean'
    or coalesce(p_manifest->>'created_at','') !~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}T'
  then raise exception 'RP400: Complete saved photo version required'; end if;
  if length(p_manifest->>'image_file') > 140
    or length(p_manifest->>'original_file') > 140
    or length(p_manifest->>'created_at') > 40
    or coalesce(length(p_manifest->>'style'),0) > 100
    or coalesce(length(p_manifest->>'disclosure'),0) > 2000
    or coalesce(p_manifest->>'created_at','') !~
      '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(\.[0-9]+)?(Z|[+-][0-9]{2}:[0-9]{2})$'
    or exists (select 1 from jsonb_array_elements(p_manifest->'effects') e
      where jsonb_typeof(e.value) is distinct from 'string'
        or (e.value#>>'{}') !~ '^[a-z-]{1,32}$')
    or (select count(distinct e.value) from jsonb_array_elements(p_manifest->'effects') e)
      <> jsonb_array_length(p_manifest->'effects')
    or exists (select 1 from (values('parent_id'),('source_id'),('staging_base_id'),
      ('staging_reference_id')) ids(k) where p_manifest->ids.k <> 'null'::jsonb
      and coalesce(p_manifest->>ids.k,'') !~ '^[A-Za-z0-9-]{1,128}$')
    or (p_manifest->'provenance_id' <> 'null'::jsonb
      and coalesce(p_manifest->>'provenance_id','') !~*
        '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$')
    or (p_manifest->'provenance_recorded' = 'true'::jsonb
      and p_manifest->'provenance_id' = 'null'::jsonb)
  then raise exception 'RP400: Saved photo metadata exceeds its bound'; end if;
  v := p_manifest->>'version_id'; family := p_manifest->>'family_id'; edit := p_manifest->>'edit';
  if coalesce(p_manifest->>'original_file','') <> 'orig-' || family || '.jpg'
    or edit not in ('capture','capture-original','declutter','stage','sky','twilight','lawn','custom')
    or jsonb_typeof(p_manifest->'parent_id') not in ('null','string')
    or jsonb_typeof(p_manifest->'source_id') not in ('null','string')
    or jsonb_typeof(p_manifest->'staging_base_id') not in ('null','string')
    or jsonb_typeof(p_manifest->'staging_reference_id') not in ('null','string')
    or jsonb_typeof(p_manifest->'style') not in ('null','string')
    or jsonb_typeof(p_manifest->'disclosure') not in ('null','string')
    or jsonb_typeof(p_manifest->'provenance_id') not in ('null','string')
  then raise exception 'RP400: Invalid saved photo lineage'; end if;
  -- Lock the listing before access and commit. A concurrent listing move or
  -- delete cannot make an accepted manifest belong to a different library.
  perform 1 from public.listings where id = p_listing and org_id = p_org and deleted_at is null for share;
  perform public.client_listing_access(p_actor,p_org,p_listing,true);
  if public.listing_owner_library(p_listing) is distinct from p_library then
    raise exception 'RP404: This property is no longer in the selected library'; end if;
  if not public.native_photo_backup_asset_ready(p_org,p_listing,p_manifest->'image',p_actor)
    or not public.native_photo_backup_asset_ready(p_org,p_listing,p_manifest->'original',null)
  then raise exception 'RP409: The exact private photo upload is unavailable or incomplete'; end if;
  perform 1 from public.capture_assets
    where id in ((p_manifest#>>'{image,asset_id}')::uuid,
                 (p_manifest#>>'{original,asset_id}')::uuid)
    order by id for share;
  if not public.native_photo_backup_asset_ready(p_org,p_listing,p_manifest->'image',p_actor)
    or not public.native_photo_backup_asset_ready(p_org,p_listing,p_manifest->'original',null)
    or not public.studio_presenter_media_access((p_manifest#>>'{image,asset_id}')::uuid)
    or not public.studio_presenter_media_access((p_manifest#>>'{original,asset_id}')::uuid)
  then raise exception 'RP409: The exact private photo upload changed during commit'; end if;
  if edit = 'capture-original' then
    if v <> family || '-original' or p_manifest->>'image_file' <> p_manifest->>'original_file'
      or p_manifest->'image' <> p_manifest->'original'
      or p_manifest->'parent_id' <> 'null'::jsonb or p_manifest->'source_id' <> 'null'::jsonb
      or p_manifest->'staging_base_id' <> 'null'::jsonb or p_manifest->'staging_reference_id' <> 'null'::jsonb
      or p_manifest->'effects' <> '[]'::jsonb
    then raise exception 'RP400: Original source must bind the retained capture bytes'; end if;
  elsif edit = 'capture' then
    select * into source from public.native_photo_backup_versions
      where listing_id = p_listing and version_id = family || '-original' for share;
    if v <> family or p_manifest#>>'{image,content_type}' <> 'image/jpeg'
      or p_manifest->>'image_file' <> 'enh-' || family || '.jpg'
      or p_manifest->'parent_id' <> 'null'::jsonb or p_manifest->'source_id' <> 'null'::jsonb
      or p_manifest->'staging_base_id' <> 'null'::jsonb or p_manifest->'staging_reference_id' <> 'null'::jsonb
      or p_manifest->'effects' <> '[]'::jsonb
      or source.version_id is null or source.manifest->'original' <> p_manifest->'original'
    then raise exception 'RP409: Save the exact original source before its capture'; end if;
  else
    select * into root from public.native_photo_backup_versions
      where listing_id = p_listing and version_id = family and family_id = family for share;
    select * into parent from public.native_photo_backup_versions
      where listing_id = p_listing and version_id = p_manifest->>'parent_id' and family_id = family for share;
    select * into source from public.native_photo_backup_versions
      where listing_id = p_listing and version_id = p_manifest->>'source_id' and family_id = family for share;
    ext := case p_manifest#>>'{image,content_type}' when 'image/png' then 'png'
      when 'image/webp' then 'webp' else 'jpg' end;
    if root.version_id is null or parent.version_id is null or source.version_id is null
      or p_manifest#>>'{image,content_type}' not in ('image/jpeg','image/png','image/webp')
      or v = family or p_manifest->>'image_file' <> 'edit-' || v || '.' || ext
      or root.manifest->'original' <> p_manifest->'original'
      or not (p_manifest->'effects' ? edit)
      or (edit <> 'stage' and p_manifest->'staging_reference_id' <> 'null'::jsonb)
    then raise exception 'RP409: Save the exact parent and source before this edit'; end if;
    if p_manifest->'staging_base_id' <> 'null'::jsonb then
      select * into ref from public.native_photo_backup_versions
        where listing_id = p_listing and version_id = p_manifest->>'staging_base_id' and family_id = family for share;
      if ref.version_id is null then raise exception 'RP409: Save the staging base before this edit'; end if;
    end if;
    if p_manifest->'staging_reference_id' <> 'null'::jsonb then
      select * into ref from public.native_photo_backup_versions
        where listing_id = p_listing and version_id = p_manifest->>'staging_reference_id' for share;
      if ref.version_id is null or ref.manifest->>'edit' <> 'stage' then
        raise exception 'RP409: Save the reviewed staging reference before this edit'; end if;
    end if;
  end if;
  select * into prior from public.native_photo_backup_versions
    where listing_id = p_listing and version_id = v for share;
  if prior.version_id is not null then
    if prior.org_id is distinct from p_org or prior.library_org_id is distinct from p_library
      or prior.family_id is distinct from family or prior.manifest is distinct from p_manifest
    then raise exception 'RP409: This saved photo version has different immutable inputs'; end if;
    replay := true;
  else
    insert into public.native_photo_backup_versions
      (listing_id,version_id,family_id,actor_id,org_id,library_org_id,image_asset_id,original_asset_id,manifest)
    values (p_listing,v,family,p_actor,p_org,p_library,
      (p_manifest#>>'{image,asset_id}')::uuid,(p_manifest#>>'{original,asset_id}')::uuid,p_manifest)
    on conflict do nothing;
    replay := not found;
    select * into prior from public.native_photo_backup_versions
      where listing_id = p_listing and version_id = v;
    if prior.version_id is null or prior.org_id is distinct from p_org
      or prior.library_org_id is distinct from p_library or prior.family_id is distinct from family
      or prior.manifest is distinct from p_manifest
    then raise exception 'RP409: This saved photo version has different immutable inputs'; end if;
  end if;
  return jsonb_build_object('ok',true,'listing_id',p_listing,'version_id',v,'family_id',family,
    'manifest',prior.manifest,'replayed',replay,'available',true,'committed_at',prior.committed_at);
end$$;
revoke all on function public.native_photo_backup_commit(uuid,uuid,uuid,uuid,jsonb)
  from public, anon, authenticated;
grant execute on function public.native_photo_backup_commit(uuid,uuid,uuid,uuid,jsonb) to service_role;

create or replace function public.native_photo_backup_read(
  p_actor uuid, p_org uuid, p_library uuid, p_listing uuid,
  p_version text default null, p_offset integer default 0
) returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare result jsonb; more boolean; next_offset integer;
begin
  if current_setting('role',true) is distinct from 'service_role' then raise insufficient_privilege; end if;
  if p_actor is null or p_org is null or p_library is null or p_listing is null
    or p_offset is null or p_offset < 0 or p_offset > 10000 or p_offset % 50 <> 0
    or (p_version is not null and (p_version !~ '^[A-Za-z0-9-]{1,128}$' or p_offset <> 0))
  then raise exception 'RP400: Choose a valid saved photo page'; end if;
  perform public.client_listing_access(p_actor,p_org,p_listing,false);
  if public.listing_owner_library(p_listing) is distinct from p_library then
    raise exception 'RP404: This property is no longer in the selected library'; end if;
  with page as (
    select * from public.native_photo_backup_versions
    where listing_id = p_listing and org_id = p_org and library_org_id = p_library
      and (p_version is null or version_id = p_version)
    order by committed_at, version_id limit 51 offset p_offset
  ), numbered as (select *, row_number() over (order by committed_at,version_id) as n from page)
  select coalesce(jsonb_agg(jsonb_build_object(
      'listing_id',p_listing,'version_id',version_id,'family_id',family_id,'manifest',manifest,
      'available',public.native_photo_backup_asset_ready(p_org,p_listing,manifest->'image',null)
        and public.native_photo_backup_asset_ready(p_org,p_listing,manifest->'original',null)
        and public.studio_presenter_media_access(image_asset_id)
        and public.studio_presenter_media_access(original_asset_id),
      'committed_at',committed_at) order by committed_at,version_id)
      filter (where n <= 50),'[]'::jsonb), bool_or(n = 51)
    into result, more from numbered;
  next_offset := case when p_offset < 10000 and coalesce(more,false) then p_offset + 50 else null end;
  return jsonb_build_object('ok',true,'listing_id',p_listing,'versions',result,'next_offset',next_offset);
end$$;
revoke all on function public.native_photo_backup_read(uuid,uuid,uuid,uuid,text,integer)
  from public, anon, authenticated;
grant execute on function public.native_photo_backup_read(uuid,uuid,uuid,uuid,text,integer) to service_role;

-- Reinstall restoration resolves a requested asset only through a committed
-- version in the currently selected listing. Storage keys never come from the
-- client, and the public handler redacts the key after minting a short URL.
create or replace function public.native_photo_backup_download(
  p_actor uuid, p_org uuid, p_library uuid, p_listing uuid, p_asset uuid
) returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare a public.capture_assets; receipt jsonb; visible jsonb;
begin
  if current_setting('role',true) is distinct from 'service_role' then raise insufficient_privilege; end if;
  if p_actor is null or p_org is null or p_library is null or p_listing is null or p_asset is null
  then raise exception 'RP400: Choose one saved photo asset'; end if;
  perform public.client_listing_access(p_actor,p_org,p_listing,false);
  if public.listing_owner_library(p_listing) is distinct from p_library then
    raise exception 'RP404: This property is no longer in the selected library'; end if;
  select case when v.image_asset_id = p_asset then v.manifest->'image' else v.manifest->'original' end
    into receipt from public.native_photo_backup_versions v
    where v.listing_id = p_listing and v.org_id = p_org and v.library_org_id = p_library
      and p_asset in (v.image_asset_id,v.original_asset_id)
    order by v.committed_at,v.version_id limit 1;
  if receipt is null or not public.native_photo_backup_asset_ready(p_org,p_listing,receipt,null) then
    raise exception 'RP404: Saved photo asset is unavailable'; end if;
  select * into a from public.capture_assets where id = p_asset and listing_id = p_listing;
  if a.id is null or a.storage_key is null then raise exception 'RP404: Saved photo asset is unavailable'; end if;
  visible := public.studio_presenter_media_visibility(p_listing,array[p_asset],'{}'::uuid[],array[a.storage_key]);
  if visible#>array['assets',p_asset::text] is distinct from 'true'::jsonb
    or visible#>array['keys',a.storage_key] is distinct from 'true'::jsonb
  then raise exception 'RP404: Saved photo asset is unavailable'; end if;
  return jsonb_build_object('ok',true,'listing_id',p_listing,'asset_id',p_asset,
    'sha256',receipt->>'sha256','bytes',(receipt->>'bytes')::bigint,
    'content_type',receipt->>'content_type','bucket','uploads','storage_key',a.storage_key);
end$$;
revoke all on function public.native_photo_backup_download(uuid,uuid,uuid,uuid,uuid)
  from public, anon, authenticated;
grant execute on function public.native_photo_backup_download(uuid,uuid,uuid,uuid,uuid) to service_role;
commit;
