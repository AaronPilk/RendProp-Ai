\set ON_ERROR_STOP on
begin;
do $$begin if current_database()<>'rendprop_audit' or inet_server_addr() is not null then raise exception 'Owned socket-only fixture required';end if;end$$;
create temp table floorplan_checks(name text);
create function pg_temp.plan_check(ok boolean,label text) returns void language plpgsql as $$begin
 if ok is distinct from true then raise exception 'FLOORPLAN FAIL: %',label;end if;
 insert into floorplan_checks values(label);
end$$;
create function pg_temp.plan_refuses(q text,code text,label text) returns void language plpgsql as $$begin
 begin execute q;exception when others then
  if sqlstate=code then perform pg_temp.plan_check(true,label);return;end if;
  raise exception 'FLOORPLAN FAIL: % expected %, got % %',label,code,sqlstate,sqlerrm;
 end;raise exception 'FLOORPLAN FAIL: % did not refuse',label;
end$$;
create temp table floorplan_ids as select gen_random_uuid() actor,gen_random_uuid() outsider,gen_random_uuid() listing,
 gen_random_uuid() foreign_listing,gen_random_uuid() asset,gen_random_uuid() foreign_asset,null::uuid org,null::uuid foreign_org;
do $$declare f floorplan_ids;begin select * into f from floorplan_ids;
 insert into auth.users(id,email)values(f.actor,'floorplan-owner@fixture.invalid'),(f.outsider,'floorplan-outsider@fixture.invalid');
 select org_id into f.org from public.memberships where user_id=f.actor limit 1;
 select org_id into f.foreign_org from public.memberships where user_id=f.outsider limit 1;
 update floorplan_ids set org=f.org,foreign_org=f.foreign_org;
 insert into public.listings(id,org_id,agent_id,address,details)values
 (f.listing,f.org,f.actor,'Owned plan fixture','{"hours":"office hours","office_note":"untouched","floorMeasurementsV9":"future-private","floor_measurements_v1":"{\"version\":1,\"unit\":\"meters\",\"rooms\":[],\"updatedAt\":1}"}'),
 (f.foreign_listing,f.foreign_org,f.outsider,'Foreign plan fixture','{}');
 insert into public.capture_assets(id,listing_id,kind,bucket,uploaded,content_type,storage_key)values
 (f.asset,f.listing,'photo','renders',true,'image/jpeg','renders/'||f.org||'/'||f.listing||'/gallery-'||f.asset||'.jpg'),
 (f.foreign_asset,f.foreign_listing,'photo','renders',true,'image/jpeg','renders/'||f.foreign_org||'/'||f.foreign_listing||'/gallery-'||f.foreign_asset||'.jpg');
end$$;
grant select on floorplan_ids to authenticated,service_role;
grant all on floorplan_checks to service_role;
-- Deletion intent is deliberately not directly writable by service_role.
-- This owned fixture helper can affect only its synthetic actor.
create function pg_temp.plan_deletion_fixture(active boolean)returns void language plpgsql security definer set search_path='' as $$begin
 if active then insert into public.deletion_requests(user_id,status)select actor,'pending'from pg_temp.floorplan_ids;
 else delete from public.deletion_requests where user_id=(select actor from pg_temp.floorplan_ids);end if;
end$$;
revoke all on function pg_temp.plan_deletion_fixture(boolean)from public;
grant execute on function pg_temp.plan_deletion_fixture(boolean)to service_role;
create function pg_temp.plan_bad_asset(kind_case text)returns uuid language plpgsql security definer set search_path='' as $$
declare f pg_temp.floorplan_ids;asset uuid:=gen_random_uuid();key text;begin
 select * into f from pg_temp.floorplan_ids;
 key:='renders/'||f.org||'/'||f.listing||'/gallery-'||asset||'.jpg';
 if kind_case='headshot' then key:='renders/'||f.org||'/'||f.listing||'/contact-'||asset||'.jpg';end if;
 if kind_case='traversal' then key:='renders/'||f.org||'/'||f.listing||'/../foreign.jpg';end if;
 insert into public.capture_assets(id,listing_id,kind,bucket,uploaded,content_type,storage_key)values
 (asset,f.listing,case when kind_case='video' then 'video' else 'photo' end,
 case when kind_case='uploads' then 'uploads' else 'renders' end,kind_case<>'incomplete',
 case when kind_case='missing_mime' then null else 'image/jpeg' end,key);
 return asset;
end$$;
revoke all on function pg_temp.plan_bad_asset(text)from public;
grant execute on function pg_temp.plan_bad_asset(text)to service_role;
set local role authenticated;
select set_config('request.jwt.claims',jsonb_build_object('sub',actor,'role','authenticated')::text,true)from floorplan_ids;
do $$begin
 begin update public.listings set details='{}'where id=(select listing from floorplan_ids);
  raise exception 'FLOORPLAN FAIL: Direct client details replacement bypassed the fence';
 exception when insufficient_privilege then null;end;
