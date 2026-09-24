-- New capabilities must respect revoked Presenter ancestry even after a native
-- render or a declared browser/reflection edit copied the accepted output.
-- Previously downloaded or externally published bytes cannot be recalled.
begin;
-- Only source identity and the already-owned object key are retained. History
-- rows may cascade with their author while shared-workspace media survives.
-- No capture FK: intermediate deleted source UUIDs must still lead to ancestry.
create table if not exists public.studio_presenter_media_sources (
 listing_id uuid not null references public.listings(id) on delete cascade,
 asset_id uuid not null,
 source_asset_id uuid not null,
 storage_key text not null,
 primary key(asset_id,source_asset_id)
);
create index if not exists studio_presenter_media_sources_key on public.studio_presenter_media_sources(listing_id,storage_key);
alter table public.studio_presenter_media_sources enable row level security;
revoke all on public.studio_presenter_media_sources from public,anon,authenticated;
grant select,insert,update,delete on public.studio_presenter_media_sources to service_role;
create or replace function public.studio_presenter_record_media_sources()
returns trigger language plpgsql security definer set search_path='' as $$
declare a public.capture_assets%rowtype; source_id text; b public.video_erase_batches%rowtype;
begin
 if tg_table_name='studio_creative_results' then
  if new.kind<>'video' or new.metadata->>'video_kind' is distinct from 'edit' or
    jsonb_typeof(new.metadata->'source_asset_ids') is distinct from 'array' then return new; end if;
  select * into a from public.capture_assets where id::text=new.metadata->>'asset_id' and listing_id=new.listing_id;
  if not found then return new; end if;
  for source_id in select jsonb_array_elements_text(new.metadata->'source_asset_ids') loop
   if source_id ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then
    insert into public.studio_presenter_media_sources(listing_id,asset_id,source_asset_id,storage_key)
     values(a.listing_id,a.id,source_id::uuid,a.storage_key) on conflict do nothing;
   end if;
  end loop;
 else
  if tg_table_name='video_erase_jobs' then select * into b from public.video_erase_batches where id=new.batch_id; else b:=new; end if;
  if b.altered_asset_id is null then return new; end if;
  select * into a from public.capture_assets where id=b.altered_asset_id and listing_id=b.listing_id;
  if not found then return new; end if;
  insert into public.studio_presenter_media_sources(listing_id,asset_id,source_asset_id,storage_key)
   select a.listing_id,a.id,source,a.storage_key from (
    select b.original_asset_id source where b.original_asset_id is not null
    union select asset_id from public.video_erase_jobs where batch_id=b.id) s on conflict do nothing;
 end if;
 return new;
end;
$$;
revoke all on function public.studio_presenter_record_media_sources() from public,anon,authenticated;
drop trigger if exists presenter_media_sources on public.studio_creative_results;
create trigger presenter_media_sources after insert or update on public.studio_creative_results for each row execute function public.studio_presenter_record_media_sources();
drop trigger if exists presenter_media_sources on public.video_erase_batches;
create trigger presenter_media_sources after insert or update on public.video_erase_batches for each row execute function public.studio_presenter_record_media_sources();
drop trigger if exists presenter_media_sources on public.video_erase_jobs;
create trigger presenter_media_sources after insert or update on public.video_erase_jobs for each row execute function public.studio_presenter_record_media_sources();
insert into public.studio_presenter_media_sources(listing_id,asset_id,source_asset_id,storage_key)
 select a.listing_id,a.id,s.id::uuid,a.storage_key from public.studio_creative_results r
 join public.capture_assets a on a.id::text=r.metadata->>'asset_id' and a.listing_id=r.listing_id
 cross join lateral jsonb_array_elements_text(case when jsonb_typeof(r.metadata->'source_asset_ids')='array' then r.metadata->'source_asset_ids' else '[]'::jsonb end) s(id)
 where r.kind='video' and r.metadata->>'video_kind'='edit' and s.id ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' on conflict do nothing;
