-- OFFLINE HOST-COMPATIBLE PROPOSAL ONLY. No production application approved/executed.
-- Original18942501 STOP and frozen d5bd candidate remain preserved unchanged.
-- Accepted unbound photo publication: original evidence/QC/NULL identities stay immutable.
-- Source-only candidate. No provider, judge, generation reservation or historical cost DML.
begin;

do $guard$declare f record;begin
 for f in select * from(values
 ('public.studio_presenter_media_access_inner(uuid)','e62ae76ce69c3f4f37dd80660a3cf4e3'),
 ('public.studio_presenter_key_access(uuid,text)','85daf8021f869b1eb6c3cc0368f734e6'),
 ('public.assert_studio_asset_quality(uuid)','f98400a1e3eb4c87669874693b4cad61'),
 ('public.studio_photo_asset_key(uuid,uuid,uuid)','719a8403ffacedb038acc5e05152ac75'),
 ('public.photo_quality_media_targets(uuid[],uuid)','5a2fb152fcf7d341cf76e281c9e761e0'),
 ('public.account_private_output_targets(uuid[],text,text)','ef55db3db9926dfaf9b284bb000d8045'),
 ('public.queue_listing_media_cleanup(uuid)','13a88808fe6992ac353502065d053907'),
 ('public.studio_presenter_media_visibility(uuid,uuid[],uuid[],text[])','1e71ee81dc34215e7698e939725d5dc9')
 )v(signature,digest)loop
  if to_regprocedure(f.signature)is null or(select md5(prosrc)from pg_proc where oid=to_regprocedure(f.signature))is distinct from f.digest then
   raise exception'Review changed photo publication dependency: %',f.signature;
  end if;
 end loop;
 if exists(select 1 from information_schema.columns where table_schema='public'and table_name='media_provenance'and column_name='photo_publication')then
  raise exception'Review previously installed photo publication schema before replay';
 end if;
end$guard$;

alter table public.media_provenance add column photo_publication jsonb;
comment on column public.media_provenance.photo_publication is 'Service-owned immutable publication association, not a new AI/QC operation. Source NULL provenance/evidence remain untouched. Copies are submitted prepared sources, not certified camera originals.';

