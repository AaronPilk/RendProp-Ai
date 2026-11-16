\set ON_ERROR_STOP on
begin;
do $$begin if inet_server_addr() is not null or current_database() <> 'native_photo_backup_proof'
  then raise exception 'Run only in the owned socket-only native photo fixture'; end if; end$$;
create temp table checks(label text primary key);
grant all on checks to service_role;
create function pg_temp.ok(value boolean, label text) returns void language plpgsql as $$
begin if value is distinct from true then raise exception 'NATIVE BACKUP FAIL: %', label; end if;
  insert into checks values(label); end$$;
create function pg_temp.denied(command text, label text, prefix text default 'RP409:') returns void language plpgsql as $$
declare message text; begin begin execute command; exception when others then message := sqlerrm; end;
  perform pg_temp.ok(message like prefix || '%', label); end$$;
create temp table fixture(actor uuid, outsider uuid, org uuid, foreign_org uuid, listing uuid,
  foreign_listing uuid, family text, edit_id text, original uuid, enhanced uuid, changed uuid, foreign_asset uuid,
  original_ref jsonb, enhanced_ref jsonb, changed_ref jsonb, source jsonb, capture jsonb, edit jsonb);
do $$
declare
  a uuid := gen_random_uuid(); b uuid := gen_random_uuid(); o uuid; oo uuid;
  l uuid := gen_random_uuid(); ll uuid := gen_random_uuid();
  family text := gen_random_uuid()::text; edit_id text := gen_random_uuid()::text;
  original uuid := gen_random_uuid(); enhanced uuid := gen_random_uuid(); changed uuid := gen_random_uuid();
  foreign_asset uuid := gen_random_uuid(); original_ref jsonb; enhanced_ref jsonb; changed_ref jsonb;
  source jsonb; capture jsonb; edit jsonb;
begin
  insert into auth.users(id,email,is_anonymous) values
    (a,'native-backup-owner@fixture.invalid',false),(b,'native-backup-other@fixture.invalid',false);
  select org_id into strict o from memberships where user_id = a and role = 'owner' limit 1;
  select org_id into strict oo from memberships where user_id = b and role = 'owner' limit 1;
  update orgs set plan = 'starter', plan_source = 'manual' where id in (o,oo);
  insert into listings(id,org_id,agent_id,address) values
    (l,o,a,'Native backup synthetic home'),(ll,oo,b,'Other synthetic home');
  insert into capture_assets(id,listing_id,kind,bucket,storage_key,sha256,bytes,uploaded,
    content_type,content_type_declared,transport_version) values
    (original,l,'photo','uploads','uploads/'||o||'/'||l||'/'||original||'.heic',repeat('a',64),100,true,'image/heic',true,2),
    (enhanced,l,'photo','uploads','uploads/'||o||'/'||l||'/'||enhanced||'-complete-'||gen_random_uuid()||'.jpg',repeat('b',64),200,true,'image/jpeg',true,2),
    (changed,l,'photo','uploads','uploads/'||o||'/'||l||'/'||changed||'-complete-'||gen_random_uuid()||'.png',repeat('c',64),300,true,'image/png',true,2),
    (foreign_asset,ll,'photo','uploads','uploads/'||oo||'/'||ll||'/'||foreign_asset||'.jpg',repeat('d',64),400,true,'image/jpeg',true,2);
  insert into upload_reservations(asset_id,org_id,listing_id,actor_id,day,spec,held_bytes,state,settled_at)
    select id,case when id = foreign_asset then oo else o end,
      listing_id,case when id = foreign_asset then b else a end,current_date,
      jsonb_build_object('kind','photo','bucket','uploads','key_role','default',
        'bytes',bytes,'content_type',content_type,'content_type_declared',true),0,'completed',clock_timestamp()
    from capture_assets where id in (original,enhanced,changed,foreign_asset);
  insert into upload_operations(asset_id,kind,bucket,object_key,bytes,expected_bytes,
    content_type,content_type_declared,asset_kind,state,etag)
    select id,'copy','uploads',storage_key,bytes,bytes,content_type,true,'photo','retained','synthetic-only-etag'
    from capture_assets where id in (original,enhanced,changed,foreign_asset);
  original_ref := jsonb_build_object('asset_id',original,'sha256',repeat('a',64),'bytes',100,'content_type','image/heic');
  enhanced_ref := jsonb_build_object('asset_id',enhanced,'sha256',repeat('b',64),'bytes',200,'content_type','image/jpeg');
  changed_ref := jsonb_build_object('asset_id',changed,'sha256',repeat('c',64),'bytes',300,'content_type','image/png');
  capture := jsonb_build_object('schema',1,'listing_id',l,'version_id',family,'family_id',family,
    'image_file','enh-'||family||'.jpg','original_file','orig-'||family||'.jpg',
    'image',enhanced_ref,'original',original_ref,'parent_id',null,'source_id',null,
    'staging_base_id',null,'staging_reference_id',null,'edit','capture','style',null,
    'effects','[]'::jsonb,'disclosure',null,'provenance_id',null,'provenance_recorded',false,
    'created_at','2026-11-04T20:00:00Z');
  source := capture || jsonb_build_object('version_id',family||'-original',
    'image_file','orig-'||family||'.jpg','image',original_ref,'edit','capture-original');
  edit := capture || jsonb_build_object('version_id',edit_id,'image_file','edit-'||edit_id||'.png',
    'image',changed_ref,'parent_id',family,'source_id',family||'-original','edit','declutter',
    'effects',jsonb_build_array('declutter'),'disclosure','Digitally decluttered');
  insert into fixture values(a,b,o,oo,l,ll,family,edit_id,original,enhanced,changed,foreign_asset,
    original_ref,enhanced_ref,changed_ref,source,capture,edit);
