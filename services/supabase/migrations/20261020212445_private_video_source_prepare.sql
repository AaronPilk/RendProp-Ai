-- Explicit, private user-chosen full master preparation for native video.
-- No gallery write, generation/provider dispatch, AI/QC re-admission, funding or
-- original NULL provenance rewrite. Legacy selected-gallery route stays exact.
begin;

do $dependencies$declare f record;begin
 for f in select*from(values
  ('public.property_video_preparation_enqueue(uuid,jsonb)','4f68a920be93cfaf8137ba5f8017c301'),
  ('public.property_video_preparation_scope(uuid,uuid)','f035236b6749fb411928887667cb0b0e'),
  ('public.property_video_actor_org(uuid,uuid,uuid)','745310a575362c74440b8a62c1b2d7e4'),
  ('public.property_photo_reference(uuid,uuid,uuid,uuid)','130af0fdfddde97f952ccdee3644ba2d')
 )v(signature,digest)loop
  if to_regprocedure(f.signature)is null or(select md5(prosrc)from pg_proc where oid=to_regprocedure(f.signature))is distinct from f.digest then
   raise exception'Review changed private video-source dependency: %',f.signature;
  end if;
 end loop;
 if to_regprocedure('public.photo_publication_target(uuid,uuid,uuid,uuid,uuid)')is null
  or to_regprocedure('public.photo_publication_asset_valid(uuid)')is null
  or to_regprocedure('public.property_video_private_preparation_enqueue(uuid,jsonb)')is not null
  or to_regprocedure('public.property_video_private_preparation_read(uuid,uuid,uuid,uuid)')is not null then
  raise exception'Review private video-source schema/dependency installation';
 end if;
end$dependencies$;

-- Same old enqueue body, with only gallery-membership replaced by explicit
-- completed owned renders/gallery master eligibility. Edge supplies its strict
-- normalized seven-key request after actual source SHA/bytes and known-AI
-- recognition/publication checks. Exact property_photo_reference/QC and actual
-- listing-bound provenance matching below remain mandatory; nil is no bypass.
create function public.property_video_private_preparation_enqueue(p_actor uuid,p_body jsonb)
returns public.property_video_preparations language plpgsql security definer set search_path=''as $$declare p public.property_video_preparations;ctx jsonb;org uuid;selected uuid[];actual_provenance uuid;begin
 if current_setting('role',true)is distinct from'service_role'then raise insufficient_privilege;end if;
 org:=public.property_video_actor_org(p_actor,(p_body->>'expected_org_id')::uuid,(p_body->>'listing_id')::uuid);
 perform pg_advisory_xact_lock(hashtextextended('video-prepare:'||p_actor||':'||(p_body->>'operation_id'),79));
 select * into p from public.property_video_preparations where actor_id=p_actor and operation_id=(p_body->>'operation_id')::uuid;
 if p.id is not null then if row(p.listing_id,p.original_asset_id,p.version_id,p.photo_id,p.photo_provenance_id)is distinct from row((p_body->>'listing_id')::uuid,(p_body->>'photo_asset_id')::uuid,p_body->>'photo_version_id',p_body->>'photo_id',(p_body->>'photo_provenance_id')::uuid)then raise exception'RP409: Saved video-source preparation changed';end if;return public.property_video_preparation_scope(p.id,p_actor);end if;
 if not exists(select 1 from public.app_config where key='property_video_jobs'and value->'enabled'='true'::jsonb)then raise exception'RP503: Background video preparation is not active yet';end if;
 ctx:=public.property_photo_reference(p_actor,(p_body->>'listing_id')::uuid,(p_body->>'photo_asset_id')::uuid,(p_body->>'photo_provenance_id')::uuid);
 if(ctx->>'bytes')::bigint>52428800 or coalesce(ctx->>'content_type','')not in('image/jpeg','image/png','image/webp')or coalesce(ctx->>'sha256','')!~'^[a-f0-9]{64}$'then raise exception'RP400: Choose a complete JPEG,PNG orWebP property master up to50MiB';end if;
 -- Explicit private choice does not mutate or borrow current gallery membership.
 -- Keep the exact existing completed renders/gallery full-master boundary.
 if not exists(select 1 from public.capture_assets a where a.id=(p_body->>'photo_asset_id')::uuid and a.listing_id=(p_body->>'listing_id')::uuid and a.kind='photo'and a.bucket='renders'and a.uploaded and a.storage_key like 'renders/'||org||'/'||(p_body->>'listing_id')||'/gallery-%')then raise exception'RP409: Choose an exact completed owned property master';end if;
 select id into actual_provenance from public.media_provenance where listing_id=(p_body->>'listing_id')::uuid and altered_key=ctx->>'storage_key'and kind in('photo_edit','virtual_stage','declutter')order by created_at desc limit 1;
 if actual_provenance is distinct from(p_body->>'photo_provenance_id')::uuid or p_body->>'photo_version_id'is distinct from'asset:'||(p_body->>'photo_asset_id')then raise exception'RP409: Preserve the exact selected photo version and effects';end if;
 insert into public.property_video_preparations(operation_id,actor_id,listing_id,org_id,library_org_id,photo_id,version_id,original_asset_id,photo_provenance_id,original_source)values((p_body->>'operation_id')::uuid,p_actor,(p_body->>'listing_id')::uuid,org,public.listing_owner_library((p_body->>'listing_id')::uuid),p_body->>'photo_id',p_body->>'photo_version_id',(p_body->>'photo_asset_id')::uuid,actual_provenance,ctx)returning * into p;return p;end$$;

-- GET-only unknown-outcome recovery: fresh authority and the existing immutable
-- source snapshot, never enqueue/claim/CPU work or a replacement operation.
create function public.property_video_private_preparation_read(p_actor uuid,p_listing uuid,p_expected uuid,p_operation uuid)
returns public.property_video_preparations language plpgsql stable security definer set search_path=''as $$
declare p public.property_video_preparations;org uuid;
begin
 if current_setting('role',true)is distinct from'service_role'then raise insufficient_privilege;end if;
 if p_actor is null or p_listing is null or p_expected is null or p_operation is null then raise exception'RP400: Use the exact saved private source operation';end if;
 org:=public.property_video_actor_org(p_actor,p_expected,p_listing);
 select*into p from public.property_video_preparations where actor_id=p_actor and operation_id=p_operation;
 if p.id is null then return null;end if;
 if p.listing_id is distinct from p_listing or p.org_id is distinct from org
  or p.library_org_id is distinct from public.listing_owner_library(p_listing)then
  raise exception'RP409: This saved source operation belongs to another property library';
 end if;
 return public.property_video_preparation_scope(p.id,p_actor);
end$$;

revoke all on function public.property_video_private_preparation_enqueue(uuid,jsonb),public.property_video_private_preparation_read(uuid,uuid,uuid,uuid)from public,anon,authenticated;
grant execute on function public.property_video_private_preparation_enqueue(uuid,jsonb),public.property_video_private_preparation_read(uuid,uuid,uuid,uuid)to service_role;
comment on function public.property_video_private_preparation_enqueue(uuid,jsonb)is 'Explicit private owned-master video preparation; same immutable CPU/storage/quality limits as selected route, no listing gallery mutation.';
comment on function public.property_video_private_preparation_read(uuid,uuid,uuid,uuid)is 'GET-only actor and saved-operation recovery; missing returnsNULL, never creates work.';
commit;