insert into public.studio_presenter_media_sources(listing_id,asset_id,source_asset_id,storage_key)
 select a.listing_id,a.id,s.id,a.storage_key from public.video_erase_batches b
 join public.capture_assets a on a.id=b.altered_asset_id and a.listing_id=b.listing_id
 cross join lateral (select b.original_asset_id id where b.original_asset_id is not null union select j.asset_id from public.video_erase_jobs j where j.batch_id=b.id) s on conflict do nothing;
create or replace function public.studio_presenter_media_access_inner(p_asset uuid)
returns boolean language plpgsql security definer set search_path='' as $$
declare todo uuid[]:=array[p_asset]; seen uuid[]:='{}'; current_id uuid; a public.capture_assets%rowtype;
 result record; source_id text; source_uuid uuid; edges uuid[]; origin_listing uuid;
begin
 if p_asset is null then return false; end if;
 select listing_id into origin_listing from public.capture_assets where id=p_asset;
 while cardinality(todo)>0 loop
  current_id:=todo[1];todo:=todo[2:];
  if current_id=any(seen) then continue; end if;
  seen:=array_append(seen,current_id);
  if cardinality(seen)>200 then return false; end if;
  select * into a from public.capture_assets where id=current_id;
  if not found then
   -- A Presenter import can be removed by its owner but its durable ledger
   -- still proves the identity. Ordinary old missing sources keep legacy read
   -- behavior; publishing continues to use its existing stronger quality gate.
   if current_id=p_asset or exists(select 1 from public.studio_presenter_jobs where import_asset_id=current_id) then return false; end if;
  end if;
  edges:=array(select source_asset_id from public.studio_presenter_media_sources where asset_id=current_id and listing_id=origin_listing);
  if a.id is not null then
  if a.listing_id<>origin_listing then return false; end if;
  if a.presenter_job_id is not null and not public.studio_presenter_asset_access(a.id) then return false; end if;
  for result in select metadata from public.studio_creative_results where kind='video' and listing_id=a.listing_id
    and metadata->>'video_kind'='edit' and metadata->>'asset_id'=a.id::text loop
   if jsonb_typeof(result.metadata->'source_asset_ids') is distinct from 'array' or jsonb_array_length(result.metadata->'source_asset_ids') not between 1 and 24 then return false; end if;
   for source_id in select jsonb_array_elements_text(result.metadata->'source_asset_ids') loop
    if source_id is null or source_id !~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then return false; end if;
    edges:=array_append(edges,source_id::uuid);
   end loop;
  end loop;
  -- Accepted reflection assembly binds the original full video and every
  -- edited clip. A later source revocation applies to that accepted derivative.
  for result in select b.original_asset_id,j.asset_id from public.video_erase_batches b left join public.video_erase_jobs j on j.batch_id=b.id
    where b.altered_asset_id=a.id and b.listing_id=a.listing_id loop
   if result.original_asset_id is not null then edges:=array_append(edges,result.original_asset_id); end if;
   if result.asset_id is not null then edges:=array_append(edges,result.asset_id); end if;
  end loop;
  end if;
  foreach source_uuid in array edges loop
   if not source_uuid=any(seen) and not source_uuid=any(todo) then todo:=array_append(todo,source_uuid); end if;
  end loop;
  if cardinality(todo)+cardinality(seen)>200 then return false; end if;
 end loop;
 return true;
end;
$$;
create or replace function public.studio_presenter_media_access(p_asset uuid)
returns boolean language plpgsql security definer set search_path='' as $$
declare org uuid;
begin
 select l.org_id into org from public.capture_assets a join public.listings l on l.id=a.listing_id join public.orgs o on o.id=l.org_id
  where a.id=p_asset and l.deleted_at is null and o.deleted_at is null;
 if org is null then return false; end if;
 if current_setting('role',true)='authenticated' and not exists(select 1 from public.memberships where org_id=org and user_id=auth.uid()) then return false; end if;
 return public.studio_presenter_media_access_inner(p_asset);
