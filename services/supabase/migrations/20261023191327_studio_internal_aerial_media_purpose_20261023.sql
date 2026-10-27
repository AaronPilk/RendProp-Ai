-- Prospective purpose-only guards, bound to root-retained current definitions.
-- No role expansion, row mutation, accepted-opening or composition change.
begin;
do $guard0$
declare before_meta jsonb; actual text;
begin
 select pg_get_functiondef(oid),to_jsonb(p)-'prosrc' into actual,before_meta from pg_proc p where oid=to_regprocedure('public.assert_recorded_render_source(uuid,uuid)');
 if actual is distinct from $prior0$CREATE OR REPLACE FUNCTION public.assert_recorded_render_source(p_listing uuid, p_asset uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare actor uuid:=auth.uid();a public.capture_assets;o uuid;
begin
 if actor is null then raise insufficient_privilege;end if;
 select l.org_id into o from public.listings l where l.id=p_listing and l.deleted_at is null;
 if o is null or not public.listing_content_access(actor,p_listing,true)then raise exception 'RP404: Recorded source is unavailable';end if;
 -- Shared with attestation's asset lock: identity cannot be reclassified while
 -- a recorded publication is deciding which retained source it may expose.
 select * into a from public.capture_assets where id=p_asset and listing_id=p_listing for update;
 if a.id is null then raise exception 'RP404: Recorded source is unavailable';end if;
 if exists(select 1 from public.property_video_job_outputs output join public.property_video_jobs job on job.id=output.job_id
   where output.asset_id=a.id and job.listing_id=p_listing and job.org_id=o
    and ((output.kind='video'and job.output_asset_id=a.id)or(output.kind='photo'and job.poster_asset_id=a.id))
    and output.storage_key=a.storage_key and output.bytes=a.bytes and output.sha256=a.sha256)
  or exists(select 1 from public.property_video_preparations prepared where prepared.asset_id=a.id and prepared.listing_id=p_listing and prepared.org_id=o
    and prepared.storage_key=a.storage_key and prepared.bytes=a.bytes and prepared.sha256=a.sha256)
  or exists(select 1 from public.property_video_attestations attested where attested.asset_id=a.id and attested.listing_id=p_listing and attested.org_id=o
    and attested.storage_key=a.storage_key and attested.bytes=a.bytes)
  or exists(select 1 from public.property_video_compositions composition where composition.asset_id=a.id and composition.listing_id=p_listing and composition.org_id=o)
 then raise exception 'RP409: Publish the saved photo video using its typed source receipts';end if;
 -- An inconsistent retained type record is a refusal, never authority to call
 -- an edited/generated object recorded footage. These tables are service-only.
 if exists(select 1 from public.property_video_job_outputs where asset_id=a.id)
  or exists(select 1 from public.property_video_preparations where asset_id=a.id)
  or exists(select 1 from public.property_video_attestations where asset_id=a.id)
  or exists(select 1 from public.property_video_compositions where asset_id=a.id)
 then raise exception 'RP409: The retained video-source identity changed';end if;
end$function$
$prior0$ then raise exception 'Review changed public.assert_recorded_render_source(uuid,uuid) before applying aerial media purpose';end if;
 if (select proacl::text from pg_proc where oid=to_regprocedure('public.assert_recorded_render_source(uuid,uuid)')) is distinct from '{postgres=X/postgres,service_role=X/postgres}' or
    (select proowner::regrole::text from pg_proc where oid=to_regprocedure('public.assert_recorded_render_source(uuid,uuid)')) is distinct from 'postgres' then raise exception 'Review changed function permissions';end if;
 execute $new0$CREATE OR REPLACE FUNCTION public.assert_recorded_render_source(p_listing uuid, p_asset uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare actor uuid:=auth.uid();a public.capture_assets;o uuid;
begin
 if actor is null then raise insufficient_privilege;end if;
 select l.org_id into o from public.listings l where l.id=p_listing and l.deleted_at is null;
 if o is null or not public.listing_content_access(actor,p_listing,true)then raise exception 'RP404: Recorded source is unavailable';end if;
 -- Shared with attestation's asset lock: identity cannot be reclassified while
 -- a recorded publication is deciding which retained source it may expose.
 select * into a from public.capture_assets where id=p_asset and listing_id=p_listing for update;
 if a.id is null then raise exception 'RP404: Recorded source is unavailable';end if;
 -- These SQL-allocated aerial assets retain their typed opening purpose even after acceptance.
 if a.storage_key ~ ('^renders/'||o::text||'/'||p_listing::text||'/(aerial-input/[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}\.jpg|aerial-provider/[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}\.mp4|aerial-opening/[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}\.(mp4|jpg)|aerial-review/[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}/frame-(0|60|119|120)\.jpg)$') then raise exception 'RP409: Aerial opening files require their saved opening review and typed composition';end if;
 if exists(select 1 from public.property_video_job_outputs output join public.property_video_jobs job on job.id=output.job_id
   where output.asset_id=a.id and job.listing_id=p_listing and job.org_id=o
    and ((output.kind='video'and job.output_asset_id=a.id)or(output.kind='photo'and job.poster_asset_id=a.id))
    and output.storage_key=a.storage_key and output.bytes=a.bytes and output.sha256=a.sha256)
  or exists(select 1 from public.property_video_preparations prepared where prepared.asset_id=a.id and prepared.listing_id=p_listing and prepared.org_id=o
    and prepared.storage_key=a.storage_key and prepared.bytes=a.bytes and prepared.sha256=a.sha256)
  or exists(select 1 from public.property_video_attestations attested where attested.asset_id=a.id and attested.listing_id=p_listing and attested.org_id=o
    and attested.storage_key=a.storage_key and attested.bytes=a.bytes)
  or exists(select 1 from public.property_video_compositions composition where composition.asset_id=a.id and composition.listing_id=p_listing and composition.org_id=o)
 then raise exception 'RP409: Publish the saved photo video using its typed source receipts';end if;
 -- An inconsistent retained type record is a refusal, never authority to call
 -- an edited/generated object recorded footage. These tables are service-only.
 if exists(select 1 from public.property_video_job_outputs where asset_id=a.id)
  or exists(select 1 from public.property_video_preparations where asset_id=a.id)
  or exists(select 1 from public.property_video_attestations where asset_id=a.id)
  or exists(select 1 from public.property_video_compositions where asset_id=a.id)
 then raise exception 'RP409: The retained video-source identity changed';end if;
end$function$
$new0$;
 if (select to_jsonb(p)-'prosrc' from pg_proc p where oid=to_regprocedure('public.assert_recorded_render_source(uuid,uuid)')) is distinct from before_meta or
    (select md5(prosrc) from pg_proc where oid=to_regprocedure('public.assert_recorded_render_source(uuid,uuid)')) is distinct from '1674897254940d261d54d220ba6433f3' then raise exception 'Aerial media purpose changed unrelated metadata or body';end if;
end $guard0$;
do $guard1$
declare before_meta jsonb; actual text;
begin
 select pg_get_functiondef(oid),to_jsonb(p)-'prosrc' into actual,before_meta from pg_proc p where oid=to_regprocedure('public.studio_gallery_copy_source(uuid,uuid,uuid,uuid,uuid)');
 if actual is distinct from $prior1$CREATE OR REPLACE FUNCTION public.studio_gallery_copy_source(p_org uuid, p_listing uuid, p_source uuid, p_provenance uuid DEFAULT NULL::uuid, p_destination uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare a public.capture_assets;o public.capture_assets;m public.media_provenance;destination_key text;visible jsonb;ids uuid[];keys text[];kind text;proof jsonb;
begin
 select *into a from public.capture_assets where id=p_source and listing_id=p_listing;
 if a.id is null or a.kind<>'photo'or a.bucket<>'renders'or a.uploaded is not true or a.upload_aborted is true
  or a.storage_key is distinct from public.studio_photo_asset_key(a.id,p_org,p_listing)
  or starts_with(a.storage_key,'renders/'||p_org||'/'||p_listing||'/gallery-')
  or a.bytes is null or a.bytes not between 1 and 10485760 or a.sha256 is null or a.sha256!~'^[a-f0-9]{64}$'
  or a.content_type is null or a.content_type not in('image/jpeg','image/png','image/webp')then
  raise exception'RP409: This source needs a verified JPG, PNG or WebP original before it can be prepared';end if;
 if p_destination is not null then select storage_key into destination_key from public.capture_assets where id=p_destination and listing_id=p_listing;end if;
 if p_provenance is null then
  if(select count(*)from public.media_provenance where listing_id=p_listing and altered_key=a.storage_key)>1 then raise exception'RP409: This photo has conflicting edit history';end if;
  select *into m from public.media_provenance where listing_id=p_listing and altered_key=a.storage_key;
 else
  select *into m from public.media_provenance where id=p_provenance and listing_id=p_listing and org_id=p_org
   and(altered_key=a.storage_key or destination_key is not null and altered_key=destination_key);
  if m.id is null then raise exception'RP409: The photo edit history changed. Refresh before preparing it';end if;
 end if;
 ids:=array[a.id];keys:=array[a.storage_key];
 if m.id is not null then
  kind:='altered';
  if m.org_id is distinct from p_org or m.kind not in('photo_edit','virtual_stage','declutter')or nullif(btrim(m.disclosure),'')is null
   or(m.qc is not null and(m.qc->'publishable'is distinct from'true'::jsonb or coalesce(m.qc->>'action','')not in('accept','pass')))
   or exists(select 1 from public.photo_edit_evidence where provenance_id=m.id and(state<>'accept'or purpose='calibration'))then
   raise exception'RP409: This edited photo has not passed its required accuracy review';end if;
  if m.original_key is null or m.original_key=a.storage_key or(select count(*)from public.capture_assets ca where ca.listing_id=p_listing and ca.storage_key=m.original_key and ca.kind='photo'and ca.uploaded and not ca.upload_aborted)<>1 then
   raise exception'RP409: This edited photo needs its retained original before it can be prepared';end if;
  select *into o from public.capture_assets ca where ca.listing_id=p_listing and ca.storage_key=m.original_key and ca.kind='photo'and ca.uploaded and not ca.upload_aborted;
  if o.bucket<>'renders'or not starts_with(o.storage_key,'renders/'||p_org||'/'||p_listing||'/')then raise exception'RP409: Save the retained original in the photo library before preparing this edited version';end if;
  ids:=array_append(ids,o.id);keys:=array_append(keys,o.storage_key);
  proof:=jsonb_build_object('id',m.id,'kind',m.kind,'edit',m.edit,'original_asset_id',o.id,'original_key',o.storage_key,'original_sha256',o.sha256,'original_bytes',o.bytes,'disclosure',m.disclosure,'qc',m.qc);
 else
  kind:='original';
  if not exists(select 1 from public.upload_reservations r where r.asset_id=a.id and r.org_id=p_org and r.listing_id=p_listing and r.state='completed'and r.spec->>'key_role'='original')then
   raise exception'RP409: This saved source has no verified original or edit history';end if;
  proof:='null'::jsonb;
 end if;
 visible:=public.studio_presenter_media_visibility(p_listing,ids,'{}'::uuid[],keys);
 if exists(select 1 from unnest(ids)x where visible#>array['assets',x::text]is distinct from'true'::jsonb)
  or exists(select 1 from unnest(keys)x where visible#>array['keys',x]is distinct from'true'::jsonb)then raise exception'RP409: This photo or its original was withdrawn';end if;
 return jsonb_build_object('asset_id',a.id,'key',a.storage_key,'bytes',a.bytes,'sha256',a.sha256,'mime',a.content_type,'kind',kind,'provenance',proof);
end$function$
$prior1$ then raise exception 'Review changed public.studio_gallery_copy_source(uuid,uuid,uuid,uuid,uuid) before applying aerial media purpose';end if;
 if (select proacl::text from pg_proc where oid=to_regprocedure('public.studio_gallery_copy_source(uuid,uuid,uuid,uuid,uuid)')) is distinct from '{postgres=X/postgres}' or
    (select proowner::regrole::text from pg_proc where oid=to_regprocedure('public.studio_gallery_copy_source(uuid,uuid,uuid,uuid,uuid)')) is distinct from 'postgres' then raise exception 'Review changed function permissions';end if;
 execute $new1$CREATE OR REPLACE FUNCTION public.studio_gallery_copy_source(p_org uuid, p_listing uuid, p_source uuid, p_provenance uuid DEFAULT NULL::uuid, p_destination uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare a public.capture_assets;o public.capture_assets;m public.media_provenance;destination_key text;visible jsonb;ids uuid[];keys text[];kind text;proof jsonb;
begin
 select *into a from public.capture_assets where id=p_source and listing_id=p_listing;
 if a.storage_key ~ ('^renders/'||p_org::text||'/'||p_listing::text||'/(aerial-input/[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}\.jpg|aerial-provider/[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}\.mp4|aerial-opening/[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}\.(mp4|jpg)|aerial-review/[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}/frame-(0|60|119|120)\.jpg)$') then raise exception 'RP409: Aerial working files are not gallery source photos';end if;
 if a.id is null or a.kind<>'photo'or a.bucket<>'renders'or a.uploaded is not true or a.upload_aborted is true
  or a.storage_key is distinct from public.studio_photo_asset_key(a.id,p_org,p_listing)
  or starts_with(a.storage_key,'renders/'||p_org||'/'||p_listing||'/gallery-')
  or a.bytes is null or a.bytes not between 1 and 10485760 or a.sha256 is null or a.sha256!~'^[a-f0-9]{64}$'
  or a.content_type is null or a.content_type not in('image/jpeg','image/png','image/webp')then
  raise exception'RP409: This source needs a verified JPG, PNG or WebP original before it can be prepared';end if;
 if p_destination is not null then select storage_key into destination_key from public.capture_assets where id=p_destination and listing_id=p_listing;end if;
 if p_provenance is null then
  if(select count(*)from public.media_provenance where listing_id=p_listing and altered_key=a.storage_key)>1 then raise exception'RP409: This photo has conflicting edit history';end if;
  select *into m from public.media_provenance where listing_id=p_listing and altered_key=a.storage_key;
 else
  select *into m from public.media_provenance where id=p_provenance and listing_id=p_listing and org_id=p_org
   and(altered_key=a.storage_key or destination_key is not null and altered_key=destination_key);
  if m.id is null then raise exception'RP409: The photo edit history changed. Refresh before preparing it';end if;
 end if;
 ids:=array[a.id];keys:=array[a.storage_key];
 if m.id is not null then
  kind:='altered';
  if m.org_id is distinct from p_org or m.kind not in('photo_edit','virtual_stage','declutter')or nullif(btrim(m.disclosure),'')is null
   or(m.qc is not null and(m.qc->'publishable'is distinct from'true'::jsonb or coalesce(m.qc->>'action','')not in('accept','pass')))
   or exists(select 1 from public.photo_edit_evidence where provenance_id=m.id and(state<>'accept'or purpose='calibration'))then
   raise exception'RP409: This edited photo has not passed its required accuracy review';end if;
  if m.original_key is null or m.original_key=a.storage_key or(select count(*)from public.capture_assets ca where ca.listing_id=p_listing and ca.storage_key=m.original_key and ca.kind='photo'and ca.uploaded and not ca.upload_aborted)<>1 then
   raise exception'RP409: This edited photo needs its retained original before it can be prepared';end if;
  select *into o from public.capture_assets ca where ca.listing_id=p_listing and ca.storage_key=m.original_key and ca.kind='photo'and ca.uploaded and not ca.upload_aborted;
  if o.bucket<>'renders'or not starts_with(o.storage_key,'renders/'||p_org||'/'||p_listing||'/')then raise exception'RP409: Save the retained original in the photo library before preparing this edited version';end if;
  if o.storage_key ~ ('^renders/'||p_org::text||'/'||p_listing::text||'/(aerial-input/[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}\.jpg|aerial-provider/[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}\.mp4|aerial-opening/[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}\.(mp4|jpg)|aerial-review/[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}/frame-(0|60|119|120)\.jpg)$') then raise exception 'RP409: Aerial working files are not retained original gallery photos';end if;
  ids:=array_append(ids,o.id);keys:=array_append(keys,o.storage_key);
  proof:=jsonb_build_object('id',m.id,'kind',m.kind,'edit',m.edit,'original_asset_id',o.id,'original_key',o.storage_key,'original_sha256',o.sha256,'original_bytes',o.bytes,'disclosure',m.disclosure,'qc',m.qc);
 else
  kind:='original';
  if not exists(select 1 from public.upload_reservations r where r.asset_id=a.id and r.org_id=p_org and r.listing_id=p_listing and r.state='completed'and r.spec->>'key_role'='original')then
   raise exception'RP409: This saved source has no verified original or edit history';end if;
  proof:='null'::jsonb;
 end if;
 visible:=public.studio_presenter_media_visibility(p_listing,ids,'{}'::uuid[],keys);
 if exists(select 1 from unnest(ids)x where visible#>array['assets',x::text]is distinct from'true'::jsonb)
  or exists(select 1 from unnest(keys)x where visible#>array['keys',x]is distinct from'true'::jsonb)then raise exception'RP409: This photo or its original was withdrawn';end if;
 return jsonb_build_object('asset_id',a.id,'key',a.storage_key,'bytes',a.bytes,'sha256',a.sha256,'mime',a.content_type,'kind',kind,'provenance',proof);
end$function$
$new1$;
 if (select to_jsonb(p)-'prosrc' from pg_proc p where oid=to_regprocedure('public.studio_gallery_copy_source(uuid,uuid,uuid,uuid,uuid)')) is distinct from before_meta or
    (select md5(prosrc) from pg_proc where oid=to_regprocedure('public.studio_gallery_copy_source(uuid,uuid,uuid,uuid,uuid)')) is distinct from 'eca7169c1b82e4e2fa75728d221c9ed5' then raise exception 'Aerial media purpose changed unrelated metadata or body';end if;
end $guard1$;
do $guard2$
declare before_meta jsonb; actual text;
begin
 select pg_get_functiondef(oid),to_jsonb(p)-'prosrc' into actual,before_meta from pg_proc p where oid=to_regprocedure('public.publish_recorded_render(uuid,boolean,numeric,numeric,jsonb,uuid)');
 if actual is distinct from $prior2$CREATE OR REPLACE FUNCTION public.publish_recorded_render(p_job uuid, p_republish boolean, p_duration numeric, p_speed numeric, p_chapters jsonb, p_poster uuid)
 RETURNS renders
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$declare r public.renders;begin
 if auth.uid()is null then raise insufficient_privilege;end if;
 perform public.assert_recorded_render_source(j.listing_id,j.capture_asset_id) from public.render_jobs j where j.id=p_job;
 if exists(select 1 from public.render_jobs j join public.property_video_compositions c on c.asset_id=j.capture_asset_id where j.id=p_job)then raise exception 'RP409: Publish the saved photo video using its typed source receipts';end if;
 if p_republish then r:=public.republish_render(p_job,p_duration,p_speed,p_chapters,p_poster);
 else r:=public.publish_render(p_job,p_duration,p_speed,p_chapters,p_poster);end if;
 update public.renders set presentation_kind='recorded_walkthrough'where id=r.id returning * into r;
 return r;
end$function$
$prior2$ then raise exception 'Review changed public.publish_recorded_render(uuid,boolean,numeric,numeric,jsonb,uuid) before applying aerial media purpose';end if;
 if (select proacl::text from pg_proc where oid=to_regprocedure('public.publish_recorded_render(uuid,boolean,numeric,numeric,jsonb,uuid)')) is distinct from '{postgres=X/postgres,service_role=X/postgres,authenticated=X/postgres}' or
    (select proowner::regrole::text from pg_proc where oid=to_regprocedure('public.publish_recorded_render(uuid,boolean,numeric,numeric,jsonb,uuid)')) is distinct from 'postgres' then raise exception 'Review changed function permissions';end if;
 execute $new2$CREATE OR REPLACE FUNCTION public.publish_recorded_render(p_job uuid, p_republish boolean, p_duration numeric, p_speed numeric, p_chapters jsonb, p_poster uuid)
 RETURNS renders
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$declare r public.renders;begin
 if auth.uid()is null then raise insufficient_privilege;end if;
 perform public.assert_recorded_render_source(j.listing_id,j.capture_asset_id) from public.render_jobs j where j.id=p_job;
 if exists(select 1 from public.render_jobs j join public.listings l on l.id=j.listing_id
  join public.capture_assets a on a.id=p_poster and a.listing_id=j.listing_id
  where j.id=p_job and a.storage_key ~ ('^renders/'||l.org_id::text||'/'||j.listing_id::text||'/(aerial-input/[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}\.jpg|aerial-provider/[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}\.mp4|aerial-opening/[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}\.(mp4|jpg)|aerial-review/[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}/frame-(0|60|119|120)\.jpg)$'))then raise exception 'RP409: Aerial working files are not recorded-tour posters';end if;
 if exists(select 1 from public.render_jobs j join public.property_video_compositions c on c.asset_id=j.capture_asset_id where j.id=p_job)then raise exception 'RP409: Publish the saved photo video using its typed source receipts';end if;
 if p_republish then r:=public.republish_render(p_job,p_duration,p_speed,p_chapters,p_poster);
 else r:=public.publish_render(p_job,p_duration,p_speed,p_chapters,p_poster);end if;
 update public.renders set presentation_kind='recorded_walkthrough'where id=r.id returning * into r;
 return r;
end$function$
$new2$;
 if (select to_jsonb(p)-'prosrc' from pg_proc p where oid=to_regprocedure('public.publish_recorded_render(uuid,boolean,numeric,numeric,jsonb,uuid)')) is distinct from before_meta or
    (select md5(prosrc) from pg_proc where oid=to_regprocedure('public.publish_recorded_render(uuid,boolean,numeric,numeric,jsonb,uuid)')) is distinct from '3bb8e91fa737d622083fd18e7f636cfa' then raise exception 'Aerial media purpose changed unrelated metadata or body';end if;
end $guard2$;
commit;
