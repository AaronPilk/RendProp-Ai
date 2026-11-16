-- Point authority for the existing private gateway thumbnail checks. The
-- complete public-tour authority remains the fallback for legacy ambiguity.
begin;
do $guard$begin
  if to_regprocedure('public.published_photo_delivery(text,text,bigint)')is not null and
    (select md5(prosrc)from pg_proc where oid=to_regprocedure('public.published_photo_delivery(text,text,bigint)'))is distinct from '697064876c48da88c0b46f8829b55b75'then
    raise exception 'Review changed published photo authority before replay';end if;
end$guard$;
create or replace function public.published_photo_delivery(p_slug text,p_key text,p_bytes bigint default 0)
returns jsonb language plpgsql volatile security definer set search_path='' as $function$
declare
  r public.renders%rowtype;l public.listings%rowtype;a public.capture_assets%rowtype;
  original public.capture_assets%rowtype;p public.media_provenance%rowtype;
  photo_ids uuid[];original_ids uuid[];provenance_ids uuid[];asset_refs uuid[];key_refs text[];
  r_snapshot jsonb;l_snapshot jsonb;a_snapshot jsonb;p_snapshot jsonb;original_snapshot jsonb;
  current_snapshot jsonb;visible jsonb;hosting jsonb;admission jsonb;prefix text;mime text;
  phase integer;