end;
$$;
create or replace function public.studio_presenter_render_access(p_render uuid)
returns boolean language plpgsql security definer set search_path='' as $$
declare asset uuid; org uuid;
begin
 select j.capture_asset_id,l.org_id into asset,org from public.renders r join public.render_jobs j on j.id=r.job_id
  join public.listings l on l.id=r.listing_id join public.orgs o on o.id=l.org_id where r.id=p_render and l.deleted_at is null and o.deleted_at is null;
 if org is null then return false; end if;
 if current_setting('role',true)='authenticated' and not exists(select 1 from public.memberships where org_id=org and user_id=auth.uid()) then return false; end if;
 return asset is null or public.studio_presenter_media_access_inner(asset);
end;
$$;
create or replace function public.studio_presenter_key_access(p_listing uuid,p_key text)
returns boolean language plpgsql security definer set search_path='' as $$
declare org uuid; item record;
begin
 select l.org_id into org from public.listings l join public.orgs o on o.id=l.org_id where l.id=p_listing and l.deleted_at is null and o.deleted_at is null;
 if org is null or p_key is null or length(p_key)>1024 or not (p_key like 'uploads/'||org::text||'/'||p_listing::text||'/%' or p_key like 'renders/'||org::text||'/'||p_listing::text||'/%') then return false; end if;
 if current_setting('role',true)='authenticated' and not exists(select 1 from public.memberships where org_id=org and user_id=auth.uid()) then return false; end if;
 for item in select id from public.capture_assets where listing_id=p_listing and storage_key=p_key loop
  if not public.studio_presenter_media_access_inner(item.id) then return false; end if;
 end loop;
 -- Retained financial identity also guards a Presenter asset deleted from the
 -- property; cleanup may not yet have removed its public imported object.
 if exists(select 1 from public.studio_presenter_jobs j where j.listing_id=p_listing and j.import_storage_key=p_key and
   (j.state not in ('accepted','importing','imported') or not public.studio_presenter_job_valid(j))) then return false; end if;
 for item in select distinct asset_id from public.studio_presenter_media_sources where listing_id=p_listing and storage_key=p_key loop
  if not public.studio_presenter_media_access_inner(item.asset_id) then return false; end if;
 end loop;
 for item in select id from public.renders where listing_id=p_listing and video_key=p_key loop
  if not public.studio_presenter_render_access(item.id) then return false; end if;
 end loop;
 for item in select j.asset_id from public.video_erase_jobs j join public.video_erase_batches b on b.id=j.batch_id where b.listing_id=p_listing and j.output_key=p_key loop
  if not public.studio_presenter_media_access_inner(item.asset_id) then return false; end if;
 end loop;
 return true;
end;
$$;
create or replace function public.studio_presenter_media_visibility(p_listing uuid,p_assets uuid[] default '{}',p_renders uuid[] default '{}',p_keys text[] default '{}')
returns jsonb language plpgsql security definer set search_path='' as $$
declare assets jsonb:='{}'; renders jsonb:='{}'; keys jsonb:='{}'; item uuid; k text; org uuid;
begin
 if current_setting('role',true) not in ('service_role','authenticated') then raise insufficient_privilege using message='authenticated media scope required'; end if;
 if p_assets is null or p_renders is null or p_keys is null or cardinality(p_assets)+cardinality(p_renders)+cardinality(p_keys)>200 or array_position(p_assets,null) is not null or array_position(p_renders,null) is not null or array_position(p_keys,null) is not null then raise exception 'RP400: Choose a bounded media visibility batch'; end if;
 select l.org_id into org from public.listings l join public.orgs o on o.id=l.org_id where l.id=p_listing and l.deleted_at is null and o.deleted_at is null;
 if org is null or current_setting('role',true)='authenticated' and not exists(select 1 from public.memberships where org_id=org and user_id=auth.uid()) then raise exception 'RP404: Media property is unavailable'; end if;
 foreach item in array p_assets loop assets:=assets||jsonb_build_object(item::text,exists(select 1 from public.capture_assets where id=item and listing_id=p_listing) and public.studio_presenter_media_access_inner(item)); end loop;
 foreach item in array p_renders loop renders:=renders||jsonb_build_object(item::text,exists(select 1 from public.renders where id=item and listing_id=p_listing) and public.studio_presenter_render_access(item)); end loop;
 foreach k in array p_keys loop keys:=keys||jsonb_build_object(k,public.studio_presenter_key_access(p_listing,k)); end loop;
 return jsonb_build_object('assets',assets,'renders',renders,'keys',keys);