create function public.photo_publication_receipt_shape(p jsonb)returns boolean
language plpgsql immutable security definer set search_path=''as $$
declare k text;x jsonb;field text;stamp timestamptz;
begin
 if p is null then return true;end if;
 if jsonb_typeof(p)<>'object'or octet_length(p::text)>4096 or
  (select array_agg(key order by key)from jsonb_object_keys(p)key)is distinct from
  array['copy','created_at','input','input_role','output','phase','prepared_at','schema','source','target']::text[]
  or p->'schema'is distinct from'1'::jsonb or jsonb_typeof(p->'phase')is distinct from'string'or coalesce(p->>'phase','')not in('preparing','prepared')
  or p->>'input_role'is distinct from'submitted_prepared_source'then return false;end if;
 if jsonb_typeof(p->'source')is distinct from'object'or
  (select array_agg(key order by key)from jsonb_object_keys(p->'source')key)is distinct from
  array['actor_id','automatic_check_id','evidence_id','library_org_id','listing_id','org_id','provenance_id','request_key','request_sha256']::text[]
  or p#>'{source,listing_id}'is distinct from'null'::jsonb
  or jsonb_typeof(p#>'{source,request_key}')is distinct from'string'
  or length(p#>>'{source,request_key}')not between 1 and 256
  or p#>>'{source,request_key}'~'[[:cntrl:]]'
  or coalesce(p#>>'{source,request_sha256}','')!~'^[a-f0-9]{64}$'then return false;end if;
 if jsonb_typeof(p->'target')is distinct from'object'or
  (select array_agg(key order by key)from jsonb_object_keys(p->'target')key)is distinct from
  array['library_org_id','listing_id','org_id','output_asset_id','source_copy_asset_id']::text[]then return false;end if;
 foreach k in array array['source','target']loop
  for field in select key from jsonb_object_keys(p->k)key where key like'%_id'and key<>'listing_id'or key='listing_id'and k='target'loop
   if coalesce(p#>>array[k,field],'')!~'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'then return false;end if;
  end loop;
 end loop;
 foreach k in array array['input','output']loop
  x:=p->k;
  if jsonb_typeof(x)is distinct from'object'or
   (select array_agg(key order by key)from jsonb_object_keys(x)key)is distinct from array['bytes','etag','mime','sha256']::text[]
   or coalesce(x->>'sha256','')!~'^[a-f0-9]{64}$'
   or jsonb_typeof(x->'bytes')is distinct from'number'or coalesce(x->>'bytes','')!~'^[1-9][0-9]{0,7}$'
   or(x->>'bytes')::bigint>(case when k='input'then 9000000 else 26214400 end)
   or coalesce(x->>'mime','')not in('image/jpeg','image/png','image/webp')
   or jsonb_typeof(x->'etag')is distinct from'string'or length(x->>'etag')not between 1 and 200
   or x->>'etag'~'[[:cntrl:]]'then return false;end if;
 end loop;
 if jsonb_typeof(p->'copy')is distinct from'object'or
  (select array_agg(key order by key)from jsonb_object_keys(p->'copy')key)is distinct from
  array['operation_id','source_copy_etag','target_output_etag','target_output_upload_operation_id']::text[]then return false;end if;
 foreach k in array array['operation_id','target_output_upload_operation_id']loop
  if coalesce(p#>>array['copy',k],'')!~'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'then return false;end if;
 end loop;
 if jsonb_typeof(p#>'{copy,target_output_etag}')is distinct from'string'
  or length(p#>>'{copy,target_output_etag}')not between 1 and 256
  or p#>>'{copy,target_output_etag}'~'[[:cntrl:]]'then return false;end if;
 if jsonb_typeof(p->'created_at')is distinct from'string'then return false;end if;stamp:=(p->>'created_at')::timestamptz;if not isfinite(stamp)then return false;end if;
 if p->>'phase'='preparing'then
  if p->'prepared_at'is distinct from'null'::jsonb or p#>'{copy,source_copy_etag}'is distinct from'null'::jsonb then return false;end if;
 else
  if jsonb_typeof(p->'prepared_at')is distinct from'string'or jsonb_typeof(p#>'{copy,source_copy_etag}')is distinct from'string'
   or length(p#>>'{copy,source_copy_etag}')not between 1 and 256 or p#>>'{copy,source_copy_etag}'~'[[:cntrl:]]'then return false;end if;
  stamp:=(p->>'prepared_at')::timestamptz;if not isfinite(stamp)then return false;end if;
  if stamp<(p->>'created_at')::timestamptz then return false;end if;
 end if;
 return true;
exception when others then return false;
end$$;
alter table public.media_provenance add constraint media_provenance_photo_publication_shape check(public.photo_publication_receipt_shape(photo_publication));
create unique index media_provenance_photo_publication_source_target on public.media_provenance(listing_id,(photo_publication#>>'{source,evidence_id}'))where photo_publication is not null;
create index media_provenance_photo_publication_evidence on public.media_provenance((photo_publication#>>'{source,evidence_id}'))where photo_publication is not null;
create index media_provenance_photo_publication_provenance on public.media_provenance((photo_publication#>>'{source,provenance_id}'))where photo_publication is not null;
create index media_provenance_photo_publication_output on public.media_provenance((photo_publication#>>'{target,output_asset_id}'))where photo_publication is not null;
create index media_provenance_photo_publication_source_copy on public.media_provenance((photo_publication#>>'{target,source_copy_asset_id}'))where photo_publication is not null;
create index photo_edit_evidence_output_identity on public.photo_edit_evidence((output->>'sha256'),(output->>'bytes'),(output->>'mime'))where output is not null;

-- Snapshot source authority from the stored original actor, never from a public viewer.
create function public.photo_publication_source(p_actor uuid,p_org uuid,p_library uuid,p_evidence uuid)returns jsonb
language plpgsql stable security definer set search_path=''as $$
declare e public.photo_edit_evidence;q public.photo_quality_checks;m public.media_provenance;c jsonb;prefix text;
begin
 select*into e from public.photo_edit_evidence where id=p_evidence;
 select*into q from public.photo_quality_checks where evidence_id=e.id and automatic;
 select*into m from public.media_provenance where id=e.provenance_id;
 if e.id is null or e.actor_id is distinct from p_actor or e.org_id is distinct from p_org or e.library_org_id is distinct from p_library
  or e.listing_id is not null or e.purpose is distinct from'prospective'or e.state is distinct from'accept'
  or q.id is null or q.state is distinct from'accept'or q.policy is distinct from e.policy or q.result->>'action'is distinct from'accept'or q.result->>'verdict'is distinct from'pass'
  or e.original_asset_id is not null or e.original_reference is not null or m.id is null or m.org_id is distinct from e.org_id or m.listing_id is not null
  or m.photo_publication is not null or m.kind not in('photo_edit','virtual_stage','declutter')or m.qc_checked_at is null
  or m.qc->>'task'is distinct from'judge.photo_fixed_features'or m.qc->>'medium'is distinct from'photo'
  or m.qc->>'purpose'is distinct from'prospective'or m.qc->'publishable'is distinct from'true'::jsonb
  or m.qc->>'action'is distinct from'accept'or m.qc->>'evidence_id'is distinct from e.id::text
  or m.qc->>'check_id'is distinct from q.id::text or m.qc->>'prepared_sha256'is distinct from e.input->>'sha256'
  or m.qc->>'output_sha256'is distinct from e.output->>'sha256'or e.input_etag is null or e.output_etag is null
  or m.altered_key is distinct from e.output->>'key'then raise exception'RP404: This saved photo is unavailable for publication';end if;
 if not exists(select 1 from auth.users u join public.profiles p on p.id=u.id where u.id=p_actor and not u.is_anonymous)
  or not exists(select 1 from public.orgs where id=p_org and deleted_at is null)
  or exists(select 1 from public.deletion_requests where user_id=p_actor and status in('pending','processing'))then raise exception'RP404: This saved photo is unavailable for publication';end if;
 c:=public.library_access(p_actor,p_org);
 if c is null or c->>'can_write'is distinct from'true'then raise exception'RP404: This saved photo is unavailable for publication';end if;
 prefix:='ai-router/'||e.org_id||'/photo-evidence/'||e.actor_id||'/'||e.id||'/';
 if e.input->>'bucket'is distinct from'renders'or e.output->>'bucket'is distinct from'renders'
  or e.input->>'key'is distinct from prefix||'input.'||(case e.input->>'mime'when'image/jpeg'then'jpg'when'image/png'then'png'else'webp'end)
  or e.output->>'key'is distinct from prefix||'candidate.'||(case e.output->>'mime'when'image/jpeg'then'jpg'when'image/png'then'png'else'webp'end)
  or e.input->>'key'~'[?#%\\[:cntrl:]]|(^|/)[.]{1,2}(/|$)'or e.output->>'key'~'[?#%\\[:cntrl:]]|(^|/)[.]{1,2}(/|$)'
  or not exists(select 1 from public.private_ai_outputs where user_id=p_actor and org_id=p_org and listing_id is null and bucket='renders'and storage_key=e.input->>'key'and bytes=(e.input->>'bytes')::bigint)
  or not exists(select 1 from public.private_ai_outputs where user_id=p_actor and org_id=p_org and listing_id is null and bucket='renders'and storage_key=e.output->>'key'and bytes=(e.output->>'bytes')::bigint)
 then raise exception'RP404: This saved photo is unavailable for publication';end if;
 return jsonb_build_object('evidence',to_jsonb(e),'check',to_jsonb(q),'provenance',to_jsonb(m),
  'source_input',(e.input-'width'-'height'-'bucket')||jsonb_build_object('etag',e.input_etag),
  'source_output',(e.output-'width'-'height'-'bucket')||jsonb_build_object('etag',e.output_etag));
end$$;

-- Retain an exact copy of the old Presenter walk for preparation ONLY. It must
-- not invoke the new preparing/prepared gate recursively.
do $copy$declare d text;begin
 d:=pg_get_functiondef('public.studio_presenter_media_access_inner(uuid)'::regprocedure);
 execute replace(d,'public.studio_presenter_media_access_inner(','public.photo_publication_prior_media_access_inner(');
end$copy$;
revoke all on function public.photo_publication_prior_media_access_inner(uuid)from public,anon,authenticated,service_role;

create function public.photo_publication_target(p_actor uuid,p_org uuid,p_library uuid,p_listing uuid,p_asset uuid)returns jsonb
language plpgsql security definer set search_path=''as $$
declare a public.capture_assets;r public.upload_reservations;o public.upload_operations;c jsonb;target_listing uuid;publication public.media_provenance;
begin
 if current_setting('role',true)is distinct from'service_role'then raise insufficient_privilege;end if;
 select*into a from public.capture_assets where id=p_asset;target_listing:=coalesce(p_listing,a.listing_id);
 if p_actor is null or p_org is null or p_library is null or target_listing is null or a.listing_id is distinct from target_listing
  or not exists(select 1 from auth.users u join public.profiles p on p.id=u.id where u.id=p_actor and not u.is_anonymous)
  or exists(select 1 from public.deletion_requests where user_id=p_actor and status in('pending','processing'))then raise exception'RP404: This photo is unavailable in the selected library';end if;
 c:=public.listing_library_scope(p_actor,target_listing);
 if c is null or c->>'can_write'is distinct from'true'or(c->>'org_id')::uuid is distinct from p_org
  or(c->>'library_org_id')::uuid is distinct from p_library then raise exception'RP404: This photo is unavailable in the selected library';end if;
 select*into r from public.upload_reservations where asset_id=a.id;
 select*into o from public.upload_operations where asset_id=a.id and kind='copy'and part=0 and state='retained';
 if a.id is null or a.kind<>'photo'or a.bucket<>'renders'or a.transport_version<>2 or a.uploaded is distinct from true or a.upload_aborted
  or a.bytes not between 1 and 52428800 or a.content_type not in('image/jpeg','image/png','image/webp')
  or not starts_with(a.storage_key,'renders/'||p_org||'/'||target_listing||'/')or a.storage_key~'[?#%\\[:cntrl:]]|(^|/)[.]{1,2}(/|$)'
  or r.actor_id is distinct from p_actor or r.org_id is distinct from p_org or r.listing_id is distinct from target_listing or r.state is distinct from'completed'
  or o.id is null or o.bucket<>'renders'or o.object_key is distinct from a.storage_key or o.expected_bytes is distinct from a.bytes
  or o.content_type is distinct from a.content_type or nullif(o.etag,'')is null or length(o.etag)>256
 then raise exception'RP404: This photo is unavailable in the selected library';end if;
 perform public.assert_studio_asset_quality_before_presenter(a.id);
 if not public.photo_publication_prior_media_access_inner(a.id)then raise exception'RP404: This photo is unavailable in the selected library';end if;
 select*into publication from public.media_provenance where photo_publication is not null and(photo_publication#>>'{target,output_asset_id}'=a.id::text or photo_publication#>>'{target,source_copy_asset_id}'=a.id::text)order by id limit 1;
 return jsonb_build_object('actor_id',p_actor,'org_id',p_org,'library_org_id',p_library,'listing_id',target_listing,
  'target',jsonb_build_object('asset_id',a.id,'key',a.storage_key,'bytes',a.bytes,'mime',a.content_type,'sha256',a.sha256,'etag',o.etag,'operation_id',o.id),'publication',case when publication.id is null then null else jsonb_build_object('id',publication.id,'photo_publication',publication.photo_publication)end);
end$$;

create function public.photo_publication_verified(p jsonb,p_sha text,p_bytes bigint,p_mime text,p_etag text)returns boolean
language sql immutable security definer set search_path=''as $$
 select jsonb_typeof(p)='object'and(select array_agg(key order by key)from jsonb_object_keys(p)key)=array['bytes','etag','mime','sha256']::text[]
 and p->>'sha256'=p_sha and p->'bytes'=to_jsonb(p_bytes)and p->>'mime'=p_mime and p->>'etag'=p_etag;
$$;

create function public.photo_publication_resolve(p_actor uuid,p_org uuid,p_library uuid,p_listing uuid,p_asset uuid,p_provenance uuid,p_verified_target jsonb)returns jsonb
language plpgsql security definer set search_path=''as $$
declare t jsonb;e public.photo_edit_evidence;s jsonb;m public.media_provenance;n integer;
begin
 t:=public.photo_publication_target(p_actor,p_org,p_library,p_listing,p_asset);
 if(t#>>'{target,bytes}')::bigint>26214400 then
  if p_provenance is not null or t->'publication'<>'null'::jsonb then raise exception'RP404: This saved photo is unavailable for publication';end if;
  return null;
 end if;
 if coalesce(p_verified_target->>'sha256','')!~'^[a-f0-9]{64}$'or
  not coalesce(public.photo_publication_verified(p_verified_target,p_verified_target->>'sha256',(t#>>'{target,bytes}')::bigint,t#>>'{target,mime}',t#>>'{target,etag}'),false)
 then raise exception'RP409: The uploaded photo body or receipt changed';end if;
 select count(*)into n from(select id from public.photo_edit_evidence where output->>'sha256'=p_verified_target->>'sha256'
  and output->'bytes'=p_verified_target->'bytes'and output->>'mime'=p_verified_target->>'mime'
  and(p_provenance is null or provenance_id=p_provenance)limit 2)x;
 if n=0 then
  if p_provenance is not null or t->'publication'<>'null'::jsonb then
   raise exception'RP404: This saved photo is unavailable for publication';end if;
  return null;
 end if;
 if n<>1 then raise exception'RP404: This saved photo is unavailable for publication';end if;
 select*into e from public.photo_edit_evidence where output->>'sha256'=p_verified_target->>'sha256'
  and output->'bytes'=p_verified_target->'bytes'and output->>'mime'=p_verified_target->>'mime'
  and(p_provenance is null or provenance_id=p_provenance);
 if p_provenance is not null and e.provenance_id is distinct from p_provenance then raise exception'RP404: This saved photo is unavailable for publication';end if;
 s:=public.photo_publication_source(p_actor,p_org,p_library,e.id);
 select*into m from public.media_provenance where listing_id=(t->>'listing_id')::uuid and photo_publication#>>'{source,evidence_id}'=e.id::text;
 if m.id is not null and m.photo_publication#>>'{target,output_asset_id}'is distinct from p_asset::text then
  raise exception'RP409: This saved photo already has a different canonical publication target';end if;
 return t||s||jsonb_build_object('publication',case when m.id is null then null else jsonb_build_object('id',m.id,'photo_publication',m.photo_publication)end);
end$$;

create function public.photo_publication_metadata_valid(p_publication uuid)returns boolean
language plpgsql stable security definer set search_path=''as $$
declare m public.media_provenance;p jsonb;s jsonb;t jsonb;c jsonb;a public.capture_assets;b public.capture_assets;u public.upload_operations;v public.upload_operations;
begin
 select*into m from public.media_provenance where id=p_publication;p:=m.photo_publication;
 if p is null or not public.photo_publication_receipt_shape(p)or p->>'phase'<>'prepared'then return false;end if;
 s:=public.photo_publication_source((p#>>'{source,actor_id}')::uuid,(p#>>'{source,org_id}')::uuid,(p#>>'{source,library_org_id}')::uuid,(p#>>'{source,evidence_id}')::uuid);
 if m.org_id::text is distinct from p#>>'{target,org_id}'or m.listing_id::text is distinct from p#>>'{target,listing_id}'
  or p#>>'{source,org_id}'is distinct from p#>>'{target,org_id}'or p#>>'{source,library_org_id}'is distinct from p#>>'{target,library_org_id}'
  or s#>>'{evidence,provenance_id}'is distinct from p#>>'{source,provenance_id}'or s#>>'{check,id}'is distinct from p#>>'{source,automatic_check_id}'
  or s#>>'{evidence,request_key}'is distinct from p#>>'{source,request_key}'or s#>>'{evidence,request_sha256}'is distinct from p#>>'{source,request_sha256}'
  or((s->'source_input')-'key')is distinct from p->'input'or((s->'source_output')-'key')is distinct from p->'output'
  or m.qc is distinct from s#>'{provenance,qc}'or to_jsonb(m.qc_checked_at)is distinct from s#>'{provenance,qc_checked_at}'then return false;end if;
 c:=public.listing_library_scope((p#>>'{source,actor_id}')::uuid,m.listing_id);
 if c is null or c->>'can_write'is distinct from'true'or(c->>'org_id')::uuid is distinct from m.org_id
  or c->>'library_org_id'is distinct from p#>>'{target,library_org_id}'then return false;end if;
 select*into a from public.capture_assets where id=(p#>>'{target,output_asset_id}')::uuid;
 select*into b from public.capture_assets where id=(p#>>'{target,source_copy_asset_id}')::uuid;
 select*into u from public.upload_operations where id=(p#>>'{copy,target_output_upload_operation_id}')::uuid;
 select*into v from public.upload_operations where id=(p#>>'{copy,operation_id}')::uuid;
 if a.id is null or b.id is null or a.listing_id is distinct from m.listing_id or b.listing_id is distinct from m.listing_id
  or a.kind<>'photo'or b.kind<>'photo'or a.bucket<>'renders'or b.bucket<>'renders'or not a.uploaded or not b.uploaded or a.upload_aborted or b.upload_aborted
  or a.storage_key is distinct from m.altered_key or b.storage_key is distinct from m.original_key
  or a.bytes is distinct from(p#>>'{output,bytes}')::bigint or b.bytes is distinct from(p#>>'{input,bytes}')::bigint
  or a.content_type is distinct from p#>>'{output,mime}'or b.content_type is distinct from p#>>'{input,mime}'
  or b.sha256 is distinct from p#>>'{input,sha256}'
  or u.asset_id is distinct from a.id or v.asset_id is distinct from b.id or u.state is distinct from'retained'or v.state is distinct from'retained'
  or u.kind<>'copy'or v.kind<>'copy'or u.bucket<>'renders'or v.bucket<>'renders'or u.asset_kind<>'photo'or v.asset_kind<>'photo'
  or u.expected_bytes is distinct from a.bytes or v.expected_bytes is distinct from b.bytes or v.bytes is distinct from b.bytes
  or u.content_type is distinct from a.content_type or v.content_type is distinct from b.content_type or u.claim is null or v.claim is null
  or u.object_key is distinct from a.storage_key or v.object_key is distinct from b.storage_key
  or u.etag is distinct from p#>>'{copy,target_output_etag}'or v.etag is distinct from p#>>'{copy,source_copy_etag}'
  or not exists(select 1 from public.upload_reservations where asset_id=a.id and actor_id=(p#>>'{source,actor_id}')::uuid and state='completed')
  or not exists(select 1 from public.upload_reservations where asset_id=b.id and actor_id=(p#>>'{source,actor_id}')::uuid and state='completed')
 then return false;end if;
 return true;
exception when others then return false;
end$$;

create function public.photo_publication_asset_valid(p_asset uuid)returns boolean
language plpgsql stable security definer set search_path=''as $$
declare m record;a public.capture_assets;marked boolean:=false;
begin
 for m in select id from public.media_provenance where photo_publication is not null and
  (photo_publication#>>'{target,output_asset_id}'=p_asset::text or photo_publication#>>'{target,source_copy_asset_id}'=p_asset::text)loop
  marked:=true;
  if not public.photo_publication_metadata_valid(m.id)then return false;end if;
 end loop;
 if marked then return true;end if;
 select*into a from public.capture_assets where id=p_asset;
 -- Advisory upload metadata can only conservatively DENY a known-AI bypass;
 -- it never authorizes publication. Edge still hashes the actual stored body.
 if a.kind='photo'and a.bucket='renders'and exists(select 1 from public.photo_edit_evidence e
  where e.output->>'sha256'=a.sha256 and e.output->'bytes'=to_jsonb(a.bytes)and e.output->>'mime'=a.content_type)then return false;end if;
 return true;
end$$;
create function public.photo_publication_key_valid(p_listing uuid,p_key text)returns boolean
language plpgsql stable security definer set search_path=''as $$
declare m record;
begin
 for m in select id from public.media_provenance where photo_publication is not null and listing_id=p_listing and(original_key=p_key or altered_key=p_key)loop
  if not public.photo_publication_metadata_valid(m.id)then return false;end if;
 end loop;
 for m in select id from public.capture_assets where listing_id=p_listing and storage_key=p_key loop
  if not public.photo_publication_asset_valid(m.id)then return false;end if;
 end loop;
 return true;
end$$;

create function public.photo_publication_guard()returns trigger
language plpgsql security definer set search_path=''as $$
declare p jsonb;s jsonb;
begin
 if tg_op='DELETE'then
  if old.photo_publication is not null and exists(select 1 from public.listings l join public.orgs o on o.id=l.org_id where l.id=old.listing_id and l.deleted_at is null and o.deleted_at is null)then
   raise exception'RP409: Revoke the publication parent before removing its durable association';end if;
  return old;
 end if;
 if tg_op='UPDATE'and old.photo_publication is not null then
  if new.photo_publication is null or
   row(new.org_id,new.listing_id,new.original_key,new.altered_key,new.kind,new.model_id,new.edit,new.style,new.disclosure,new.qc,new.qc_checked_at)is distinct from
   row(old.org_id,old.listing_id,old.original_key,old.altered_key,old.kind,old.model_id,old.edit,old.style,old.disclosure,old.qc,old.qc_checked_at)
  then raise exception'RP409: Photo publication identity and original verdict are immutable';end if;
  if new.photo_publication is distinct from old.photo_publication then
   if old.photo_publication->>'phase'<>'preparing'or new.photo_publication->>'phase'<>'prepared'
    or(new.photo_publication-'phase'-'prepared_at'-'copy')is distinct from(old.photo_publication-'phase'-'prepared_at'-'copy')
    or((new.photo_publication->'copy')-'source_copy_etag')is distinct from((old.photo_publication->'copy')-'source_copy_etag')
   then raise exception'RP409: Photo publication receipt is immutable';end if;
  end if;
 elsif new.photo_publication is not null then
  if tg_op<>'INSERT'or new.photo_publication->>'phase'<>'preparing'then raise exception'RP409: Reserve a new photo publication first';end if;
 end if;
 p:=new.photo_publication;
 if p is not null then
  if current_setting('role',true)is distinct from'service_role'or not public.photo_publication_receipt_shape(p)then raise insufficient_privilege;end if;
  s:=public.photo_publication_source((p#>>'{source,actor_id}')::uuid,(p#>>'{source,org_id}')::uuid,(p#>>'{source,library_org_id}')::uuid,(p#>>'{source,evidence_id}')::uuid);
  if new.org_id::text is distinct from p#>>'{target,org_id}'or new.listing_id::text is distinct from p#>>'{target,listing_id}'
   or s#>>'{provenance,id}'is distinct from p#>>'{source,provenance_id}'or s#>>'{check,id}'is distinct from p#>>'{source,automatic_check_id}'
   or((s->'source_input')-'key')is distinct from p->'input'or((s->'source_output')-'key')is distinct from p->'output'
   or new.qc is distinct from s#>'{provenance,qc}'or to_jsonb(new.qc_checked_at)is distinct from s#>'{provenance,qc_checked_at}'
  then raise exception'RP409: Photo publication must retain its exact original evidence and verdict';end if;
 end if;
 return new;
end$$;
create trigger accepted_photo_publication_guard before insert or update or delete on public.media_provenance for each row execute function public.photo_publication_guard();

-- The bridge runs as the actual service caller so the OLD invoker upload
-- current_user guard remains intact. Its parameters cannot name an arbitrary asset,
-- key, bytes, type, reservation or settlement; all derive from one new receipt.
create function public.photo_publication_upload_reserve(p_actor uuid,p_publication uuid,p_claim uuid)returns jsonb
language plpgsql security invoker set search_path=''as $$
declare m public.media_provenance;p jsonb;a public.capture_assets;o public.upload_operations;spec jsonb;key text;ext text;
begin
 if current_setting('role',true)is distinct from'service_role'or current_user is distinct from'service_role'or p_claim is null then raise insufficient_privilege;end if;
 select*into m from public.media_provenance where id=p_publication;p:=m.photo_publication;
 if p is null or not public.photo_publication_receipt_shape(p)or p->>'phase'<>'preparing'or p#>>'{source,actor_id}'is distinct from p_actor::text then raise exception'RP404: Photo publication is unavailable';end if;
 perform public.photo_publication_source(p_actor,m.org_id,(p#>>'{target,library_org_id}')::uuid,(p#>>'{source,evidence_id}')::uuid);
 perform public.photo_publication_target(p_actor,m.org_id,(p#>>'{target,library_org_id}')::uuid,m.listing_id,(p#>>'{target,output_asset_id}')::uuid);
 ext:=case p#>>'{input,mime}'when'image/jpeg'then'jpg'when'image/png'then'png'else'webp'end;
 key:='renders/'||m.org_id||'/'||m.listing_id||'/original-'||(p#>>'{target,source_copy_asset_id}')||'.'||ext;
 if m.original_key is distinct from key then raise exception'RP409: Reserved submitted source identity changed';end if;
 select*into a from public.capture_assets where id=(p#>>'{target,source_copy_asset_id}')::uuid;
 if a.id is null then
  spec:=jsonb_build_object('id',p#>>'{target,source_copy_asset_id}','listing_id',m.listing_id,'kind','photo','bucket','renders','storage_key',key,
   'bytes',(p#>>'{input,bytes}')::bigint,'content_type',p#>>'{input,mime}','content_type_declared',true,'sha256',p#>>'{input,sha256}','idem_key','photo-publication:'||m.id);
  perform public.reserve_upload_assets(p_actor,jsonb_build_array(spec));
  -- This is one server-owned source→canonical conditional copy, not a client
  -- staging upload. Use the same existing budget and irrevocable claim journal.
  insert into public.upload_operations(id,asset_id,kind,part,bucket,object_key,bytes,expected_bytes,content_type,content_type_declared,asset_kind)
  values((p#>>'{copy,operation_id}')::uuid,(p#>>'{target,source_copy_asset_id}')::uuid,'copy',0,'renders',key,
   (p#>>'{input,bytes}')::bigint,(p#>>'{input,bytes}')::bigint,p#>>'{input,mime}',true,'photo');
 end if;
 select*into o from public.upload_operations where id=(p#>>'{copy,operation_id}')::uuid;
 if o.asset_id is distinct from(p#>>'{target,source_copy_asset_id}')::uuid or o.object_key is distinct from key then raise exception'RP409: Saved copy operation changed';end if;
 if o.state='planned'then return public.claim_upload_operation(o.id,p_claim);end if;
 return to_jsonb(o)||jsonb_build_object('dispatch',false);
end$$;
-- Owner remains the migration owner; no role/schema privilege transfer.

create function public.photo_publication_upload_finish(p_actor uuid,p_publication uuid,p_verified_source jsonb)returns jsonb
language plpgsql security invoker set search_path=''as $$
declare m public.media_provenance;p jsonb;o public.upload_operations;
begin
 if current_setting('role',true)is distinct from'service_role'or current_user is distinct from'service_role'then raise insufficient_privilege;end if;
 select*into m from public.media_provenance where id=p_publication;p:=m.photo_publication;
 if p is null or not public.photo_publication_receipt_shape(p)or p#>>'{source,actor_id}'is distinct from p_actor::text or not coalesce(public.photo_publication_verified(p_verified_source,p#>>'{input,sha256}',(p#>>'{input,bytes}')::bigint,p#>>'{input,mime}',p_verified_source->>'etag'),false)
  or nullif(p_verified_source->>'etag','')is null or length(p_verified_source->>'etag')>256 then raise exception'RP409: Exact submitted source copy proof is required';end if;
 perform public.photo_publication_source(p_actor,m.org_id,(p#>>'{target,library_org_id}')::uuid,(p#>>'{source,evidence_id}')::uuid);
 perform public.photo_publication_target(p_actor,m.org_id,(p#>>'{target,library_org_id}')::uuid,m.listing_id,(p#>>'{target,output_asset_id}')::uuid);
 select*into o from public.upload_operations where id=(p#>>'{copy,operation_id}')::uuid;
 if o.asset_id is distinct from(p#>>'{target,source_copy_asset_id}')::uuid or o.object_key is distinct from m.original_key then raise exception'RP409: Saved copy operation changed';end if;
 if o.state='dispatching'then perform public.finish_upload_operation(o.id,o.claim,'stored',p_verified_source->>'etag',null,p_verified_source->>'mime');
 elsif o.state='uncertain'then perform public.recover_upload_operation(o.id,p_verified_source->>'etag',null,p_verified_source->>'mime');
 elsif o.state not in('stored','retained')or o.etag is distinct from p_verified_source->>'etag'then raise exception'RP409: No recorded source copy can be reconciled';end if;
 return public.settle_upload_reservation((p#>>'{target,source_copy_asset_id}')::uuid,true,o.id,jsonb_build_object('sha256',p#>>'{input,sha256}'));
end$$;
-- Owner remains the migration owner; no role/schema privilege transfer.

create function public.photo_publication_reserve_locked(p_actor uuid,p_org uuid,p_library uuid,p_listing uuid,p_asset uuid,p_evidence uuid,p_verified_input jsonb,p_verified_output jsonb,p_verified_target jsonb,p_claim uuid)returns jsonb
language plpgsql security definer set search_path=''as $$
declare s jsonb;t jsonb;m public.media_provenance;source_m public.media_provenance;p jsonb;copy_asset uuid:=gen_random_uuid();op uuid:=gen_random_uuid();pub uuid:=gen_random_uuid();io jsonb;key text;ext text;
begin
 if current_setting('role',true)is distinct from'service_role'then raise insufficient_privilege;end if;
 -- Established parent order: actor/profile→org→listing→source/check/provenance→assets/upload.
 perform 1 from auth.users where id=p_actor for update;perform 1 from public.profiles where id=p_actor for update;
 perform 1 from public.orgs where id=p_org for update;perform 1 from public.listings where id=p_listing for update;
 perform pg_advisory_xact_lock(hashtextextended('photo-publication:'||p_listing||':'||p_evidence,91));
 perform 1 from public.photo_edit_evidence where id=p_evidence for update;
 perform 1 from public.photo_quality_checks where evidence_id=p_evidence and automatic for update;
 s:=public.photo_publication_source(p_actor,p_org,p_library,p_evidence);
 t:=public.photo_publication_resolve(p_actor,p_org,p_library,p_listing,p_asset,(s#>>'{provenance,id}')::uuid,p_verified_target);
 if t is null or t#>>'{evidence,id}'is distinct from p_evidence::text then raise exception'RP404: This saved photo is unavailable for publication';end if;
 if not coalesce(public.photo_publication_verified(p_verified_input,s#>>'{source_input,sha256}',(s#>>'{source_input,bytes}')::bigint,s#>>'{source_input,mime}',s#>>'{source_input,etag}'),false)
  or not coalesce(public.photo_publication_verified(p_verified_output,s#>>'{source_output,sha256}',(s#>>'{source_output,bytes}')::bigint,s#>>'{source_output,mime}',s#>>'{source_output,etag}'),false)
 then raise exception'RP409: Exact retained source and output body proofs are required';end if;
 if t->'publication'is not null and t->'publication'<>'null'::jsonb then
  select*into m from public.media_provenance where id=(t#>>'{publication,id}')::uuid for update;
  if m.photo_publication->>'phase'='prepared'then
   if not public.photo_publication_metadata_valid(m.id)then raise exception'RP404: Saved publication is no longer available';end if;
   return t||jsonb_build_object('dispatch',false,
    'copy_operation',(select to_jsonb(oo)||jsonb_build_object('dispatch',false)from public.upload_operations oo where oo.id=(m.photo_publication#>>'{copy,operation_id}')::uuid),
    'copy_asset',jsonb_build_object('asset_id',m.photo_publication#>>'{target,source_copy_asset_id}','key',m.original_key,'bytes',(m.photo_publication#>>'{input,bytes}')::bigint,'mime',m.photo_publication#>>'{input,mime}','sha256',m.photo_publication#>>'{input,sha256}','etag',m.photo_publication#>>'{copy,source_copy_etag}'));
  end if;
 else
  source_m:=jsonb_populate_record(null::public.media_provenance,s->'provenance');
  ext:=case s#>>'{source_input,mime}'when'image/jpeg'then'jpg'when'image/png'then'png'else'webp'end;
  key:='renders/'||p_org||'/'||p_listing||'/original-'||copy_asset||'.'||ext;
  p:=jsonb_build_object('schema',1,'phase','preparing','source',jsonb_build_object(
   'evidence_id',p_evidence,'provenance_id',source_m.id,'automatic_check_id',s#>>'{check,id}','actor_id',p_actor,'org_id',p_org,'library_org_id',p_library,'listing_id',null,
   'request_key',s#>>'{evidence,request_key}','request_sha256',s#>>'{evidence,request_sha256}'),
   'target',jsonb_build_object('listing_id',p_listing,'org_id',p_org,'library_org_id',p_library,'output_asset_id',p_asset,'source_copy_asset_id',copy_asset),
   'input',p_verified_input,'output',p_verified_output,'copy',jsonb_build_object('operation_id',op,'source_copy_etag',null,
   'target_output_upload_operation_id',t#>>'{target,operation_id}','target_output_etag',t#>>'{target,etag}'),
   'created_at',clock_timestamp(),'prepared_at',null,'input_role','submitted_prepared_source');
  insert into public.media_provenance(id,org_id,listing_id,kind,label,model_id,edit,style,original_key,altered_key,disclosure,qc,qc_checked_at,photo_publication)
  values(pub,p_org,p_listing,source_m.kind,source_m.label,source_m.model_id,source_m.edit,source_m.style,key,t#>>'{target,key}',source_m.disclosure,source_m.qc,source_m.qc_checked_at,p)returning*into m;
 end if;
 -- Locks and the immutable receipt stay held in the outer RPC transaction.
 -- No upload helper runs under this privileged validation identity.
 return t||jsonb_build_object('publication',jsonb_build_object('id',m.id,'photo_publication',m.photo_publication),
  'copy_asset',jsonb_build_object('asset_id',m.photo_publication#>>'{target,source_copy_asset_id}','key',m.original_key,'bytes',(m.photo_publication#>>'{input,bytes}')::bigint,'mime',m.photo_publication#>>'{input,mime}','sha256',m.photo_publication#>>'{input,sha256}','etag',null));
end$$;

-- Service-only invoker orchestration. Returning from the privileged helper does
-- not release transaction locks; later refusal rolls back receipt and budget.
create function public.photo_publication_reserve(p_actor uuid,p_org uuid,p_library uuid,p_listing uuid,p_asset uuid,p_evidence uuid,p_verified_input jsonb,p_verified_output jsonb,p_verified_target jsonb,p_claim uuid)returns jsonb
language plpgsql security invoker set search_path=''as $$
declare r jsonb;io jsonb;
begin
 if current_setting('role',true)is distinct from'service_role'or current_user is distinct from'service_role'or p_claim is null then raise insufficient_privilege;end if;
 r:=public.photo_publication_reserve_locked(p_actor,p_org,p_library,p_listing,p_asset,p_evidence,p_verified_input,p_verified_output,p_verified_target,p_claim);
 if r#>>'{publication,photo_publication,phase}'='prepared'then return r;end if;
 io:=public.photo_publication_upload_reserve(p_actor,(r#>>'{publication,id}')::uuid,p_claim);
 return r||jsonb_build_object('dispatch',io->'dispatch','copy_operation',io,'copy_asset',(r->'copy_asset')||jsonb_build_object('etag',io->'etag'));
end$$;

create function public.photo_publication_finish_locked(p_actor uuid,p_org uuid,p_library uuid,p_listing uuid,p_publication uuid,p_verified_source jsonb,p_verified_target jsonb)returns jsonb
language plpgsql security definer set search_path=''as $$
declare m public.media_provenance;p jsonb;s jsonb;t jsonb;a jsonb;
begin
 if current_setting('role',true)is distinct from'service_role'then raise insufficient_privilege;end if;
 perform 1 from auth.users where id=p_actor for update;perform 1 from public.profiles where id=p_actor for update;
 perform 1 from public.orgs where id=p_org for update;perform 1 from public.listings where id=p_listing for update;
 select*into m from public.media_provenance where id=p_publication for update;p:=m.photo_publication;
 if p is null or m.org_id is distinct from p_org or m.listing_id is distinct from p_listing
  or p#>>'{source,actor_id}'is distinct from p_actor::text or p#>>'{target,library_org_id}'is distinct from p_library::text
 then raise exception'RP404: Photo publication is unavailable';end if;
 perform 1 from public.photo_edit_evidence where id=(p#>>'{source,evidence_id}')::uuid for update;
 perform 1 from public.photo_quality_checks where id=(p#>>'{source,automatic_check_id}')::uuid for update;
 s:=public.photo_publication_source(p_actor,p_org,p_library,(p#>>'{source,evidence_id}')::uuid);
 t:=public.photo_publication_resolve(p_actor,p_org,p_library,p_listing,(p#>>'{target,output_asset_id}')::uuid,(p#>>'{source,provenance_id}')::uuid,p_verified_target);
 if t is null or t#>>'{publication,id}'is distinct from m.id::text then raise exception'RP409: Publication target changed';end if;
 if not coalesce(public.photo_publication_verified(p_verified_source,p#>>'{input,sha256}',(p#>>'{input,bytes}')::bigint,p#>>'{input,mime}',p_verified_source->>'etag'),false)
  or nullif(p_verified_source->>'etag','')is null or length(p_verified_source->>'etag')>256 then raise exception'RP409: Exact submitted source copy proof is required';end if;
 if p->>'phase'='prepared'then
  if not public.photo_publication_metadata_valid(m.id)or p#>>'{copy,source_copy_etag}'is distinct from p_verified_source->>'etag'then raise exception'RP409: Prepared publication changed';end if;
 end if;
 return t||jsonb_build_object('publication',jsonb_build_object('id',m.id,'photo_publication',m.photo_publication),'dispatch',false,
  'copy_asset',jsonb_build_object('asset_id',p#>>'{target,source_copy_asset_id}','key',m.original_key,'bytes',(p#>>'{input,bytes}')::bigint,'mime',p#>>'{input,mime}','sha256',p#>>'{input,sha256}','etag',p#>>'{copy,source_copy_etag}'));
end$$;

-- Receipt commit revalidates the same locked facts. Without existing upload
-- settlement, complete metadata validity fails and rolls back this RPC.
create function public.photo_publication_finish_commit(p_actor uuid,p_org uuid,p_library uuid,p_listing uuid,p_publication uuid,p_verified_source jsonb,p_verified_target jsonb)returns jsonb
language plpgsql security definer set search_path=''as $$
declare r jsonb;p jsonb;m public.media_provenance;
begin
 if current_setting('role',true)is distinct from'service_role'then raise insufficient_privilege;end if;
 r:=public.photo_publication_finish_locked(p_actor,p_org,p_library,p_listing,p_publication,p_verified_source,p_verified_target);
 p:=r#>'{publication,photo_publication}';
 if p->>'phase'='prepared'then return r;end if;
 p:=jsonb_set(jsonb_set(jsonb_set(p,'{phase}','"prepared"'::jsonb),'{prepared_at}',to_jsonb(clock_timestamp())),'{copy,source_copy_etag}',to_jsonb(p_verified_source->>'etag'));
 update public.media_provenance set photo_publication=p where id=p_publication returning*into m;
 if not public.photo_publication_metadata_valid(m.id)then raise exception'RP409: The complete publication proof could not be verified';end if;
 return r||jsonb_build_object('publication',jsonb_build_object('id',m.id,'photo_publication',m.photo_publication),'copy_asset',(r->'copy_asset')||jsonb_build_object('etag',p_verified_source->>'etag'));
end$$;

create function public.photo_publication_finish(p_actor uuid,p_org uuid,p_library uuid,p_listing uuid,p_publication uuid,p_verified_source jsonb,p_verified_target jsonb)returns jsonb
language plpgsql security invoker set search_path=''as $$
declare r jsonb;
begin
 if current_setting('role',true)is distinct from'service_role'or current_user is distinct from'service_role'then raise insufficient_privilege;end if;
 r:=public.photo_publication_finish_locked(p_actor,p_org,p_library,p_listing,p_publication,p_verified_source,p_verified_target);
 if r#>>'{publication,photo_publication,phase}'='prepared'then return r;end if;
 perform public.photo_publication_upload_finish(p_actor,p_publication,p_verified_source);
 return public.photo_publication_finish_commit(p_actor,p_org,p_library,p_listing,p_publication,p_verified_source,p_verified_target);
end$$;

-- Reader/cleanup expansions follow below; physical R2 body existence is checked
-- at the shared Edge visibility admission, not falsely claimed by SQL metadata.

create function public.photo_publication_objects(p_publication uuid)returns jsonb
language plpgsql stable security definer set search_path=''as $$
declare m public.media_provenance;p jsonb;s jsonb;
begin
 if not public.photo_publication_metadata_valid(p_publication)then raise exception'RP404: Photo publication is no longer available';end if;
 select*into m from public.media_provenance where id=p_publication;p:=m.photo_publication;
 s:=public.photo_publication_source((p#>>'{source,actor_id}')::uuid,(p#>>'{source,org_id}')::uuid,(p#>>'{source,library_org_id}')::uuid,(p#>>'{source,evidence_id}')::uuid);
 return jsonb_build_array(
  ((s->'source_input')-'sha256')||jsonb_build_object('bucket','renders'),
  ((s->'source_output')-'sha256')||jsonb_build_object('bucket','renders'),
  jsonb_build_object('bucket','renders','key',m.original_key,'bytes',(p#>>'{input,bytes}')::bigint,'mime',p#>>'{input,mime}','etag',p#>>'{copy,source_copy_etag}'),
  jsonb_build_object('bucket','renders','key',m.altered_key,'bytes',(p#>>'{output,bytes}')::bigint,'mime',p#>>'{output,mime}','etag',p#>>'{copy,target_output_etag}'));
end$$;

create function public.photo_publication_read_objects(p_listing uuid,p_key text)returns jsonb
language plpgsql stable security definer set search_path=''as $$
declare m record;result jsonb:='[]'::jsonb;
begin
 if current_setting('role',true)is distinct from'service_role'then raise insufficient_privilege;end if;
 for m in select id from public.media_provenance where listing_id=p_listing and photo_publication is not null and(original_key=p_key or altered_key=p_key)loop
  result:=result||public.photo_publication_objects(m.id);
 end loop;
 return result;
end$$;

create function public.photo_publication_visibility(p_listing uuid,p_assets uuid[],p_keys text[])returns jsonb
language plpgsql stable security definer set search_path=''as $$
declare m record;p jsonb;result jsonb:='[]'::jsonb;
begin
 for m in select id,original_key,altered_key,photo_publication from public.media_provenance where listing_id=p_listing and photo_publication is not null and(
  photo_publication#>>'{target,output_asset_id}'=any(array(select x::text from unnest(p_assets)x))
  or photo_publication#>>'{target,source_copy_asset_id}'=any(array(select x::text from unnest(p_assets)x))
  or original_key=any(p_keys)or altered_key=any(p_keys))order by id loop
  -- Invalid/preparing associations have already failed the asset/key boolean.
  -- Never present an empty descriptor as physical-object approval.
  if public.photo_publication_metadata_valid(m.id)then
   p:=m.photo_publication;
   result:=result||jsonb_build_array(jsonb_build_object('publication_id',m.id,'org_id',(p#>>'{target,org_id}')::uuid,'listing_id',p_listing,
    'assets',jsonb_build_array(p#>>'{target,output_asset_id}',p#>>'{target,source_copy_asset_id}'),
    'keys',jsonb_build_array(m.original_key,m.altered_key),'objects',public.photo_publication_objects(m.id)));
  end if;
 end loop;
 return result;
end$$;

-- Modify exact reviewed bodies in place; original ACLs/RLS/OIDs remain in force.
do $readers$declare d text;needle text;replacement text;begin
 d:=pg_get_functiondef('public.studio_presenter_media_access_inner(uuid)'::regprocedure);
 needle:='  select * into a from public.capture_assets where id=current_id;';
 if(length(d)-length(replace(d,needle,'')))<>length(needle)then raise exception'Review photo publication asset walk seam';end if;
 execute replace(d,needle,E'  if not public.photo_publication_asset_valid(current_id)then return false;end if;\n'||needle);
 d:=pg_get_functiondef('public.studio_presenter_key_access(uuid,text)'::regprocedure);
 needle:=' if current_setting(''role'',true)=''authenticated''';
 if(length(d)-length(replace(d,needle,'')))<>length(needle)then raise exception'Review photo publication key read seam';end if;
 execute replace(d,needle,E' if not public.photo_publication_key_valid(p_listing,p_key)then return false;end if;\n'||needle);
 d:=pg_get_functiondef('public.studio_photo_asset_key(uuid,uuid,uuid)'::regprocedure);
 needle:=' return a.storage_key;';
 if(length(d)-length(replace(d,needle,'')))<>length(needle)then raise exception'Review photo publication photo key seam';end if;
 execute replace(d,needle,E' if not public.photo_publication_asset_valid(p_asset)then raise exception''RP409: Saved photo publication is no longer available'';end if;\n'||needle);
 -- The existing quality assertion calls the same guarded Presenter walk.
 d:=pg_get_functiondef('public.studio_presenter_media_visibility(uuid,uuid[],uuid[],text[])'::regprocedure);
 needle:='return jsonb_build_object(''assets'',assets,''renders'',renders,''keys'',keys);';
 if(length(d)-length(replace(d,needle,'')))<>length(needle)then raise exception'Review photo publication visibility return seam';end if;
 replacement:='return jsonb_build_object(''assets'',assets,''renders'',renders,''keys'',keys,''photo_publications'',public.photo_publication_visibility(p_listing,p_assets,p_keys));';
 execute replace(d,needle,replacement);
end$readers$;

-- Preserve a marker until its target parent itself is unavailable. Removing
-- assets first does not prove an old canonical URL cannot still resolve.
-- Source erasure queues only canonical copies/output aliases, never the source
-- evidence's private originals; the old evidence cleanup owns those originals.
do $cleanup_kind$declare def text;begin
 select pg_get_constraintdef(oid)into def from pg_constraint where conrelid='public.privacy_cleanup_jobs'::regclass and conname='privacy_cleanup_jobs_kind_check';
 if def is distinct from 'CHECK ((kind = ANY (ARRAY[''lead''::text, ''listing''::text])))'then raise exception'Review privacy cleanup kind constraint';end if;
 alter table public.privacy_cleanup_jobs drop constraint privacy_cleanup_jobs_kind_check;
 alter table public.privacy_cleanup_jobs add constraint privacy_cleanup_jobs_kind_check check(kind in('lead','listing','photo_publication'));
end$cleanup_kind$;

create function public.photo_publication_source_erasure()returns trigger
language plpgsql security definer set search_path=''as $$
declare m record;targets jsonb;payload jsonb;deadline timestamptz;source_uuid uuid;actor uuid;org uuid;
begin
 -- Publication deletion is separately protected. This trigger follows only
 -- the ORIGINAL source evidence/provenance deletion and leaves markers intact.
 if tg_table_name='media_provenance'and to_jsonb(old)->'photo_publication'is not null and to_jsonb(old)->'photo_publication'<>'null'::jsonb then return old;end if;
 source_uuid:=old.id;
 for m in select id,org_id,photo_publication,original_key,altered_key from public.media_provenance where photo_publication is not null and
  ((tg_table_name='photo_edit_evidence'and photo_publication#>>'{source,evidence_id}'=source_uuid::text)
   or(tg_table_name='media_provenance'and photo_publication#>>'{source,provenance_id}'=source_uuid::text)
   or(tg_table_name='listings'and listing_id=source_uuid)or(tg_table_name='orgs'and org_id=source_uuid))loop
  actor:=(m.photo_publication#>>'{source,actor_id}')::uuid;org:=m.org_id;
  targets:=jsonb_build_array(jsonb_build_object('bucket','renders','key',m.original_key),jsonb_build_object('bucket','renders','key',m.altered_key));
  payload:=jsonb_build_object('r2',targets,'stream_uids','[]'::jsonb,'ghl_targets','[]'::jsonb);
  select greatest(clock_timestamp()+interval'1 hour',max(write_deadline)+interval'1 hour')into deadline from public.upload_operations
   where id in((m.photo_publication#>>'{copy,operation_id}')::uuid,(m.photo_publication#>>'{copy,target_output_upload_operation_id}')::uuid);
  insert into public.privacy_cleanup_jobs(kind,org_id,source_id,source_user_id,payload,remaining,not_before)
  values('photo_publication',org,m.id,actor,payload,payload,deadline)on conflict(kind,source_id)do nothing;
 end loop;
 return old;
end$$;
create trigger photo_publication_evidence_erasure before delete on public.photo_edit_evidence for each row execute function public.photo_publication_source_erasure();
create trigger photo_publication_provenance_erasure before delete on public.media_provenance for each row execute function public.photo_publication_source_erasure();
create trigger photo_publication_listing_erasure before delete on public.listings for each row execute function public.photo_publication_source_erasure();
create trigger photo_publication_org_erasure before delete on public.orgs for each row execute function public.photo_publication_source_erasure();

create function public.photo_publication_media_targets(p_orgs uuid[],p_listing uuid default null)returns jsonb
language sql stable security definer set search_path=''as $$
 select coalesce(jsonb_agg(distinct jsonb_build_object('bucket','renders','key',x.key,'valid',
 starts_with(x.key,'renders/'||m.org_id||'/'||m.listing_id||'/')and x.key!~'[?#%\\[:cntrl:]]|(^|/)[.]{1,2}(/|$)')),'[]'::jsonb)
 from public.media_provenance m cross join lateral(select m.original_key key union select m.altered_key)x
 where m.photo_publication is not null and m.org_id=any(p_orgs)and(p_listing is null or m.listing_id=p_listing)and x.key is not null;
$$;
do $cleanup$declare d text;needle text;replacement text;begin
 -- Existing cleanup inventory already retains all ordinary capture objects;
 -- this explicit marker inventory also survives asset removal before erasure.
 d:=pg_get_functiondef('public.account_private_output_targets(uuid[],text,text)'::regprocedure);
 needle:='prior:=public.photo_quality_previous_account_targets(p_orgs,p_upload_bucket,p_render_bucket);';
 if(length(d)-length(replace(d,needle,'')))<>length(needle)then raise exception'Review account publication inventory seam';end if;
 execute replace(d,needle,needle||E'\n'||' prior:=prior||(select coalesce(jsonb_agg(v||jsonb_build_object(''bucket'',p_render_bucket)),''[]''::jsonb)from jsonb_array_elements(public.photo_publication_media_targets(p_orgs,null))v);');
 d:=pg_get_functiondef('public.queue_listing_media_cleanup(uuid)'::regprocedure);
 needle:='from jsonb_array_elements(public.photo_quality_media_targets(array[l.org_id],l.id))v;';
 if(length(d)-length(replace(d,needle,'')))<>length(needle)then raise exception'Review listing publication inventory seam';end if;
 replacement:='from jsonb_array_elements(public.photo_quality_media_targets(array[l.org_id],l.id)||public.photo_publication_media_targets(array[l.org_id],l.id))v;';
 execute replace(d,needle,replacement);
end$cleanup$;

-- Only request-owning service Edge may construct/resolve publications. Internal
-- public-reading predicates execute as their existing privileged callers.
do $acl$declare f regprocedure;begin
 for f in select oid::regprocedure from pg_proc where pronamespace='public'::regnamespace and proname like'photo_publication_%'loop
  execute format('revoke all on function %s from public,anon,authenticated',f);
  execute format('grant execute on function %s to service_role,postgres',f);
 end loop;
 -- The previous walk is internal preparation-only, never a client read bypass.
 revoke all on function public.photo_publication_prior_media_access_inner(uuid)from public,anon,authenticated,service_role;
end$acl$;
commit;
