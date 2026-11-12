-- Source-only guarded additive aerial Original byte-verification protocol.
-- No capture-asset SHA update, historical receipt rewrite, table DDL or provider call.
do $migration$
declare before_meta jsonb;after_meta jsonb;before_table jsonb;after_table jsonb;owner_name text;
begin
 perform pg_advisory_xact_lock(hashtextextended('aerial-original-byte-verification-source',79));
 if md5(pg_get_functiondef('public.property_video_actor_org(uuid,uuid,uuid)'::regprocedure)) is distinct from '47edc01284f82f9369a23f2089d93212' then raise exception'Original verification predecessor changed: property_video_actor_org';end if;
 if md5(pg_get_functiondef('public.property_video_aerial_original(uuid,uuid,uuid,jsonb)'::regprocedure)) is distinct from '356ef05848a1a321581611032f34dd7f' then raise exception'Original verification predecessor changed: property_video_aerial_original';end if;
 if md5(pg_get_functiondef('public.property_video_aerial_original_register(uuid,uuid,uuid,uuid,jsonb)'::regprocedure)) is distinct from '31d6ffbda70008617508267feb5f1485' then raise exception'Original verification predecessor changed: property_video_aerial_original_register';end if;
 if to_regprocedure('public.property_video_aerial_original_verify_register(uuid,uuid,uuid,uuid,jsonb,jsonb,jsonb)')is not null then raise exception'Original byte verifier already exists';end if;
 select jsonb_agg(to_jsonb(p)-'prosrc'order by p.oid)into before_meta from pg_proc p where p.oid in('public.property_video_actor_org(uuid,uuid,uuid)'::regprocedure,'public.property_video_aerial_original(uuid,uuid,uuid,jsonb)'::regprocedure,'public.property_video_aerial_original_register(uuid,uuid,uuid,uuid,jsonb)'::regprocedure);
 select jsonb_build_object('relation',to_jsonb(c),'columns',(select jsonb_agg(to_jsonb(a)order by attnum)from pg_attribute a where attrelid=c.oid),'constraints',(select jsonb_agg(to_jsonb(k)order by k.oid)from pg_constraint k where conrelid=c.oid),'policies',(select jsonb_agg(to_jsonb(p)order by p.oid)from pg_policy p where polrelid=c.oid),'triggers',(select jsonb_agg(to_jsonb(t)order by t.oid)from pg_trigger t where tgrelid=c.oid))into before_table from pg_class c where c.oid='public.property_video_aerial_original_sources'::regclass;
 select pg_get_userbyid(proowner)into owner_name from pg_proc where oid='public.property_video_aerial_original(uuid,uuid,uuid,jsonb)'::regprocedure;
 execute $definition$CREATE OR REPLACE FUNCTION public.property_video_aerial_original_verify_register(p_actor uuid, p_operation uuid, p_library uuid, p_listing uuid, p_source jsonb, p_owned jsonb, p_verified jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$declare ctx jsonb;org uuid;prior public.property_video_aerial_original_sources;proof jsonb;envelope jsonb;begin
 if current_setting('role',true)is distinct from'service_role'then raise insufficient_privilege;end if;
 if p_actor is null or p_operation is null or p_library is null or p_listing is null then raise exception'RP400: Keep the exact original operation and property library';end if;
 perform pg_advisory_xact_lock(hashtextextended('aerial-original:'||p_actor||':'||p_operation,79));
 perform 1 from public.listings where id=p_listing and deleted_at is null for share;
 org:=public.property_video_actor_org(p_actor,p_library,p_listing);
 if p_operation is null or jsonb_typeof(p_source)is distinct from'object'or(select count(*)from jsonb_object_keys(p_source))<>5
 or exists(select 1 from jsonb_object_keys(p_source)k where k not in('photo_asset_id','photo_version_id','photo_provenance_id','sha256','bytes'))
 or p_source->'photo_provenance_id'is distinct from'null'::jsonb or p_source->>'photo_version_id'is distinct from'asset:'||(p_source->>'photo_asset_id')
 or coalesce(p_source->>'sha256','')!~'^[a-f0-9]{64}$'or jsonb_typeof(p_source->'bytes')is distinct from'number'or(p_source->>'bytes')::numeric not between 1 and 52428800 or(p_source->>'bytes')::numeric<>trunc((p_source->>'bytes')::numeric)
 then raise exception'RP400: Keep the exact unchanged original capture';end if;
 -- Hold the exact completed native row while binding the fresh owned CAS.
 perform 1 from public.capture_assets where id=(p_source->>'photo_asset_id')::uuid and listing_id=p_listing for share;
 perform 1 from public.upload_reservations where asset_id=(p_source->>'photo_asset_id')::uuid and actor_id=p_actor and listing_id=p_listing and org_id=org for share;
 perform 1 from public.upload_operations where asset_id=(p_source->>'photo_asset_id')::uuid and kind in('copy','assemble')and state='retained'for share;
 if exists(select 1 from public.deletion_requests where user_id=p_actor and status in('pending','processing'))then raise exception'RP404: This original library is unavailable';end if;
 ctx:=public.property_owned_upload(p_actor,p_listing,(p_source->>'photo_asset_id')::uuid,'photo');
 if ctx->>'org_id'is distinct from org::text or ctx->>'bucket'is distinct from'uploads'
 or ctx is distinct from p_owned or ctx->'sha256'is distinct from'null'::jsonb
 or coalesce(ctx->>'etag','')=''or length(ctx->>'etag')>256
 or ctx is distinct from public.property_native_owned_upload(p_actor,p_listing,(p_source->>'photo_asset_id')::uuid,'photo')
 or(ctx->>'bytes')::numeric is distinct from(p_source->>'bytes')::numeric
 or ctx->>'content_type'not in('image/jpeg','image/png','image/webp','image/heic','image/heif')
 or ctx->>'storage_key'not like'uploads/'||org||'/'||p_listing||'/%'
 or exists(select 1 from public.property_video_preparations where asset_id=(p_source->>'photo_asset_id')::uuid)
 or exists(select 1 from public.media_provenance where altered_key=ctx->>'storage_key')
 or not exists(select 1 from public.upload_reservations where asset_id=(p_source->>'photo_asset_id')::uuid and actor_id=p_actor and listing_id=p_listing and org_id=org and state='completed'and spec->>'bucket'='uploads'and spec->>'kind'='photo')
 then raise exception'RP409: Upload the actual raw original through the normal private capture lane';end if;
 proof:=jsonb_build_object('method','sha256_if_match','actor_id',p_actor,'operation_id',p_operation,'org_id',org,'listing_id',p_listing,'asset_id',(p_source->>'photo_asset_id')::uuid,'bucket',ctx->>'bucket','storage_key',ctx->>'storage_key','bytes',(p_source->>'bytes')::bigint,'etag',ctx->>'etag','content_type',ctx->>'content_type','sha256',p_source->>'sha256');
 if p_verified is distinct from proof then raise exception'RP409: The server byte verification does not match this exact original';end if;
 envelope:=jsonb_build_object('schema','aerial_original_server_bytes_v1','owned',ctx,'verified',proof);
 select*into prior from public.property_video_aerial_original_sources where actor_id=p_actor and operation_id=p_operation;
 if prior.operation_id is not null then if row(prior.org_id,prior.library_org_id,prior.listing_id,prior.source,prior.owned_receipt)is distinct from row(org,public.listing_owner_library(p_listing),p_listing,p_source,envelope)then raise exception'RP409: This original-source registration has different saved inputs';end if;
 else insert into public.property_video_aerial_original_sources(actor_id,operation_id,org_id,library_org_id,listing_id,asset_id,source,owned_receipt)values(p_actor,p_operation,org,public.listing_owner_library(p_listing),p_listing,(p_source->>'photo_asset_id')::uuid,p_source,envelope);end if;
 return jsonb_build_object('actor_id',p_actor,'org_id',org,'selected_library_org_id',public.listing_owner_library(p_listing),'listing_id',p_listing,'source',p_source);end$function$
$definition$;
 execute format('alter function public.property_video_aerial_original_verify_register(uuid,uuid,uuid,uuid,jsonb,jsonb,jsonb) owner to %I',owner_name);
 execute 'revoke all on function public.property_video_aerial_original_verify_register(uuid,uuid,uuid,uuid,jsonb,jsonb,jsonb) from public,anon,authenticated';
 execute 'grant execute on function public.property_video_aerial_original_verify_register(uuid,uuid,uuid,uuid,jsonb,jsonb,jsonb) to service_role';
 execute $definition$CREATE OR REPLACE FUNCTION public.property_video_aerial_original(p_actor uuid, p_library uuid, p_listing uuid, p_source jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$declare ctx jsonb;base_ctx jsonb;org uuid;byte_verified boolean:=false;begin
 if current_setting('role',true)is distinct from'service_role'and(p_actor is null or auth.uid()is distinct from p_actor)then raise insufficient_privilege;end if;
 if jsonb_typeof(p_source)is distinct from'object' or (select count(*)from jsonb_object_keys(p_source))<>5
 or exists(select 1 from jsonb_object_keys(p_source)k where k not in('photo_asset_id','photo_version_id','photo_provenance_id','sha256','bytes'))
 or p_source->'photo_provenance_id'is distinct from'null'::jsonb
 or p_source->>'photo_version_id'is distinct from'asset:'||(p_source->>'photo_asset_id')
 or coalesce(p_source->>'sha256','')!~'^[a-f0-9]{64}$'
 or jsonb_typeof(p_source->'bytes')is distinct from'number' or (p_source->>'bytes')::numeric not between 1 and 52428800
 or (p_source->>'bytes')::numeric<>trunc((p_source->>'bytes')::numeric) then raise exception'RP400: Choose the exact original front-of-home photo';end if;
 ctx:=public.property_owned_upload(p_actor,p_listing,(p_source->>'photo_asset_id')::uuid,'photo');
 if current_setting('role',true)='service_role'then org:=public.property_video_actor_org(p_actor,p_library,p_listing);
 else
  org:=(ctx->>'org_id')::uuid;
  if p_library is null or p_library not in(org,public.listing_owner_library(p_listing))or not public.listing_content_access(p_actor,p_listing,true)
  or exists(select 1 from public.deletion_requests where user_id=p_actor and status in('pending','processing'))
  then raise exception'RP404: This accepted opening library is unavailable';end if;
 end if;
 -- Only this source-specific receipt may supply a previously absent digest.
 -- The generic owned JSON and every frozen old receipt are never rewritten.
 base_ctx:=ctx;
 if p_library is not null and ctx->'sha256'='null'::jsonb and ctx->>'bucket'='uploads'
 and ctx->>'storage_key'like'uploads/'||org||'/'||p_listing||'/%'
 and not exists(select 1 from public.deletion_requests where user_id=p_actor and status in('pending','processing'))
 and not exists(select 1 from public.property_video_preparations where asset_id=(p_source->>'photo_asset_id')::uuid)
 and not exists(select 1 from public.media_provenance where altered_key=ctx->>'storage_key')
 and exists(select 1 from public.upload_reservations where asset_id=(p_source->>'photo_asset_id')::uuid and actor_id=p_actor and listing_id=p_listing and org_id=org and state='completed'and spec->>'bucket'='uploads'and spec->>'kind'='photo')
 then
  select exists(select 1 from public.property_video_aerial_original_sources r where r.actor_id=p_actor and r.org_id=org and r.library_org_id=public.listing_owner_library(p_listing)and r.listing_id=p_listing and r.asset_id=(p_source->>'photo_asset_id')::uuid and r.source=p_source
   and r.owned_receipt=jsonb_build_object('schema','aerial_original_server_bytes_v1','owned',ctx,'verified',jsonb_build_object('method','sha256_if_match','actor_id',p_actor,'operation_id',r.operation_id,'org_id',org,'listing_id',p_listing,'asset_id',(p_source->>'photo_asset_id')::uuid,'bucket',ctx->>'bucket','storage_key',ctx->>'storage_key','bytes',(p_source->>'bytes')::bigint,'etag',ctx->>'etag','content_type',ctx->>'content_type','sha256',p_source->>'sha256')))into byte_verified;
  if byte_verified then ctx:=ctx||jsonb_build_object('sha256',p_source->>'sha256');end if;
 end if;
 if ctx->>'org_id'is distinct from org::text or ctx->>'asset_id'is distinct from p_source->>'photo_asset_id'
 or ctx->>'sha256'is distinct from p_source->>'sha256' or (ctx->>'bytes')::numeric is distinct from(p_source->>'bytes')::numeric
 or ctx->>'content_type'not in('image/jpeg','image/png','image/webp','image/heic','image/heif') or coalesce(ctx->>'etag','')=''
 or not(exists(select 1 from public.photos where listing_id=p_listing and original_key=ctx->>'storage_key')or exists(select 1 from public.property_video_aerial_original_sources where actor_id=p_actor and org_id=org and library_org_id=public.listing_owner_library(p_listing)and listing_id=p_listing and asset_id=(p_source->>'photo_asset_id')::uuid and source=p_source and owned_receipt=base_ctx)or byte_verified)
 or exists(select 1 from public.media_provenance where org_id=org and listing_id=p_listing and altered_key=ctx->>'storage_key'and kind in('photo_edit','virtual_stage','declutter'))
 then raise exception'RP409: Use this property original, not an edited image or video alias';end if;
 return ctx;
end$function$
$definition$;
 if md5(pg_get_functiondef('public.property_video_aerial_original(uuid,uuid,uuid,jsonb)'::regprocedure))is distinct from '9998abb7d4a6bb2108b3bf3237c8d2a5'or md5(pg_get_functiondef('public.property_video_aerial_original_verify_register(uuid,uuid,uuid,uuid,jsonb,jsonb,jsonb)'::regprocedure))is distinct from '3e9eabad1ccf1be58ac6aca07421a4a2'then raise exception'Original verification final definition mismatch';end if;
 select jsonb_agg(to_jsonb(p)-'prosrc'order by p.oid)into after_meta from pg_proc p where p.oid in('public.property_video_actor_org(uuid,uuid,uuid)'::regprocedure,'public.property_video_aerial_original(uuid,uuid,uuid,jsonb)'::regprocedure,'public.property_video_aerial_original_register(uuid,uuid,uuid,uuid,jsonb)'::regprocedure);
 if before_meta is distinct from after_meta then raise exception'Original verification changed existing function metadata';end if;
 select jsonb_build_object('relation',to_jsonb(c),'columns',(select jsonb_agg(to_jsonb(a)order by attnum)from pg_attribute a where attrelid=c.oid),'constraints',(select jsonb_agg(to_jsonb(k)order by k.oid)from pg_constraint k where conrelid=c.oid),'policies',(select jsonb_agg(to_jsonb(p)order by p.oid)from pg_policy p where polrelid=c.oid),'triggers',(select jsonb_agg(to_jsonb(t)order by t.oid)from pg_trigger t where tgrelid=c.oid))into after_table from pg_class c where c.oid='public.property_video_aerial_original_sources'::regclass;
 if before_table is distinct from after_table then raise exception'Original verification changed source table metadata';end if;
 if has_function_privilege('anon', 'public.property_video_aerial_original_verify_register(uuid,uuid,uuid,uuid,jsonb,jsonb,jsonb)','execute')or has_function_privilege('authenticated','public.property_video_aerial_original_verify_register(uuid,uuid,uuid,uuid,jsonb,jsonb,jsonb)','execute')or not has_function_privilege('service_role','public.property_video_aerial_original_verify_register(uuid,uuid,uuid,uuid,jsonb,jsonb,jsonb)','execute')then raise exception'Original verifier ACL is not closed';end if;
end
$migration$;