end$$;
set local role service_role;
do $$declare f floorplan_ids;old_details jsonb;received jsonb;attached jsonb;r jsonb;q text;url text;key text;client text;before_row jsonb;bad uuid;bad_key text;begin
 select * into f from floorplan_ids;select details into old_details from public.listings where id=f.listing;
 select storage_key into key from public.capture_assets where id=f.asset;url:='https://fixture.invalid/'||key;
 perform pg_temp.plan_check(not has_column_privilege('authenticated','public.listings','details','update'),'Ordinary details grant remains revoked');
 foreach client in array array['anon','authenticated']loop
  perform pg_temp.plan_check(not has_function_privilege(client,'public.studio_attach_floorplan(uuid,uuid,uuid,uuid,jsonb,text)','execute'),'Dedicated RPC denies '||client);
 end loop;
 perform pg_temp.plan_check(has_function_privilege('service_role','public.studio_attach_floorplan(uuid,uuid,uuid,uuid,jsonb,text)','execute'),'Dedicated RPC permits service');
 r:=public.studio_attach_floorplan(f.actor,f.org,f.listing,f.asset,old_details,url);received:=r->'details';
 perform pg_temp.plan_check(r->>'id'=f.listing::text and received->>'floorplan_asset_id'=f.asset::text and received->>'floorplan_url'=url,'Authorized atomic floorplan attachment succeeds');
 perform pg_temp.plan_check(received->>'office_note'='untouched' and received->>'hours'='office hours' and received->'floor_measurements_v1'=old_details->'floor_measurements_v1' and received->'floorMeasurementsV9'=old_details->'floorMeasurementsV9','Only two floorplan keys merge; private measurements and facts survive');
 attached:=received;
 update public.memberships set role='marketing'where user_id=f.actor and org_id=f.org;
 q:=format('select public.studio_attach_floorplan(%L,%L,%L,%L,%L,%L)',f.actor,f.org,f.listing,f.asset,attached,url);
 perform pg_temp.plan_refuses(q,'42501','Role revoked after read cannot attach');
 perform pg_temp.plan_check((select details=attached from public.listings where id=f.listing),'Revoked actor leaves listing untouched');
 -- The superseded service-PATCH implementation would have admitted this write
 -- despite the role change; retain that concrete control in the owned fixture.
 update public.listings set details=attached||'{"floorplan_asset_id":"unsafe-service-control"}'where id=f.listing and org_id=f.org and deleted_at is null and details=attached;
 perform pg_temp.plan_check(found,'Old bare service PATCH admits revoked actor control');
 update public.listings set details=attached where id=f.listing;
 update public.memberships set role='owner'where user_id=f.actor and org_id=f.org;
 perform pg_temp.plan_deletion_fixture(true);
 perform pg_temp.plan_refuses(q,'42501','Deletion started after read cannot attach');
 perform pg_temp.plan_check((select details=attached from public.listings where id=f.listing),'Deleting actor leaves listing untouched');
 perform pg_temp.plan_deletion_fixture(false);
 perform pg_temp.plan_refuses(format('select public.studio_attach_floorplan(%L,%L,%L,%L,%L,%L)',f.outsider,f.org,f.listing,f.asset,attached,url),'42501','Outsider cannot attach across workspaces');
 perform pg_temp.plan_refuses(format('select public.studio_attach_floorplan(%L,%L,%L,%L,%L,%L)',f.actor,f.org,f.foreign_listing,f.asset,attached,url),'P0002','Scoped actor cannot target foreign listing');
 perform pg_temp.plan_refuses(format('select public.studio_attach_floorplan(%L,%L,%L,%L,%L,%L)',f.actor,f.org,f.listing,f.foreign_asset,attached,url),'22023','Foreign asset cannot attach');
 foreach client in array array['incomplete','uploads','missing_mime','headshot','traversal','video']loop
  bad:=pg_temp.plan_bad_asset(client);select storage_key into bad_key from public.capture_assets where id=bad;
  perform pg_temp.plan_refuses(format('select public.studio_attach_floorplan(%L,%L,%L,%L,%L,%L)',f.actor,f.org,f.listing,bad,attached,'https://fixture.invalid/'||bad_key),'22023','Invalid asset cannot attach: '||client);
 end loop;
 perform pg_temp.plan_refuses(format('select public.studio_attach_floorplan(%L,%L,%L,%L,%L,%L)',f.actor,f.org,f.listing,f.asset,attached,'https://fixture.invalid/invented.jpg'),'22023','URL must name the verified asset key');
 perform public.save_listing_facts(f.actor,f.org,f.listing,'{}','{}','{"hours":{"present":true,"value":"office hours"}}','{"hours":"new phone hours"}');
 select to_jsonb(l)into before_row from public.listings l where id=f.listing;
 perform pg_temp.plan_refuses(q,'PT409','Phone detail edit after read conflicts atomically');
 perform pg_temp.plan_check((select to_jsonb(l)=before_row from public.listings l where id=f.listing),'Conflicted attachment preserves the complete newer row');
 select details into received from public.listings where id=f.listing;
 r:=public.studio_attach_floorplan(f.actor,f.org,f.listing,f.asset,received,url);
 perform pg_temp.plan_check(r->'details'->>'hours'='new phone hours','Retry with current snapshot preserves phone edits');
 update public.listings set deleted_at=now()where id=f.listing;
 perform pg_temp.plan_refuses(format('select public.studio_attach_floorplan(%L,%L,%L,%L,%L,%L)',f.actor,f.org,f.listing,f.asset,r->'details',url),'P0002','Deleted listing cannot attach');
end$$;
reset role;
select jsonb_build_object('passed',true,'assertions',count(*))from floorplan_checks;
rollback;
