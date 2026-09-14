-- Isolated actual-migration regression. Every synthetic row is rolled back.
begin;
create temp table voice_fixture(n int,actor uuid,org uuid,listing uuid,reservation uuid,reserved jsonb,receipt jsonb,teammate uuid);
do $$declare a uuid; o uuid; l uuid; begin
  for n in 1..7 loop
    a:=gen_random_uuid();l:=gen_random_uuid();
    insert into auth.users(id,email,raw_user_meta_data) values(a,'reserved-voice-'||n||'@fixture.invalid','{}');
    select org_id into strict o from public.memberships where user_id=a;
    insert into public.listings(id,org_id,agent_id,address) values(l,o,a,'Synthetic reserved voice');
    insert into voice_fixture values(n,a,o,l,gen_random_uuid(),null,null,null);
  end loop;
end$$;
grant select,update on voice_fixture to service_role;
set local role service_role;
update voice_fixture set reserved=public.reserve_voice_storage(actor,org,reservation,case when n=6 then null else listing end);
-- Exact replays retain the first write deadline instead of extending it.
do $$declare f record; result jsonb;begin
  for f in select * from voice_fixture loop
    result:=public.reserve_voice_storage(f.actor,f.org,f.reservation,case when f.n=6 then null else f.listing end);
    if result<>f.reserved then raise exception 'Replay extended or changed reservation';end if;
  end loop;
end$$;
reset role;
do $$declare f record; r record;begin
  for f in select * from voice_fixture loop
    select * into strict r from public.voice_storage_reservations where id=f.reservation;
    if r.actor_id<>f.actor or r.org_id<>f.org or (f.n<>6 and r.listing_id<>f.listing) or (f.n=6 and r.listing_id is not null)
      or f.reserved->>'reservation_id'<>f.reservation::text or f.reserved->>'key'<>'ai-voice/'||f.org||'/'||f.reservation||'.mp3'
      or r.write_deadline<>r.created_at+interval '15 minutes'
      or (f.reserved->>'write_deadline')::timestamptz<>r.write_deadline
      or r.write_deadline not between clock_timestamp()+interval '14 minutes' and clock_timestamp()+interval '16 minutes'
      then raise exception 'Invalid fixed scoped storage receipt';end if;
  end loop;
  if exists(select 1 from studio_creative_results where org_id in(select org from voice_fixture)) then raise exception 'A reservation generated history or media';end if;
  if has_table_privilege('anon','public.voice_storage_reservations','select')
    or has_table_privilege('authenticated','public.voice_storage_reservations','select')
    or has_table_privilege('service_role','public.voice_storage_reservations','insert')
    or has_table_privilege('service_role','public.voice_storage_reservations','update')
    or has_table_privilege('service_role','public.voice_storage_reservations','delete')
    or has_function_privilege('anon','public.reserve_voice_storage(uuid,uuid,uuid,uuid)','execute')
    or has_function_privilege('authenticated','public.reserve_voice_storage(uuid,uuid,uuid,uuid)','execute')
    or not has_function_privilege('service_role','public.reserve_voice_storage(uuid,uuid,uuid,uuid)','execute')
    then raise exception 'Voice reservation grants permit unfenced access';end if;
  begin update public.voice_storage_reservations set storage_key='ai-voice/unverified.mp3' where id=(select reservation from voice_fixture where n=3);
    raise exception 'Invalid key accepted';exception when check_violation then null;end;
end$$;
-- Service caller cannot change a prior ID's actor, workspace or listing binding.
set local role service_role;
do $$declare a record; b record;begin
  select * into a from voice_fixture where n=1;select * into b from voice_fixture where n=3;
  begin perform public.reserve_voice_storage(b.actor,b.org,a.reservation,b.listing);
    raise exception 'Scope replay accepted';exception when others then if sqlerrm not like 'RP409: voice storage reservation belongs%' then raise;end if;end;
  begin perform public.reserve_voice_storage(a.actor,a.org,a.reservation,null);
    raise exception 'Listing replay accepted';exception when others then if sqlerrm not like 'RP409: voice storage reservation belongs%' then raise;end if;end;
  begin perform public.reserve_voice_storage(b.actor,b.org,gen_random_uuid(),a.listing);
    raise exception 'Foreign listing accepted';exception when others then if sqlerrm not like 'RP404: voice listing unavailable%' then raise;end if;end;
  begin perform public.reserve_voice_storage(gen_random_uuid(),b.org,gen_random_uuid());
    raise exception 'Missing account accepted';exception when others then if sqlerrm not like 'RP401: account no longer exists%' then raise;end if;end;
end$$;
reset role;
-- Expiry is not renewed on retry; the original target remains inventoried.
update public.voice_storage_reservations set created_at=created_at-interval '20 minutes',write_deadline=write_deadline-interval '20 minutes'
where id=(select reservation from voice_fixture where n=4);
set local role service_role;
do $$declare f record;begin select * into f from voice_fixture where n=4;
  begin perform public.reserve_voice_storage(f.actor,f.org,f.reservation,f.listing);
    raise exception 'Expired reservation renewed';exception when others then if sqlerrm not like 'RP409: voice storage reservation expired%' then raise;end if;end;
end$$;
reset role;
update public.memberships set role='marketing' where user_id=(select actor from voice_fixture where n=3);
set local role service_role;
do $$declare f record;begin select * into f from voice_fixture where n=3;
  begin perform public.reserve_voice_storage(f.actor,f.org,gen_random_uuid(),f.listing);
    raise exception 'Read-only role accepted';exception when others then if sqlerrm not like 'RP403: workspace does not permit%' then raise;end if;end;