end;
$$;
-- The existing edit verifier invokes this hook before every nested source.
-- Extend that same boundary to reflection and durable edit descendants.
create or replace function public.assert_studio_asset_quality(p_asset uuid)
returns void language plpgsql security definer set search_path='' as $$
begin
 if p_asset is not null and exists(select 1 from public.capture_assets where id=p_asset) and not public.studio_presenter_media_access(p_asset) then raise exception 'RP409: Presenter source approval is no longer available'; end if;
 perform public.assert_studio_asset_quality_before_presenter(p_asset);
end;
$$;
revoke all on function public.assert_studio_asset_quality(uuid) from public,anon,authenticated;
grant execute on function public.assert_studio_asset_quality(uuid) to service_role;
-- Existing membership policies remain in force. Only new capabilities for a
-- Presenter or tracked descendant are removed by the additional restriction.
drop policy if exists presenter_approved_read on public.capture_assets;
create policy presenter_approved_read on public.capture_assets as restrictive for select to authenticated using(public.studio_presenter_media_access(id));
drop policy if exists presenter_approved_read on public.renders;
create policy presenter_approved_read on public.renders as restrictive for select to authenticated using(public.studio_presenter_render_access(id));
drop policy if exists presenter_approved_read on public.media_provenance;
create policy presenter_approved_read on public.media_provenance as restrictive for select to authenticated using(
 (original_key is null or public.studio_presenter_key_access(listing_id,original_key)) and (altered_key is null or public.studio_presenter_key_access(listing_id,altered_key)));

