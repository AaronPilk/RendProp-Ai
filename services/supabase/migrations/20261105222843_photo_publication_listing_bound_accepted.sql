-- A reviewed edit of a photo already in a listing has listing-bound evidence.
-- The original publication bridge admitted only account-library (NULL-listing)
-- evidence. Preserve that path, and admit the listing-bound path only when its
-- actor, library, original upload, accepted QC, and exact output agree.
begin;

do $repair$
declare
  f record;
  d text;
  needle text;
  replacement text;
  before_metadata jsonb;
begin
  for f in select * from (values
    ('public.photo_publication_receipt_shape(jsonb)', 'c76cf415717510e7d628376773ebdb76'),
    ('public.photo_publication_source(uuid,uuid,uuid,uuid)', 'a2c46b643f5ecf6c8a3ee94bf7f56bb8'),
    ('public.photo_publication_resolve(uuid,uuid,uuid,uuid,uuid,uuid,jsonb)', 'c3f8373eb4b61a523fab595f3fff1950'),
    ('public.photo_publication_reserve_locked(uuid,uuid,uuid,uuid,uuid,uuid,jsonb,jsonb,jsonb,uuid)', '6f8783344a73771c6f61bd9a0ae1c8e0'),
    ('public.photo_publication_metadata_valid(uuid)', 'c849f4a4a614e0711914c216393f1189')
  ) v(signature, digest) loop
    if to_regprocedure(f.signature) is null or
      (select md5(prosrc) from pg_proc where oid=to_regprocedure(f.signature)) is distinct from f.digest then
      raise exception 'Review changed accepted-photo publication authority: %', f.signature;
    end if;
  end loop;

  -- Receipt source listing is either NULL (existing library edit) or the
  -- identical target listing. The target UUID is already shape-validated.
  select to_jsonb(p)-'prosrc', pg_get_functiondef(p.oid) into before_metadata,d
  from pg_proc p where p.oid='public.photo_publication_receipt_shape(jsonb)'::regprocedure;
  needle:='or p#>''{source,listing_id}''is distinct from''null''::jsonb';
  replacement:='or (p#>''{source,listing_id}'' is distinct from ''null''::jsonb and p#>''{source,listing_id}'' is distinct from p#>''{target,listing_id}'')';
  if length(d)-length(replace(d,needle,''))<>length(needle) then raise exception 'Review publication receipt listing seam'; end if;
  execute replace(d,needle,replacement);
  if (select to_jsonb(p)-'prosrc' from pg_proc p where p.oid='public.photo_publication_receipt_shape(jsonb)'::regprocedure) is distinct from before_metadata then
    raise exception 'Publication receipt metadata changed';
  end if;

  select to_jsonb(p)-'prosrc', pg_get_functiondef(p.oid) into before_metadata,d
  from pg_proc p where p.oid='public.photo_publication_source(uuid,uuid,uuid,uuid)'::regprocedure;
  needle:='c jsonb;prefix text;'; replacement:='c jsonb;a public.capture_assets;prefix text;';
  if length(d)-length(replace(d,needle,''))<>length(needle) then raise exception 'Review publication source declaration seam'; end if;
  d:=replace(d,needle,replacement);
  needle:='or e.listing_id is not null or e.purpose is distinct from''prospective''';
  replacement:='or e.purpose is distinct from''prospective''';
  if length(d)-length(replace(d,needle,''))<>length(needle) then raise exception 'Review publication source scope seam'; end if;
  d:=replace(d,needle,replacement);
  needle:='or e.original_asset_id is not null or e.original_reference is not null or m.id is null or m.org_id is distinct from e.org_id or m.listing_id is not null';
  replacement:='or m.id is null or m.org_id is distinct from e.org_id';
  if length(d)-length(replace(d,needle,''))<>length(needle) then raise exception 'Review publication source identity seam'; end if;
  d:=replace(d,needle,replacement);
  needle:='if not exists(select 1 from auth.users u join public.profiles p on p.id=u.id where u.id=p_actor and not u.is_anonymous)';
  replacement:=$scope$
 if e.listing_id is null then
  if e.original_asset_id is not null or e.original_reference is not null or m.listing_id is not null then
   raise exception 'RP404: This saved photo is unavailable for publication';
  end if;
 else
  if e.original_asset_id is null or jsonb_typeof(e.original_reference) is distinct from 'object'
   or m.listing_id is distinct from e.listing_id or m.original_key is distinct from e.original_reference->>'storage_key'
   or e.original_reference->>'asset_id' is distinct from e.original_asset_id::text
   or e.original_reference->>'actor_id' is distinct from p_actor::text
   or e.original_reference->>'org_id' is distinct from p_org::text
   or e.original_reference->>'listing_id' is distinct from e.listing_id::text then
   raise exception 'RP404: This saved photo is unavailable for publication';
  end if;
  c:=public.listing_library_scope(p_actor,e.listing_id);
  if c is null or c->>'can_write' is distinct from 'true'
   or c->>'org_id' is distinct from p_org::text
   or c->>'library_org_id' is distinct from p_library::text then
   raise exception 'RP404: This saved photo is unavailable for publication';
  end if;
  select * into a from public.capture_assets where id=e.original_asset_id;
  if a.id is null or a.listing_id is distinct from e.listing_id or a.kind is distinct from 'photo'
   or (a.bucket is distinct from 'renders' and a.bucket is distinct from 'uploads')
   or a.transport_version is distinct from 2
   or a.uploaded is distinct from true or a.upload_aborted is distinct from false
   or a.storage_key is distinct from e.original_reference->>'storage_key'
   or coalesce(a.storage_key !~ ('^'||a.bucket||'/'||p_org::text||'/'||e.listing_id::text||'/[^/]+$'),true)
   or a.sha256 is distinct from e.original_reference->>'sha256'
   or to_jsonb(a.bytes) is distinct from e.original_reference->'bytes'
   or a.content_type is distinct from e.original_reference->>'content_type'
   or a.bucket is distinct from e.original_reference->>'bucket'
   or not public.studio_presenter_media_access(a.id)
   or not exists(select 1 from public.upload_reservations r where r.asset_id=a.id
      and r.actor_id=p_actor and r.org_id=p_org and r.listing_id=e.listing_id and r.state='completed')
   or not exists(select 1 from public.upload_operations o where o.asset_id=a.id
      and o.kind='copy' and o.part=0 and o.state='retained' and o.bucket=a.bucket
      and o.object_key=a.storage_key and o.expected_bytes=a.bytes and o.content_type=a.content_type
      and o.etag=e.original_reference->>'etag') then
   raise exception 'RP404: This saved photo is unavailable for publication';
  end if;
 end if;
 if not exists(select 1 from auth.users u join public.profiles p on p.id=u.id where u.id=p_actor and not u.is_anonymous)$scope$;
  if length(d)-length(replace(d,needle,''))<>length(needle) then raise exception 'Review publication source custody seam'; end if;
  d:=replace(d,needle,replacement);
  -- The prepared input of a listing-bound edit is retained by exact evidence
  -- and physically hash-checked by Edge, but is not a private_ai_outputs row.
  needle:='or not exists(select 1 from public.private_ai_outputs where user_id=p_actor and org_id=p_org and listing_id is null and bucket=''renders''and storage_key=e.input->>''key''and bytes=(e.input->>''bytes'')::bigint)';
  replacement:='or (e.listing_id is null and not exists(select 1 from public.private_ai_outputs where user_id=p_actor and org_id=p_org and listing_id is null and bucket=''renders''and storage_key=e.input->>''key''and bytes=(e.input->>''bytes'')::bigint))';
  if length(d)-length(replace(d,needle,''))<>length(needle) then raise exception 'Review publication input custody seam'; end if;
  d:=replace(d,needle,replacement);
  needle:='where user_id=p_actor and org_id=p_org and listing_id is null and bucket=''renders''and storage_key=e.output->>''key''';
  replacement:='where user_id=p_actor and org_id=p_org and listing_id is not distinct from e.listing_id and bucket=''renders''and storage_key=e.output->>''key''';
  if length(d)-length(replace(d,needle,''))<>length(needle) then raise exception 'Review publication output custody seam'; end if;
  execute d;
  if (select to_jsonb(p)-'prosrc' from pg_proc p where p.oid='public.photo_publication_source(uuid,uuid,uuid,uuid)'::regprocedure) is distinct from before_metadata then
    raise exception 'Publication source metadata changed';
  end if;

  select to_jsonb(p)-'prosrc', pg_get_functiondef(p.oid) into before_metadata,d
  from pg_proc p where p.oid='public.photo_publication_resolve(uuid,uuid,uuid,uuid,uuid,uuid,jsonb)'::regprocedure;
  needle:='s:=public.photo_publication_source(p_actor,p_org,p_library,e.id);';
  replacement:='if e.listing_id is not null and e.listing_id is distinct from (t->>''listing_id'')::uuid then raise exception ''RP404: This saved photo is unavailable for publication'';end if;'||E'\n '||needle;
  if length(d)-length(replace(d,needle,''))<>length(needle) then raise exception 'Review publication resolve listing seam'; end if;
  execute replace(d,needle,replacement);
  if (select to_jsonb(p)-'prosrc' from pg_proc p where p.oid='public.photo_publication_resolve(uuid,uuid,uuid,uuid,uuid,uuid,jsonb)'::regprocedure) is distinct from before_metadata then
    raise exception 'Publication resolve metadata changed';
  end if;

  select to_jsonb(p)-'prosrc', pg_get_functiondef(p.oid) into before_metadata,d
  from pg_proc p where p.oid='public.photo_publication_reserve_locked(uuid,uuid,uuid,uuid,uuid,uuid,jsonb,jsonb,jsonb,uuid)'::regprocedure;
  needle:='''library_org_id'',p_library,''listing_id'',null,';
  replacement:='''library_org_id'',p_library,''listing_id'',s#>''{evidence,listing_id}'',';
  if length(d)-length(replace(d,needle,''))<>length(needle) then raise exception 'Review publication reserve listing seam'; end if;
  execute replace(d,needle,replacement);
  if (select to_jsonb(p)-'prosrc' from pg_proc p where p.oid='public.photo_publication_reserve_locked(uuid,uuid,uuid,uuid,uuid,uuid,jsonb,jsonb,jsonb,uuid)'::regprocedure) is distinct from before_metadata then
    raise exception 'Publication reserve metadata changed';
  end if;

  select to_jsonb(p)-'prosrc', pg_get_functiondef(p.oid) into before_metadata,d
  from pg_proc p where p.oid='public.photo_publication_metadata_valid(uuid)'::regprocedure;
  needle:='if m.org_id::text is distinct from p#>>''{target,org_id}''';
  replacement:='if p#>''{source,listing_id}'' is distinct from s#>''{evidence,listing_id}'' or m.org_id::text is distinct from p#>>''{target,org_id}''';
  if length(d)-length(replace(d,needle,''))<>length(needle) then raise exception 'Review publication metadata listing seam'; end if;
  execute replace(d,needle,replacement);
  if (select to_jsonb(p)-'prosrc' from pg_proc p where p.oid='public.photo_publication_metadata_valid(uuid)'::regprocedure) is distinct from before_metadata then
    raise exception 'Publication metadata changed';
  end if;
end
$repair$;
commit;
