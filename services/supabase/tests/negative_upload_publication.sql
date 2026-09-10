-- Root-owned disposable harness only. Auth/asset rows are synthetic and rolled
-- back. This fixture is authored here, NOT executed by the implementation agent.
\set ON_ERROR_STOP on
begin;
do $$ begin
  if current_database() <> 'rendprop_audit'
     or current_setting('listen_addresses') <> ''
     or current_setting('data_directory') !~ '^/tmp/rendprop-db-audit-[^/]+/cluster$' then
    raise exception 'Refusing anything except the disposable audit cluster';
  end if;
end $$;

create temp table _upload_publication_checks(name text primary key, pass boolean not null) on commit drop;
create function pg_temp.expect_upload_rejection(statement text, label text) returns void
language plpgsql as $$
declare rejected boolean := false;
begin
  begin
    execute statement;
  exception when others then
    if SQLERRM not like 'RP409:%' then raise; end if;
    rejected := true;
  end;
  if not rejected then raise exception 'Missing publication rejection: %', label; end if;
  insert into _upload_publication_checks values (label, true);
end $$;

do $$
declare
  u uuid := gen_random_uuid(); l uuid := gen_random_uuid(); o uuid;
  completed uuid := gen_random_uuid(); aborted uuid := gen_random_uuid(); multipart uuid := gen_random_uuid();
  change text; frozen jsonb := '[{"number":1,"etag":"\"AAAA\""}]'::jsonb;
begin
  insert into auth.users(id, email, raw_user_meta_data)
    values (u, 'upload-publication-fixture@example.invalid', '{}'::jsonb);
  select org_id into strict o from memberships where user_id = u and role = 'owner' limit 1;
  insert into listings(id, org_id, agent_id, address) values (l, o, u, 'Synthetic upload fixture');
  insert into capture_assets(id, listing_id, kind, storage_key, bytes, content_type, bucket)
    values (completed, l, 'photo', 'uploads/fixture/ticket.jpg', 4, 'image/jpeg', 'uploads');
  update capture_assets set uploaded = true, storage_key = 'uploads/fixture/winner.jpg' where id = completed;

  foreach change in array array[
    'uploaded = false', 'storage_key = ''uploads/fixture/replacement.jpg''',
    'bucket = ''renders''', 'kind = ''video''', 'bytes = 5', 'content_type = ''image/png''',
    'upload_aborted = true', 'completion_parts = ''[]''::jsonb',
    'id = gen_random_uuid()', 'listing_id = gen_random_uuid()', 'upload_id = ''new-session'''
  ] loop
    perform pg_temp.expect_upload_rejection(
      format('update capture_assets set %s where id = %L', change, completed), 'completed: ' || change);
  end loop;
  update capture_assets set duration_s = 2, fps = 30, width = 640, height = 480,
    codec = 'fixture', has_gyro = true where id = completed;
  if not exists (select 1 from capture_assets where id = completed and duration_s = 2 and fps = 30
                 and width = 640 and height = 480 and codec = 'fixture' and has_gyro) then
    raise exception 'Legitimate probe metadata update did not persist';
  end if;
  insert into _upload_publication_checks values ('completed metadata remains writable', true);
  insert into capture_chapters(asset_id, label, t_ms) values (completed, 'Synthetic chapter', 100);
  if not exists (select 1 from capture_chapters where asset_id = completed and t_ms = 100) then
    raise exception 'Completed asset chapter metadata did not persist';
  end if;
  insert into _upload_publication_checks values ('completed chapters remain writable', true);
  delete from capture_assets where id = completed;
  if exists (select 1 from capture_assets where id = completed) then raise exception 'Deletion was blocked'; end if;
  if exists (select 1 from capture_chapters where asset_id = completed) then raise exception 'Chapter cascade was blocked'; end if;
  insert into _upload_publication_checks values ('separate completed-asset deletion remains allowed', true);

  insert into capture_assets(id, listing_id, storage_key, bytes) values (aborted, l, 'uploads/fixture/aborted.mov', 4);
  update capture_assets set upload_aborted = true where id = aborted;
  perform pg_temp.expect_upload_rejection(format('update capture_assets set uploaded = true where id = %L', aborted), 'aborted cannot publish');
  perform pg_temp.expect_upload_rejection(format('update capture_assets set upload_aborted = false where id = %L', aborted), 'aborted cannot reopen');

  insert into capture_assets(id, listing_id, storage_key, bytes, upload_id, parts_total)
    values (multipart, l, 'uploads/fixture/multipart.mov', 4, 'synthetic-session', 1);
  perform pg_temp.expect_upload_rejection(format('update capture_assets set uploaded = true where id = %L', multipart), 'multipart must freeze before publication');
  update capture_assets set completion_parts = frozen where id = multipart;
  perform pg_temp.expect_upload_rejection(format('update capture_assets set completion_parts = ''[{"number":1,"etag":"BBBB"}]''::jsonb where id = %L', multipart), 'multipart manifest cannot change');
  update capture_assets set uploaded = true, upload_id = null where id = multipart;
  if not exists (select 1 from capture_assets where id = multipart and uploaded and completion_parts = frozen) then
    raise exception 'Frozen multipart publication did not persist';
  end if;
  insert into _upload_publication_checks values ('frozen multipart can publish', true);
end $$;

do $$ begin
  if (select count(*) from _upload_publication_checks where pass) <> 19 then
    raise exception 'Expected all 19 upload publication trigger checks';
  end if;
end $$;
rollback;
\echo 'PASS: 19 upload publication trigger checks; all synthetic mutations rolled back.'