end$$;
reset role;
update public.memberships set role='owner' where user_id=(select actor from voice_fixture where n=3);
insert into public.deletion_requests(user_id,email,status,payload) select actor,'deleting@fixture.invalid','pending','{}' from voice_fixture where n=3;
set local role service_role;
do $$declare f record;begin select * into f from voice_fixture where n=3;
  begin perform public.reserve_voice_storage(f.actor,f.org,gen_random_uuid(),f.listing);
    raise exception 'Deleting account accepted';exception when others then if sqlerrm not like 'RP409: account deletion is in progress%' then raise;end if;end;
end$$;
reset role;
delete from public.deletion_requests where user_id=(select actor from voice_fixture where n=3);
update public.orgs set deleted_at=clock_timestamp() where id=(select org from voice_fixture where n=3);
set local role service_role;
do $$declare f record;begin select * into f from voice_fixture where n=3;
  begin perform public.reserve_voice_storage(f.actor,f.org,gen_random_uuid(),f.listing);
    raise exception 'Deleted workspace accepted';exception when others then if sqlerrm not like 'RP404: voice workspace unavailable%' then raise;end if;end;
end$$;
reset role;
update public.orgs set deleted_at=null where id=(select org from voice_fixture where n=3);
update public.listings set deleted_at=clock_timestamp() where id=(select listing from voice_fixture where n=3);
set local role service_role;
do $$declare f record;begin select * into f from voice_fixture where n=3;
  begin perform public.reserve_voice_storage(f.actor,f.org,gen_random_uuid(),f.listing);
    raise exception 'Deleted listing accepted';exception when others then if sqlerrm not like 'RP404: voice listing unavailable%' then raise;end if;end;
end$$;
reset role;
update public.listings set deleted_at=null where id=(select listing from voice_fixture where n=3);
do $$begin if (select count(*) from voice_storage_reservations where org_id in(select org from voice_fixture))<>7 then raise exception 'Refused reservation left unexpected rows';end if;end$$;
-- A successful history row and its earlier reservation have one cleanup key.
insert into public.studio_creative_results(user_id,org_id,listing_id,kind,bucket,storage_key,request_key,metadata)
select actor,org,listing,'voice','uploads',reserved->>'key','reserved-fixture','{"state":"completed"}' from voice_fixture where n=7;
-- Create a shared workspace; leaving it must preserve both bytes and inventory.
do $$declare mate uuid;begin
  mate:=gen_random_uuid();insert into auth.users(id,email,raw_user_meta_data) values(mate,'voice-team-heir@fixture.invalid','{}');
  insert into memberships(user_id,org_id,role) select mate,org,'agent' from voice_fixture where n=2;
  update voice_fixture set teammate=mate where n=2;
end$$;
set local role service_role;
update voice_fixture set receipt=public.prepare_account_deletion(actor,'fixture-uploads','fixture-renders') where n in(1,2,4,6,7);
reset role;
do $$declare f record;begin
  for f in select * from voice_fixture where n in(1,4,6,7) loop
    if jsonb_array_length(f.receipt->'payload'->'r2')<>1
      or f.receipt->'payload'->'r2'->0->>'key'<>f.reserved->>'key'
      or f.receipt->'payload'->'r2'->0->>'bucket'<>'fixture-uploads'
      then raise exception 'Pending or deduplicated reserved voice key missing from leased cleanup';end if;
    if (f.receipt->'payload'->>'storage_not_before')::timestamptz is distinct from
      ((f.reserved->>'write_deadline')::timestamptz+interval '1 hour'-(case when f.n=4 then interval '20 minutes' else interval '0' end))
      then raise exception 'Deletion did not wait for original write deadline plus grace';end if;
    if exists(select 1 from voice_storage_reservations where org_id=f.org) then raise exception 'Owned reservation was not purged after inventory';end if;
  end loop;
  select * into f from voice_fixture where n=2;
  if jsonb_array_length(f.receipt->'payload'->'r2')<>0
    or not exists(select 1 from voice_storage_reservations where id=f.reservation)
    then raise exception 'Shared reservation was removed during creator deletion';end if;
end$$;
-- Auth deletion must not cascade away a shared team's cleanup receipt.
delete from auth.users where id=(select actor from voice_fixture where n=2);
do $$begin if not exists(select 1 from voice_storage_reservations where id=(select reservation from voice_fixture where n=2))
  then raise exception 'Creator Auth deletion orphaned shared audio';end if;end$$;
set local role service_role;
update voice_fixture set receipt=public.prepare_account_deletion(teammate,'fixture-uploads','fixture-renders') where n=2;
reset role;
do $$declare f record;begin select * into f from voice_fixture where n=2;
  if not exists(select 1 from jsonb_array_elements(f.receipt->'payload'->'r2') target where target->>'key'=f.reserved->>'key')
    then raise exception 'Final team owner could not clean up retained voice';end if;
end$$;
-- Invalid history still blocks the whole transaction, including reserved targets.
insert into studio_creative_results(user_id,org_id,listing_id,kind,bucket,storage_key,request_key,metadata)
select actor,org,listing,'voice','uploads','ai-voice/unverified.mp3','invalid-history','{}' from voice_fixture where n=5;
set local role service_role;
do $$declare f record;begin select * into f from voice_fixture where n=5;
  begin perform public.prepare_account_deletion(f.actor,'fixture-uploads','fixture-renders');
    raise exception 'Invalid history accepted';exception when others then if sqlerrm not like 'RP409: unverified media ownership%' then raise;end if;end;
end$$;
reset role;
do $$declare f record;begin select * into f from voice_fixture where n=5;
  if not exists(select 1 from voice_storage_reservations where id=f.reservation)
    or not exists(select 1 from listings where id=f.listing)
    or exists(select 1 from deletion_requests where user_id=f.actor)
    then raise exception 'Unverified cleanup did not roll back every related change';end if;
end$$;
rollback;