-- Patching the inspected exact transaction boundaries preserves established
-- native entitlement/reflection settlement behavior, including idempotent replay.
do $$
declare definition text; needle text; replacement text; signature text;
begin
 signature:='public.create_render_job(uuid,uuid,text,jsonb,text,text)';
 definition:=pg_get_functiondef(signature::regprocedure);needle:='  -- Fast path: an already-recorded idempotent replay.';
 if position('Presenter source approval is no longer available' in definition)=0 then
  if position(needle in definition)=0 then raise exception 'Native create transaction changed; inspect Presenter gate placement'; end if;
  execute replace(definition,needle,E'  if not public.studio_presenter_media_access(p_asset) then raise exception ''RP409: Presenter source approval is no longer available''; end if;\n'||needle);
 end if;
 signature:='public.publish_render(uuid,numeric,numeric,jsonb,uuid)';
 definition:=pg_get_functiondef(signature::regprocedure);needle:='  -- Poster: SERVER-DERIVED key from an asset the caller could only have created';
 if position('Presenter source approval is no longer available' in definition)=0 then
  if position(needle in definition)=0 then raise exception 'Native publish transaction changed; inspect Presenter gate placement'; end if;
  execute replace(definition,needle,E'  if v_job.capture_asset_id is not null and not public.studio_presenter_media_access(v_job.capture_asset_id) then raise exception ''RP409: Presenter source approval is no longer available''; end if;\n'||needle);
 end if;
 foreach signature in array array['public.video_erase_existing(uuid,uuid,uuid,text)','public.video_erase_get(uuid,uuid,uuid)'] loop
  definition:=pg_get_functiondef(signature::regprocedure);
  needle:=case when signature like '%_existing%' then '  return jsonb_build_object(''job'',to_jsonb(j));' else '  return to_jsonb(j);' end;
  if position('Presenter source approval is no longer available' in definition)=0 then
   if position(needle in definition)=0 then raise exception 'Reflection read transaction changed; inspect Presenter gate placement'; end if;
   execute replace(definition,needle,E'  if not public.studio_presenter_media_access(j.asset_id) then raise exception ''RP409: Presenter source approval is no longer available''; end if;\n'||needle);
  end if;
 end loop;
 signature:='public.video_erase_reserve(uuid,uuid,uuid,uuid,uuid,uuid,text,numeric)';
 definition:=pg_get_functiondef(signature::regprocedure);needle:='  -- One org lock serializes all reservations and applies/cancels for this feature.';
 if position('Presenter source approval is no longer available' in definition)=0 then
  if position(needle in definition)=0 then raise exception 'Reflection reserve transaction changed; inspect Presenter gate placement'; end if;
  execute replace(definition,needle,E'  if not public.studio_presenter_media_access(p_asset) then raise exception ''RP409: Presenter source approval is no longer available''; end if;\n'||needle);
 end if;
 signature:='public.video_erase_apply(uuid,uuid,uuid,uuid,uuid,boolean)';
 definition:=pg_get_functiondef(signature::regprocedure);needle:='  if b.state=''applied'' then';
 if position('Presenter source approval is no longer available' in definition)=0 then
  if position(needle in definition)=0 then raise exception 'Reflection acceptance transaction changed; inspect Presenter gate placement'; end if;
  execute replace(definition,needle,E'  if not public.studio_presenter_media_access(p_original) or not public.studio_presenter_media_access(p_altered) or exists(select 1 from public.video_erase_jobs where batch_id=b.id and not public.studio_presenter_media_access(asset_id)) then raise exception ''RP409: Presenter source approval is no longer available''; end if;\n'||needle);
 end if;
 signature:='public.video_erase_finish(uuid,text,jsonb,text,text,text,boolean)';
 definition:=pg_get_functiondef(signature::regprocedure);needle:='  return to_jsonb(j);';
 if position('Presenter source approval is no longer available' in definition)=0 then
  if position(needle in definition)=0 then raise exception 'Reflection settlement transaction changed; inspect Presenter redaction placement'; end if;
  replacement:=E'  if not public.studio_presenter_media_access(j.asset_id) then return to_jsonb(j)||jsonb_build_object(''state'',''cancelled'',''output_url'',null,''output_key'',null,''error'',''Presenter source approval is no longer available''); end if;\n';
  execute replace(definition,needle,replacement||needle);
 end if;
 -- Brokerage exports use a service client and label edits return a definer
 -- row, so RLS alone cannot remove these fresh signing capabilities. Keep the
 -- audit/disclosure itself intact and redact only currently inaccessible keys.
 signature:='public.compliance_audit(uuid,uuid,timestamp with time zone,timestamp with time zone)';
 definition:=pg_get_functiondef(signature::regprocedure);needle:='           mp.original_key, mp.altered_key,';
 if position('studio_presenter_key_access' in definition)=0 then
  if position(needle in definition)=0 then raise exception 'Compliance export changed; inspect Presenter redaction placement'; end if;
  replacement:=E'           case when public.studio_presenter_key_access(mp.listing_id,mp.original_key) then mp.original_key else null end as original_key,\n           case when public.studio_presenter_key_access(mp.listing_id,mp.altered_key) then mp.altered_key else null end as altered_key,';
  execute replace(definition,needle,replacement);
 end if;
 signature:='public.set_provenance_media(uuid,uuid,uuid,text)';
 definition:=pg_get_functiondef(signature::regprocedure);needle:='  return v_row;';
 if position('studio_presenter_key_access' in definition)=0 then
  if position(needle in definition)=0 then raise exception 'Provenance edit changed; inspect Presenter redaction placement'; end if;
  replacement:=E'  if v_row.original_key is not null and not public.studio_presenter_key_access(v_row.listing_id,v_row.original_key) then v_row.original_key:=null; end if;\n  if v_row.altered_key is not null and not public.studio_presenter_key_access(v_row.listing_id,v_row.altered_key) then v_row.altered_key:=null; end if;\n';
  execute replace(definition,needle,replacement||needle);
 end if;
end;
$$;
revoke all on function public.studio_presenter_media_access_inner(uuid),public.studio_presenter_media_access(uuid),public.studio_presenter_render_access(uuid),public.studio_presenter_key_access(uuid,text),public.studio_presenter_media_visibility(uuid,uuid[],uuid[],text[]) from public,anon,authenticated;
grant execute on function public.studio_presenter_media_access(uuid),public.studio_presenter_render_access(uuid),public.studio_presenter_key_access(uuid,text),public.studio_presenter_media_visibility(uuid,uuid[],uuid[],text[]) to authenticated,service_role;
grant execute on function public.studio_presenter_media_access_inner(uuid) to service_role;
commit;