begin
  if current_setting('role',true) is distinct from 'service_role' then raise insufficient_privilege;end if;
  if p_slug is null or p_slug !~ '^[A-Za-z0-9_-]{1,64}$'or p_key is null or length(p_key)not between 1 and 1024
    or p_bytes is null or p_bytes not between 0 and 2097152 then raise exception 'RP400: Use one bounded published photo';end if;
  if p_key ~ '[[:cntrl:]]'or position(chr(92)in p_key)>0 or position('%'in p_key)>0 or position('?'in p_key)>0
    or position('#'in p_key)>0 or exists(select 1 from unnest(string_to_array(p_key,'/'))s where s in('','.','..'))then
    raise exception 'RP400: Use an exact published photo key';end if;
  select *into r from public.renders where slug=p_slug and published_at is not null;
  if not found then raise exception 'RP404: This photo is no longer published';end if;
  select x.*into l from public.listings x join public.orgs o on o.id=x.org_id
    where x.id=r.listing_id and x.deleted_at is null and o.deleted_at is null;
  if not found then raise exception 'RP404: This photo is no longer published';end if;
  -- Match the old JavaScript descriptor parser: nested/oversized/null-item
  -- arrays delegate, while an explicit empty selection remains authoritative.
  if l.gallery_asset_ids is not null and coalesce(array_ndims(l.gallery_asset_ids),1)>1 then return null;end if;
  if l.gallery_asset_ids is not null and(cardinality(l.gallery_asset_ids)>100 or array_position(l.gallery_asset_ids,null)is not null)then return null;end if;
  prefix:='renders/'||l.org_id::text||'/'||l.id::text||'/gallery-';
  if not starts_with(p_key,prefix)or length(p_key)>500 or length(p_key)=length(prefix)
    or position('/'in substr(p_key,length(prefix)+1))>0 then
    -- A foreign canonical key is positively outside this published property.
    if p_key ~* '^(uploads|renders)/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/'
      and not(starts_with(p_key,'renders/'||l.org_id::text||'/'||l.id::text||'/')
        or starts_with(p_key,'uploads/'||l.org_id::text||'/'||l.id::text||'/'))then
      raise exception 'RP404: This photo does not belong to this property';end if;
    return null;
  end if;
  select array_agg(id order by id)into photo_ids from
    (select id from public.capture_assets where listing_id=l.id and storage_key=p_key order by id limit 2)s;
  if coalesce(cardinality(photo_ids),0)=0 then raise exception 'RP404: This photo is no longer published';end if;
  select *into a from public.capture_assets where id=photo_ids[1];
  if a.kind<>'photo'or a.bucket is distinct from 'renders'or a.uploaded is not true or a.upload_aborted is true then
    raise exception 'RP404: This photo is no longer published';end if;
  if l.gallery_asset_ids is not null then
    if not coalesce(a.id=any(l.gallery_asset_ids),false)then raise exception 'RP404: This photo is no longer selected';end if;
  elsif l.main_photo_key is distinct from p_key and not exists(select 1 from
      (select id from public.capture_assets where listing_id=l.id and kind='photo'and bucket='renders'and uploaded
        and storage_key like '%/gallery-%'order by created_at,id limit 100)s where s.id=a.id)then
    raise exception 'RP404: This photo is not in the published gallery';
  end if;
  asset_refs:=photo_ids;key_refs:=array[p_key];
  visible:=public.studio_presenter_media_visibility(l.id,asset_refs,array[r.id],key_refs);
  if visible#>array['renders',r.id::text]is distinct from 'true'::jsonb
    or exists(select 1 from unnest(asset_refs)i where visible#>array['assets',i::text]is distinct from 'true'::jsonb)
    or visible#>array['keys',p_key]is distinct from 'true'::jsonb then raise exception 'RP404: This media is no longer available';end if;
  if cardinality(photo_ids)<>1 then return null;end if;
  mime:=lower(trim(split_part(coalesce(a.content_type,''),';',1)));
  if a.bytes is null or a.bytes not between 1 and 20000000 or mime not in('image/jpeg','image/png','image/webp','image/avif')then return null;end if;
  -- Absence is a successful exact database lookup, not a guessed Original
  -- classification. Positively foreign/revoked sources fail closed below;
  -- canonically visible historical keys without a row retain normal fallback.
  select array_agg(id order by id)into provenance_ids from
    (select id from public.media_provenance where listing_id=l.id and altered_key=p_key order by id limit 2)s;
  if coalesce(cardinality(provenance_ids),0)>1 then return null;end if;
  if cardinality(provenance_ids)=1 then
    select *into p from public.media_provenance where id=provenance_ids[1];
    if p.org_id is distinct from l.org_id then raise exception 'RP404: This photo source is no longer available';end if;
    if p.original_key is null then return null;end if;
    if not(starts_with(p.original_key,'renders/'||l.org_id::text||'/'||l.id::text||'/')
      or starts_with(p.original_key,'uploads/'||l.org_id::text||'/'||l.id::text||'/'))then
      if p.original_key ~* '^(uploads|renders)/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/'then
        raise exception 'RP404: This photo source does not belong to this property';end if;
      return null;
    end if;
    if length(p.original_key)>1024 or p.original_key ~ '[[:cntrl:]]'or position(chr(92)in p.original_key)>0 or position('%'in p.original_key)>0
      or position('?'in p.original_key)>0 or position('#'in p.original_key)>0
      or exists(select 1 from unnest(string_to_array(p.original_key,'/'))s where s in('','.','..'))then return null;end if;
    select array_agg(id order by id)into original_ids from
      (select id from public.capture_assets where listing_id=l.id and storage_key=p.original_key order by id limit 2)s;
    if coalesce(cardinality(original_ids),0)=0 then
      -- The generic authority permits a canonically visible historical key
      -- without a surviving capture row. Do not add a new publication policy.
      visible:=public.studio_presenter_media_visibility(l.id,asset_refs,array[r.id],array[p_key,p.original_key]);
      if visible#>array['keys',p.original_key]is distinct from 'true'::jsonb
        or visible#>array['keys',p_key]is distinct from 'true'::jsonb
        or visible#>array['renders',r.id::text]is distinct from 'true'::jsonb
        or exists(select 1 from unnest(asset_refs)i where visible#>array['assets',i::text]is distinct from 'true'::jsonb)then
        raise exception 'RP404: This media is no longer available';end if;
      return null;
    end if;
    select *into original from public.capture_assets where id=original_ids[1];
    if original.kind<>'photo'or original.bucket is distinct from split_part(p.original_key,'/',1)or original.uploaded is not true or original.upload_aborted is true then
      raise exception 'RP404: This photo source is no longer available';end if;
    asset_refs:=asset_refs||original_ids;key_refs:=key_refs||p.original_key;
    visible:=public.studio_presenter_media_visibility(l.id,asset_refs,array[r.id],key_refs);
    if exists(select 1 from unnest(asset_refs)i where visible#>array['assets',i::text]is distinct from 'true'::jsonb)
      or exists(select 1 from unnest(key_refs)k where visible#>array['keys',k]is distinct from 'true'::jsonb)
      or visible#>array['renders',r.id::text]is distinct from 'true'::jsonb then raise exception 'RP404: This media is no longer available';end if;
    if cardinality(original_ids)<>1 then return null;end if;
    p_snapshot:=to_jsonb(p);original_snapshot:=to_jsonb(original);
  end if;
  r_snapshot:=to_jsonb(r);l_snapshot:=jsonb_build_object('id',l.id,'org_id',l.org_id,'deleted_at',l.deleted_at,
    'gallery_asset_ids',l.gallery_asset_ids,'main_photo_key',l.main_photo_key);a_snapshot:=to_jsonb(a);
  for phase in 1..2 loop
    hosting:=public.hosting_retention_state(l.org_id);
    if hosting->>'org_id'is distinct from l.org_id::text or jsonb_typeof(hosting->'hosting_available')is distinct from 'boolean'
      or not(hosting?'retention_ends_at')or jsonb_typeof(hosting->'protected')is distinct from 'boolean'or coalesce(hosting->>'policy','')not in('preserved','prospective_90_day_grace')then
      raise exception 'RP503: Hosting status could not be verified';end if;
    if not((hosting->>'policy'='preserved'and hosting->>'retention_ends_at'is null and hosting->>'hosting_available'='true')
      or(hosting->>'policy'='prospective_90_day_grace'and hosting->>'protected'='false'
        and jsonb_typeof(hosting->'retention_ends_at')='string'))then raise exception 'RP503: Hosting status could not be verified';end if;
    if hosting->>'retention_ends_at'is not null and not isfinite((hosting->>'retention_ends_at')::timestamptz)then
      raise exception 'RP503: Hosting status could not be verified';end if;
    if hosting->>'hosting_available'<>'true'or(hosting->>'retention_ends_at'is not null
      and(hosting->>'retention_ends_at')::timestamptz<=clock_timestamp())then raise exception 'RP404: This tour is no longer hosted';end if;
    if phase=2 then exit;end if;
    admission:=public.media_delivery_admit(l.org_id,p_bytes,true);
    if admission->'admitted'is distinct from 'true'::jsonb or admission->'legacy_unbudgeted'is distinct from 'false'::jsonb
      or(admission->>'basis'='product_media_serving'and(admission->'financial_budget_bypassed'is distinct from 'true'::jsonb
        or admission->>'infrastructure_cost'is distinct from 'unpriced'or admission->'request_counted'is distinct from 'true'::jsonb
        or admission->'bytes_counted'is distinct from to_jsonb(p_bytes)))then raise exception 'RP503: Media admission could not be verified';end if;
    select to_jsonb(x)into current_snapshot from public.renders x where x.id=r.id;
    if current_snapshot is distinct from r_snapshot then raise exception 'RP404: The published photo changed';end if;
    select jsonb_build_object('id',x.id,'org_id',x.org_id,'deleted_at',x.deleted_at,'gallery_asset_ids',x.gallery_asset_ids,
      'main_photo_key',x.main_photo_key)into current_snapshot from public.listings x where x.id=l.id;
    if current_snapshot is distinct from l_snapshot then raise exception 'RP404: The published photo selection changed';end if;
    select to_jsonb(x)into current_snapshot from public.capture_assets x where x.id=a.id;
    if current_snapshot is distinct from a_snapshot then raise exception 'RP404: The published photo source changed';end if;
    if p.id is null then
      if exists(select 1 from public.media_provenance where listing_id=l.id and altered_key=p_key)then raise exception 'RP404: The photo lineage changed';end if;
    else
      select to_jsonb(x)into current_snapshot from public.media_provenance x where x.id=p.id;
      if current_snapshot is distinct from p_snapshot or exists(select 1 from public.media_provenance where listing_id=l.id and altered_key=p_key and id<>p.id)then
        raise exception 'RP404: The photo lineage changed';end if;
      select to_jsonb(x)into current_snapshot from public.capture_assets x where x.id=original.id;
      if current_snapshot is distinct from original_snapshot then raise exception 'RP404: The retained original changed';end if;
    end if;
    if l.gallery_asset_ids is null and l.main_photo_key is distinct from p_key and not exists(select 1 from
      (select id from public.capture_assets where listing_id=l.id and kind='photo'and bucket='renders'and uploaded
        and storage_key like '%/gallery-%'order by created_at,id limit 100)s where s.id=a.id)then
      raise exception 'RP404: This photo is no longer in the published gallery';end if;
    visible:=public.studio_presenter_media_visibility(l.id,asset_refs,array[r.id],key_refs);
    if exists(select 1 from unnest(asset_refs)i where visible#>array['assets',i::text]is distinct from 'true'::jsonb)
      or exists(select 1 from unnest(key_refs)k where visible#>array['keys',k]is distinct from 'true'::jsonb)
      or visible#>array['renders',r.id::text]is distinct from 'true'::jsonb then raise exception 'RP404: This media is no longer available';end if;
  end loop;
  return jsonb_build_object('schema',1,'slug',p_slug,'objects',jsonb_build_object(p_key,'renders'),'stream_uid',null);
end;
$function$;
revoke all on function public.published_photo_delivery(text,text,bigint)from public,anon,authenticated;
grant execute on function public.published_photo_delivery(text,text,bigint)to service_role;
commit;