end$$;
grant select on fixture to service_role;
select pg_temp.ok(not has_table_privilege('authenticated','native_photo_backup_versions','select')
  and not has_table_privilege('service_role','native_photo_backup_versions','insert'),
  'manifest rows have no direct client or service write');
select pg_temp.ok(not has_function_privilege('authenticated','native_photo_backup_commit(uuid,uuid,uuid,uuid,jsonb)','execute')
  and has_function_privilege('service_role','native_photo_backup_commit(uuid,uuid,uuid,uuid,jsonb)','execute')
  and not has_function_privilege('service_role','native_photo_backup_asset_ready(uuid,uuid,jsonb,uuid)','execute'),
  'only the scoped service RPC can commit');
select pg_temp.ok(public.native_photo_backup_asset_ready(org,listing,original_ref,actor),
  'completed HEIC exact original receipt is eligible') from fixture;
select pg_temp.ok(not public.native_photo_backup_asset_ready(org,listing,
  original_ref || jsonb_build_object('sha256',repeat('f',64)),actor),
  'wrong hash does not match retained receipt') from fixture;
select pg_temp.ok(not public.native_photo_backup_asset_ready(org,listing,original_ref,outsider),
  'new image receipt belongs to current uploader') from fixture;
set local role service_role;
do $$declare f fixture; r jsonb; page jsonb; begin
  select * into f from fixture;
  perform pg_temp.denied(format('select public.native_photo_backup_commit(%L,%L,%L,%L,%L::jsonb)',
    f.actor,f.org,f.org,f.listing,f.capture),'root cannot predate retained original');
  r := public.native_photo_backup_commit(f.actor,f.org,f.org,f.listing,f.source);
  perform pg_temp.ok(r->>'version_id'=f.family||'-original' and r->>'replayed'='false' and r->>'available'='true',
    'synthetic original commit acknowledges exact retained bytes');
  r := public.native_photo_backup_commit(f.actor,f.org,f.org,f.listing,f.capture);
  perform pg_temp.ok(r->>'version_id'=f.family and r->>'replayed'='false',
    'enhanced capture commits after original');
  r := public.native_photo_backup_commit(f.actor,f.org,f.org,f.listing,f.capture);
  perform pg_temp.ok(r->>'replayed'='true', 'lost reply exact replay is acknowledged');
  perform pg_temp.denied(format('select public.native_photo_backup_commit(%L,%L,%L,%L,%L::jsonb)',
    f.actor,f.org,f.org,f.listing,f.capture||jsonb_build_object('created_at','2026-11-04T20:01:00Z')),
    'same key cannot change timestamp');
  perform pg_temp.denied(format('select public.native_photo_backup_commit(%L,%L,%L,%L,%L::jsonb)',
    f.actor,f.org,f.org,f.listing,f.edit||jsonb_build_object('source_id','missing')),
    'edit cannot claim unknown source');
  r := public.native_photo_backup_commit(f.actor,f.org,f.org,f.listing,f.edit);
  perform pg_temp.ok(r->>'version_id'=f.edit_id and r->>'family_id'=f.family,
    'edit records parent, source and original lineage');
  page := public.native_photo_backup_read(f.actor,f.org,f.org,f.listing,null,0);
  perform pg_temp.ok(jsonb_array_length(page->'versions')=3 and page->'next_offset'='null'::jsonb,
    'private listing read includes all committed graph nodes');
  page := public.native_photo_backup_read(f.actor,f.org,f.org,f.listing,f.edit_id,0);
  perform pg_temp.ok(jsonb_array_length(page->'versions')=1 and page#>>'{versions,0,version_id}'=f.edit_id,
    'exact version probe recovers lost commit reply');
  perform pg_temp.ok((select gallery_asset_ids is null and main_photo_key is null from listings where id=f.listing),
    'private backup does not select or publish a listing photo');
  r := public.native_photo_backup_download(f.actor,f.org,f.org,f.listing,f.original);
  perform pg_temp.ok(r->>'asset_id'=f.original::text and r->>'content_type'='image/heic'
    and r->>'storage_key'='uploads/'||f.org||'/'||f.listing||'/'||f.original||'.heic',
    'manifest-only original is restorable by exact private storage key');
  r := public.native_photo_backup_download(f.actor,f.org,f.org,f.listing,f.changed);
  perform pg_temp.ok(r->>'asset_id'=f.changed::text and r->>'content_type'='image/png',
    'committed AI edit is restorable even when never in gallery');
  perform pg_temp.denied(format('select public.native_photo_backup_download(%L,%L,%L,%L,%L)',
    f.outsider,f.org,f.org,f.listing,f.original),
    'foreign account cannot resolve original download','RP404:');
  perform pg_temp.denied(format('select public.native_photo_backup_download(%L,%L,%L,%L,%L)',
    f.actor,f.org,f.foreign_org,f.listing,f.original),
    'wrong selected library cannot resolve download','RP404:');
  perform pg_temp.denied(format('select public.native_photo_backup_download(%L,%L,%L,%L,%L)',
    f.actor,f.org,f.org,f.listing,f.foreign_asset),
    'other listing asset cannot resolve by guessed UUID','RP404:');
  perform pg_temp.denied(format('select public.native_photo_backup_read(%L,%L,%L,%L,null,0)',
    f.outsider,f.org,f.org,f.listing),'foreign actor cannot read private lineage','RP404:');
  perform pg_temp.denied(format('select public.native_photo_backup_read(%L,%L,%L,%L,null,0)',
    f.actor,f.org,f.foreign_org,f.listing),'selected library must own the listing','RP404:');
  perform pg_temp.denied(format('select public.native_photo_backup_commit(%L,%L,%L,%L,%L::jsonb)',
    f.actor,f.org,f.org,f.listing,f.edit||jsonb_build_object('version_id',gen_random_uuid(),
      'image',jsonb_build_object('asset_id',f.foreign_asset,'sha256',repeat('d',64),'bytes',400,'content_type','image/jpeg'))),
    'cross-listing photo upload is not usable');
end$$;
reset role;
delete from capture_assets where id = (select changed from fixture);
set local role service_role;
do $$declare f fixture; page jsonb; begin
  select * into f from fixture;
  page := public.native_photo_backup_read(f.actor,f.org,f.org,f.listing,f.edit_id,0);
  perform pg_temp.ok(page#>'{versions,0,available}'='false'::jsonb
    and jsonb_array_length(page->'versions')=1,
    'asset removal leaves immutable lineage visible but unavailable');
  perform pg_temp.denied(format('select public.native_photo_backup_download(%L,%L,%L,%L,%L)',
    f.actor,f.org,f.org,f.listing,f.changed),
    'removed asset cannot receive a fresh restore URL','RP404:');
end$$;
reset role;
select json_build_object('passed',true,'assertions',(select count(*) from checks));
rollback;
