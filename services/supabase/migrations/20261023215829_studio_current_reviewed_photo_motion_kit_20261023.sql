-- Source-only CAS proposal. Existing GET JSON only; no rows, grants, roles, settings or purchases changed.
DO $kit_migration$
declare state_metadata jsonb;pm_metadata jsonb;begin
 if pg_catalog.pg_get_functiondef('public.property_website_state(uuid,uuid,uuid)'::regprocedure)is distinct from $before_state$CREATE OR REPLACE FUNCTION public.property_website_state(p_actor uuid, p_listing uuid, p_expected_org uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare o uuid;logical uuid;theme text;prod boolean;test boolean;config public.property_website_products;
begin
 if current_setting('role',true)is distinct from 'service_role'and auth.uid()is distinct from p_actor then raise insufficient_privilege;end if;
 select org_id into o from public.listings where id=p_listing and deleted_at is null;
 logical:=public.listing_owner_library(p_listing);
 if o is null or not public.listing_content_access(p_actor,p_listing,false)or(p_expected_org is not null and p_expected_org<>o and p_expected_org<>logical)then raise exception 'RP404: Property is unavailable';end if;
 select * into config from public.property_website_products where product_id='com.rendprop.app.website.premium.property';
 select s.theme into theme from public.property_website_settings s where listing_id=p_listing;
 select exists(select 1 from public.property_website_transactions where assigned_listing_id=p_listing and environment='Production'and revoked_at is null),
  exists(select 1 from public.property_website_transactions where assigned_listing_id=p_listing and environment='Sandbox'and revoked_at is null)into prod,test;
 return jsonb_build_object('listing_id',p_listing,'org_id',coalesce(p_expected_org,logical),'website_theme',case when prod then coalesce(theme,'basic')else 'basic'end,
  'selected_theme',coalesce(theme,'basic'),'purchase_enabled',coalesce(config.production_enabled,false),
  'sandbox_purchase_enabled',coalesce(config.sandbox_enabled,false),'premium_website',jsonb_build_object('unlocked',prod or test,
  'product_id','com.rendprop.app.website.premium.property','test_only',not prod and test,
  'purchase_enabled',coalesce(config.production_enabled,false),'sandbox_purchase_enabled',coalesce(config.sandbox_enabled,false)));
end$function$
$before_state$ then raise exception'Kit readmodel predecessor changed: state';end if;
 if(select to_jsonb(p)-'prosrc'from pg_proc p where p.oid='public.property_website_state(uuid,uuid,uuid)'::regprocedure)is distinct from $metadata_state${"oid": "21807", "proacl": ["postgres=X/postgres", "service_role=X/postgres"], "proallargtypes": null, "proargdefaults": "({CONST :consttype 2950 :consttypmod -1 :constcollid 0 :constlen 16 :constbyval false :constisnull true :location -1 :constvalue <>})", "proargmodes": null, "proargnames": ["p_actor", "p_listing", "p_expected_org"], "proargtypes": ["2950", "2950", "2950"], "probin": null, "proconfig": ["search_path=\"\""], "procost": 100, "proisstrict": false, "prokind": "f", "prolang": "13619", "proleakproof": false, "proname": "property_website_state", "pronamespace": "2200", "pronargdefaults": 1, "pronargs": 3, "proowner": "16388", "proparallel": "u", "proretset": false, "prorettype": "3802", "prorows": 0, "prosecdef": true, "prosqlbody": null, "prosupport": "-", "protrftypes": null, "provariadic": "0", "provolatile": "v"}$metadata_state$::jsonb then raise exception'Kit readmodel metadata changed: state';end if;
 if pg_catalog.pg_get_userbyid((select proowner from pg_proc where oid='public.property_website_state(uuid,uuid,uuid)'::regprocedure))is distinct from'postgres'or pg_catalog.obj_description('public.property_website_state(uuid,uuid,uuid)'::regprocedure,'pg_proc')is not null then raise exception'Kit readmodel owner/comment changed: state';end if;
 if pg_catalog.pg_get_functiondef('public.property_video_photo_motion_publication(uuid,uuid,uuid,uuid,jsonb)'::regprocedure)is distinct from $before_pm$CREATE OR REPLACE FUNCTION public.property_video_photo_motion_publication(p_actor uuid, p_listing uuid, p_asset uuid, p_poster uuid, p_manifest jsonb)
 RETURNS boolean
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$declare j public.property_video_jobs;normalized jsonb;begin
 if p_actor is distinct from auth.uid()and current_setting('role',true)is distinct from'service_role'then raise insufficient_privilege;end if;
 if p_manifest->>'source_mode'is distinct from'photo_motion_v1'or not coalesce(p_manifest->>'composition_profile'in('photo-motion-v1-cfr24','photo-motion-v2-cfr24','photo-motion-v2-opening-cfr24'),false)or p_manifest->'fps'is distinct from'24'::jsonb then return false;end if;
 select*into j from public.property_video_jobs where actor_id=p_actor and listing_id=p_listing and manifest->>'purpose'=p_manifest->>'purpose'and manifest->>'aspect'=p_manifest->>'aspect'and result->>'branding_policy'=p_manifest->>'branding_policy'and output_asset_id=p_asset and poster_asset_id=p_poster and state='ready'and manifest->>'source_mode'='photo_motion_v1'and quality_profile=public.property_video_photo_motion_profile(p_manifest)and public.property_video_photo_motion_saved_identity(public.property_video_photo_motion_profile(p_manifest),quality_identity);
 if j.id is null or j.result->'producer_identity'is distinct from j.quality_identity->'producer_identity' or j.result->'total_frames'is distinct from p_manifest->'total_frames'or jsonb_typeof(p_manifest->'sources')is distinct from'array'or jsonb_array_length(p_manifest->'sources')<>j.source_count then return false;end if;
 if j.quality_profile='photo-motion-v2-opening-cfr24'theN
  if p_manifest->'opening'is distinct from j.result->'opening'or(public.property_video_aerial_opening_scope(j.manifest->'opening',p_actor,j.org_id,j.library_org_id,p_listing,j.manifest->>'aspect'))->'opening'is distinct from j.result->'opening'then return false;end if;
 elsif p_manifest?'opening'then return false;end if;
 if exists(select 1 from jsonb_array_elements(j.result->'sources')s left join public.capture_assets a on a.id=(s->>'photo_asset_id')::uuid where a.id is null or a.listing_id<>p_listing or not a.uploaded or a.upload_aborted or a.sha256 is distinct from s->>'source_sha256'or a.bytes is distinct from(s->>'source_bytes')::bigint
  or exists(select 1 from public.media_provenance p where p.org_id=j.org_id and p.listing_id=p_listing and p.altered_key=a.storage_key and p.kind in('photo_edit','virtual_stage','declutter')and p.id is distinct from(s->>'photo_provenance_id')::uuid)
  or(s->>'photo_provenance_id'is not null and not exists(select 1 from public.media_provenance p where p.id=(s->>'photo_provenance_id')::uuid and p.org_id=j.org_id and p.listing_id=p_listing and p.qc->'publishable'='true'::jsonb and p.qc->>'action'in('accept','pass')and p.qc->>'output_sha256'=a.sha256 and(not(p.qc?'verdict')or p.qc->>'verdict'='pass'))))then return false;end if;
 if exists(select 1 from jsonb_array_elements(p_manifest->'sources')s where s->>'motion_kind'is distinct from'photo_motion'or s->'source_bound'is distinct from'true'::jsonb or s->>'generation_request_id'is not null or s->>'generation_provenance_id'is not null)then return false;end if;
 select jsonb_agg(jsonb_build_object('photo_asset_id',s->>'photo_asset_id','photo_version_id',s->>'photo_version_id','photo_provenance_id',s->>'photo_provenance_id','generation_request_id',null,'generation_provenance_id',null,'motion_kind','photo_motion','source_bound',true,'source_sha256',s->>'source_sha256','source_bytes',(s->>'source_bytes')::bigint,'visible_frames',(s->>'visible_frames')::integer)||case when j.quality_profile in('photo-motion-v2-cfr24','photo-motion-v2-opening-cfr24')then jsonb_build_object('motion',s->>'motion')else'{}'::jsonb end order by n)into normalized from jsonb_array_elements(p_manifest->'sources')with ordinality a(s,n);
 return normalized=j.result->'sources';end$function$
$before_pm$ then raise exception'Kit readmodel predecessor changed: pm';end if;
 if(select to_jsonb(p)-'prosrc'from pg_proc p where p.oid='public.property_video_photo_motion_publication(uuid,uuid,uuid,uuid,jsonb)'::regprocedure)is distinct from $metadata_pm${"oid": "23486", "proacl": ["postgres=X/postgres", "service_role=X/postgres"], "proallargtypes": null, "proargdefaults": null, "proargmodes": null, "proargnames": ["p_actor", "p_listing", "p_asset", "p_poster", "p_manifest"], "proargtypes": ["2950", "2950", "2950", "2950", "3802"], "probin": null, "proconfig": ["search_path=\"\""], "procost": 100, "proisstrict": false, "prokind": "f", "prolang": "13619", "proleakproof": false, "proname": "property_video_photo_motion_publication", "pronamespace": "2200", "pronargdefaults": 0, "pronargs": 5, "proowner": "16388", "proparallel": "u", "proretset": false, "prorettype": "16", "prorows": 0, "prosecdef": true, "prosqlbody": null, "prosupport": "-", "protrftypes": null, "provariadic": "0", "provolatile": "s"}$metadata_pm$::jsonb then raise exception'Kit readmodel metadata changed: pm';end if;
 if pg_catalog.pg_get_userbyid((select proowner from pg_proc where oid='public.property_video_photo_motion_publication(uuid,uuid,uuid,uuid,jsonb)'::regprocedure))is distinct from'postgres'or pg_catalog.obj_description('public.property_video_photo_motion_publication(uuid,uuid,uuid,uuid,jsonb)'::regprocedure,'pg_proc')is not null then raise exception'Kit readmodel owner/comment changed: pm';end if;
 select to_jsonb(p)-'prosrc'into state_metadata from pg_proc p where p.oid='public.property_website_state(uuid,uuid,uuid)'::regprocedure;
 select to_jsonb(p)-'prosrc'into pm_metadata from pg_proc p where p.oid='public.property_video_photo_motion_publication(uuid,uuid,uuid,uuid,jsonb)'::regprocedure;
 execute $after_definition$CREATE OR REPLACE FUNCTION public.property_website_state(p_actor uuid, p_listing uuid, p_expected_org uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare o uuid;logical uuid;theme text;prod boolean;test boolean;config public.property_website_products;
begin
 if current_setting('role',true)is distinct from 'service_role'and auth.uid()is distinct from p_actor then raise insufficient_privilege;end if;
 select org_id into o from public.listings where id=p_listing and deleted_at is null;
 logical:=public.listing_owner_library(p_listing);
 if o is null or not public.listing_content_access(p_actor,p_listing,false)or(p_expected_org is not null and p_expected_org<>o and p_expected_org<>logical)then raise exception 'RP404: Property is unavailable';end if;
 select * into config from public.property_website_products where product_id='com.rendprop.app.website.premium.property';
 select s.theme into theme from public.property_website_settings s where listing_id=p_listing;
 select exists(select 1 from public.property_website_transactions where assigned_listing_id=p_listing and environment='Production'and revoked_at is null),
  exists(select 1 from public.property_website_transactions where assigned_listing_id=p_listing and environment='Sandbox'and revoked_at is null)into prod,test;
 return jsonb_build_object('listing_id',p_listing,'org_id',coalesce(p_expected_org,logical),'website_theme',case when prod then coalesce(theme,'basic')else 'basic'end,
  'selected_theme',coalesce(theme,'basic'),'purchase_enabled',coalesce(config.production_enabled,false),
  'sandbox_purchase_enabled',coalesce(config.sandbox_enabled,false),'premium_website',jsonb_build_object('unlocked',prod or test,
  'product_id','com.rendprop.app.website.premium.property','test_only',not prod and test,
  'purchase_enabled',coalesce(config.production_enabled,false),'sandbox_purchase_enabled',coalesce(config.sandbox_enabled,false))) || jsonb_build_object('current_reviewed_photo_motion',(
  select jsonb_build_object('schema',1,'actor_id',p_actor,'org_id',o,'library_org_id',logical,'listing_id',p_listing,
   'composition_id',c.id,'publication_key',op.operation_key,'selection_revision',op.selection_revision,'selected_at',op.created_at,
   'render_id',r.id,'slug',r.slug,'published_at',r.published_at,'disclosure',c.disclosure,'manifest',c.manifest,
   'job_id',j.id,'operation_id',j.operation_id,'manifest_sha256',j.manifest_sha256,'asset_id',c.asset_id,'poster_asset_id',c.poster_asset_id,
   'source_mode','photo_motion_v1','composition_profile',j.quality_profile,'bytes',j.result->'bytes','sha256',j.result->>'sha256')
  from public.property_video_compositions c
  join lateral(select x.* from public.property_video_publication_ops x where x.listing_id=p_listing order by x.selection_revision desc limit 1)op
   on op.composition_id=c.id and op.actor_id=p_actor
  join lateral(select x.id,x.slug,x.published_at from public.renders x where x.listing_id=p_listing and x.published_at is not null
   order by x.published_at desc,x.created_at desc,x.id limit 1)r on true
  join public.property_video_jobs j on j.actor_id=p_actor and j.org_id=o and j.library_org_id=logical and j.listing_id=p_listing
   and j.output_asset_id=c.asset_id and j.poster_asset_id=c.poster_asset_id and j.state='ready'
   and j.manifest->>'source_mode'='photo_motion_v1'and j.manifest->>'purpose'='listing'and j.manifest->>'aspect'='16:9'
   and j.quality_profile in('photo-motion-v1-cfr24','photo-motion-v2-cfr24')and coalesce(j.manifest->>'composition_profile','photo-motion-v1-cfr24')=j.quality_profile
   and j.result->>'source_mode'='photo_motion_v1'and j.result->>'composition_profile'=j.quality_profile
   and j.result->>'branding_policy'='unbranded'and j.result->'width'='1920'::jsonb and j.result->'height'='1080'::jsonb
  where c.listing_id=p_listing and c.org_id=o and c.actor_id=p_actor and c.selected and length(btrim(c.disclosure))>0
   and public.listing_content_access(p_actor,p_listing,true)
   and not exists(select 1 from public.deletion_requests d where d.user_id=p_actor and d.status in('pending','processing'))
   and c.manifest->>'source_mode'='photo_motion_v1'and c.manifest->>'composition_profile'=j.quality_profile
   and c.manifest->>'purpose'='listing'and c.manifest->>'aspect'='16:9'and c.manifest->>'branding_policy'='unbranded'
   and public.property_video_photo_motion_publication(p_actor,p_listing,c.asset_id,c.poster_asset_id,c.manifest)
 ));
end$function$
$after_definition$;
 if pg_catalog.pg_get_functiondef('public.property_website_state(uuid,uuid,uuid)'::regprocedure)is distinct from $expected_after$CREATE OR REPLACE FUNCTION public.property_website_state(p_actor uuid, p_listing uuid, p_expected_org uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare o uuid;logical uuid;theme text;prod boolean;test boolean;config public.property_website_products;
begin
 if current_setting('role',true)is distinct from 'service_role'and auth.uid()is distinct from p_actor then raise insufficient_privilege;end if;
 select org_id into o from public.listings where id=p_listing and deleted_at is null;
 logical:=public.listing_owner_library(p_listing);
 if o is null or not public.listing_content_access(p_actor,p_listing,false)or(p_expected_org is not null and p_expected_org<>o and p_expected_org<>logical)then raise exception 'RP404: Property is unavailable';end if;
 select * into config from public.property_website_products where product_id='com.rendprop.app.website.premium.property';
 select s.theme into theme from public.property_website_settings s where listing_id=p_listing;
 select exists(select 1 from public.property_website_transactions where assigned_listing_id=p_listing and environment='Production'and revoked_at is null),
  exists(select 1 from public.property_website_transactions where assigned_listing_id=p_listing and environment='Sandbox'and revoked_at is null)into prod,test;
 return jsonb_build_object('listing_id',p_listing,'org_id',coalesce(p_expected_org,logical),'website_theme',case when prod then coalesce(theme,'basic')else 'basic'end,
  'selected_theme',coalesce(theme,'basic'),'purchase_enabled',coalesce(config.production_enabled,false),
  'sandbox_purchase_enabled',coalesce(config.sandbox_enabled,false),'premium_website',jsonb_build_object('unlocked',prod or test,
  'product_id','com.rendprop.app.website.premium.property','test_only',not prod and test,
  'purchase_enabled',coalesce(config.production_enabled,false),'sandbox_purchase_enabled',coalesce(config.sandbox_enabled,false))) || jsonb_build_object('current_reviewed_photo_motion',(
  select jsonb_build_object('schema',1,'actor_id',p_actor,'org_id',o,'library_org_id',logical,'listing_id',p_listing,
   'composition_id',c.id,'publication_key',op.operation_key,'selection_revision',op.selection_revision,'selected_at',op.created_at,
   'render_id',r.id,'slug',r.slug,'published_at',r.published_at,'disclosure',c.disclosure,'manifest',c.manifest,
   'job_id',j.id,'operation_id',j.operation_id,'manifest_sha256',j.manifest_sha256,'asset_id',c.asset_id,'poster_asset_id',c.poster_asset_id,
   'source_mode','photo_motion_v1','composition_profile',j.quality_profile,'bytes',j.result->'bytes','sha256',j.result->>'sha256')
  from public.property_video_compositions c
  join lateral(select x.* from public.property_video_publication_ops x where x.listing_id=p_listing order by x.selection_revision desc limit 1)op
   on op.composition_id=c.id and op.actor_id=p_actor
  join lateral(select x.id,x.slug,x.published_at from public.renders x where x.listing_id=p_listing and x.published_at is not null
   order by x.published_at desc,x.created_at desc,x.id limit 1)r on true
  join public.property_video_jobs j on j.actor_id=p_actor and j.org_id=o and j.library_org_id=logical and j.listing_id=p_listing
   and j.output_asset_id=c.asset_id and j.poster_asset_id=c.poster_asset_id and j.state='ready'
   and j.manifest->>'source_mode'='photo_motion_v1'and j.manifest->>'purpose'='listing'and j.manifest->>'aspect'='16:9'
   and j.quality_profile in('photo-motion-v1-cfr24','photo-motion-v2-cfr24')and coalesce(j.manifest->>'composition_profile','photo-motion-v1-cfr24')=j.quality_profile
   and j.result->>'source_mode'='photo_motion_v1'and j.result->>'composition_profile'=j.quality_profile
   and j.result->>'branding_policy'='unbranded'and j.result->'width'='1920'::jsonb and j.result->'height'='1080'::jsonb
  where c.listing_id=p_listing and c.org_id=o and c.actor_id=p_actor and c.selected and length(btrim(c.disclosure))>0
   and public.listing_content_access(p_actor,p_listing,true)
   and not exists(select 1 from public.deletion_requests d where d.user_id=p_actor and d.status in('pending','processing'))
   and c.manifest->>'source_mode'='photo_motion_v1'and c.manifest->>'composition_profile'=j.quality_profile
   and c.manifest->>'purpose'='listing'and c.manifest->>'aspect'='16:9'and c.manifest->>'branding_policy'='unbranded'
   and public.property_video_photo_motion_publication(p_actor,p_listing,c.asset_id,c.poster_asset_id,c.manifest)
 ));
end$function$
$expected_after$ then raise exception'Kit readmodel after definition mismatch';end if;
 if(select to_jsonb(p)-'prosrc'from pg_proc p where p.oid='public.property_website_state(uuid,uuid,uuid)'::regprocedure)is distinct from state_metadata or(select to_jsonb(p)-'prosrc'from pg_proc p where p.oid='public.property_video_photo_motion_publication(uuid,uuid,uuid,uuid,jsonb)'::regprocedure)is distinct from pm_metadata then raise exception'Kit readmodel metadata was not preserved';end if;
 if pg_catalog.pg_get_functiondef('public.property_video_photo_motion_publication(uuid,uuid,uuid,uuid,jsonb)'::regprocedure)is distinct from $unchanged_pm$CREATE OR REPLACE FUNCTION public.property_video_photo_motion_publication(p_actor uuid, p_listing uuid, p_asset uuid, p_poster uuid, p_manifest jsonb)
 RETURNS boolean
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$declare j public.property_video_jobs;normalized jsonb;begin
 if p_actor is distinct from auth.uid()and current_setting('role',true)is distinct from'service_role'then raise insufficient_privilege;end if;
 if p_manifest->>'source_mode'is distinct from'photo_motion_v1'or not coalesce(p_manifest->>'composition_profile'in('photo-motion-v1-cfr24','photo-motion-v2-cfr24','photo-motion-v2-opening-cfr24'),false)or p_manifest->'fps'is distinct from'24'::jsonb then return false;end if;
 select*into j from public.property_video_jobs where actor_id=p_actor and listing_id=p_listing and manifest->>'purpose'=p_manifest->>'purpose'and manifest->>'aspect'=p_manifest->>'aspect'and result->>'branding_policy'=p_manifest->>'branding_policy'and output_asset_id=p_asset and poster_asset_id=p_poster and state='ready'and manifest->>'source_mode'='photo_motion_v1'and quality_profile=public.property_video_photo_motion_profile(p_manifest)and public.property_video_photo_motion_saved_identity(public.property_video_photo_motion_profile(p_manifest),quality_identity);
 if j.id is null or j.result->'producer_identity'is distinct from j.quality_identity->'producer_identity' or j.result->'total_frames'is distinct from p_manifest->'total_frames'or jsonb_typeof(p_manifest->'sources')is distinct from'array'or jsonb_array_length(p_manifest->'sources')<>j.source_count then return false;end if;
 if j.quality_profile='photo-motion-v2-opening-cfr24'theN
  if p_manifest->'opening'is distinct from j.result->'opening'or(public.property_video_aerial_opening_scope(j.manifest->'opening',p_actor,j.org_id,j.library_org_id,p_listing,j.manifest->>'aspect'))->'opening'is distinct from j.result->'opening'then return false;end if;
 elsif p_manifest?'opening'then return false;end if;
 if exists(select 1 from jsonb_array_elements(j.result->'sources')s left join public.capture_assets a on a.id=(s->>'photo_asset_id')::uuid where a.id is null or a.listing_id<>p_listing or not a.uploaded or a.upload_aborted or a.sha256 is distinct from s->>'source_sha256'or a.bytes is distinct from(s->>'source_bytes')::bigint
  or exists(select 1 from public.media_provenance p where p.org_id=j.org_id and p.listing_id=p_listing and p.altered_key=a.storage_key and p.kind in('photo_edit','virtual_stage','declutter')and p.id is distinct from(s->>'photo_provenance_id')::uuid)
  or(s->>'photo_provenance_id'is not null and not exists(select 1 from public.media_provenance p where p.id=(s->>'photo_provenance_id')::uuid and p.org_id=j.org_id and p.listing_id=p_listing and p.qc->'publishable'='true'::jsonb and p.qc->>'action'in('accept','pass')and p.qc->>'output_sha256'=a.sha256 and(not(p.qc?'verdict')or p.qc->>'verdict'='pass'))))then return false;end if;
 if exists(select 1 from jsonb_array_elements(p_manifest->'sources')s where s->>'motion_kind'is distinct from'photo_motion'or s->'source_bound'is distinct from'true'::jsonb or s->>'generation_request_id'is not null or s->>'generation_provenance_id'is not null)then return false;end if;
 select jsonb_agg(jsonb_build_object('photo_asset_id',s->>'photo_asset_id','photo_version_id',s->>'photo_version_id','photo_provenance_id',s->>'photo_provenance_id','generation_request_id',null,'generation_provenance_id',null,'motion_kind','photo_motion','source_bound',true,'source_sha256',s->>'source_sha256','source_bytes',(s->>'source_bytes')::bigint,'visible_frames',(s->>'visible_frames')::integer)||case when j.quality_profile in('photo-motion-v2-cfr24','photo-motion-v2-opening-cfr24')then jsonb_build_object('motion',s->>'motion')else'{}'::jsonb end order by n)into normalized from jsonb_array_elements(p_manifest->'sources')with ordinality a(s,n);
 return normalized=j.result->'sources';end$function$
$unchanged_pm$ then raise exception'Kit PM authority was not preserved';end if;
end$kit_migration$;
