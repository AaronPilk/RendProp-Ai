-- Only the disposable CI/local PostgreSQL fixture. No external media/provider.
begin;
do $$begin if current_database()<>'rendprop_audit' or inet_server_addr() is not null then raise exception 'Run only in the owned socket-only rendprop_audit fixture';end if;end$$;
create temp table music_fixture(actor uuid,reviewer uuid,org uuid,listing uuid,media uuid,sha text,payload jsonb);
do $$declare a uuid:=gen_random_uuid();b uuid:=gen_random_uuid();o uuid;l uuid:=gen_random_uuid();begin
 insert into auth.users(id,email,raw_user_meta_data) values(a,'music-author@fixture.invalid','{}'),(b,'music-reviewer@fixture.invalid','{}');
 select org_id into strict o from public.memberships where user_id=a;
 insert into public.memberships(user_id,org_id,role) values(b,o,'agent');
 insert into public.listings(id,org_id,agent_id,address) values(l,o,a,'Synthetic music property');
 insert into music_fixture values(a,b,o,l,gen_random_uuid(),repeat('a',64),jsonb_build_object('listingId',l,'sources','[]'::jsonb,'draft',jsonb_build_object('clips','[]'::jsonb,'music',jsonb_build_object('licensed',true,'source',jsonb_build_object('sha256',repeat('a',64),'size',3)))));
end $$;
grant select on music_fixture to service_role;
set local role service_role;
do $$declare f record;r jsonb;begin
 select * into f from music_fixture;
 perform public.studio_project_media_write(f.actor,f.org,f.media,'reserve',jsonb_build_object('sha256',f.sha,'bytes',3,'mime','audio/mpeg','filename','fixture.mp3','modified',0));
 begin perform public.studio_property_music_attach(f.actor,f.org,f.listing,f.sha);raise exception 'Incomplete music attached';exception when others then if sqlerrm not like 'RP422: Music upload has not finished%' then raise;end if;end;
 perform public.studio_project_media_write(f.actor,f.org,f.media,'claim',jsonb_build_object('sha256',f.sha,'bytes',3,'part',0));
 perform public.studio_project_media_write(f.actor,f.org,f.media,'finish',jsonb_build_object('sha256',f.sha,'bytes',3,'part',0));
 r:=public.studio_property_music_attach(f.actor,f.org,f.listing,f.sha);
 if r->>'media_id'<>f.media::text then raise exception 'Attached wrong original';end if;
 if public.studio_property_music_attach(f.actor,f.org,f.listing,f.sha)<>r then raise exception 'Attachment replay changed';end if;
 begin perform public.studio_property_music_attach(f.reviewer,f.org,f.listing,f.sha);raise exception 'Guessed hash attached another account music';exception when others then if sqlerrm not like 'RP409: This music belongs to another contributor%' then raise;end if;end;
 perform public.studio_assert_property_music(f.org,f.listing,f.actor,f.payload);
 begin perform public.studio_assert_property_music(f.org,f.listing,f.reviewer,f.payload);raise exception 'Guessed hash authorized shared review';exception when others then if sqlerrm not like 'RP422: This music was not attached by you%' then raise;end if;end;
 begin perform public.studio_assert_property_music(f.org,f.listing,f.actor,jsonb_set(f.payload,'{draft,music,source,size}','4'));raise exception 'Incorrect music size accepted';exception when others then if sqlerrm not like 'RP422: Music is unavailable%' then raise;end if;end;
 insert into public.studio_documents(user_id,org_id,key,kind,listing_id,revision,payload) values(f.actor,f.org,'edit:'||f.listing,'edit',f.listing,1,f.payload);
 perform public.studio_production_review(f.actor,f.org,f.actor,'edit:'||f.listing,'submit',1,0);
 r:=public.studio_production_copy(f.reviewer,f.org,f.actor,'edit:'||f.listing,1,0);
 if r#>>'{document,payload,draft,music,source,sha256}'<>f.sha then raise exception 'Handoff lost music';end if;
 if not exists(select 1 from public.studio_property_music_copies where actor_id=f.reviewer and org_id=f.org and listing_id=f.listing and sha256=f.sha) then raise exception 'Handoff has no private grant';end if;
 perform public.studio_assert_property_music(f.org,f.listing,f.reviewer,f.payload);
 -- Withdrawal ends new review access; an explicit completed copy remains its own snapshot.
 perform public.studio_production_review(f.actor,f.org,f.actor,'edit:'||f.listing,'withdraw',1,1);
 perform public.studio_assert_property_music(f.org,f.listing,f.reviewer,f.payload);
end $$;
reset role;
create temp table new_recipient(id uuid);
insert into new_recipient values(gen_random_uuid());
insert into auth.users(id,email) select id,'new-recipient@fixture.invalid' from new_recipient;
insert into public.memberships(user_id,org_id,role) select n.id,f.org,'agent' from new_recipient n,music_fixture f;
grant select on new_recipient to service_role;
set local role service_role;
do $$declare f record;c uuid;r jsonb;begin select * into f from music_fixture;select id into c from new_recipient;
 if (select status from studio_production_reviews where document_user_id=f.actor and org_id=f.org and document_key='edit:'||f.listing)<>'draft' then raise exception 'Fixture did not withdraw';end if;
 begin
  r:=studio_production_copy(c,f.org,f.actor,'edit:'||f.listing,1,0);
  raise exception 'FAIL: fresh copy after withdrawal was admitted';
 exception when others then if sqlerrm not like 'RP404:%' then raise;end if;end;
 if exists(select 1 from studio_property_music_copies where actor_id=c) or exists(select 1 from studio_documents where user_id=c and org_id=f.org) then raise exception 'FAIL: rejected copy leaked grant or draft';end if;
 perform studio_production_review(f.actor,f.org,f.actor,'edit:'||f.listing,'submit',1,2);
 update studio_documents set revision=2,payload=payload||'{"private_note":"new unsubmitted edit"}'::jsonb where user_id=f.actor and org_id=f.org and key='edit:'||f.listing;
 begin
  perform studio_production_copy(c,f.org,f.actor,'edit:'||f.listing,1,0);
  raise exception 'FAIL: a new private source revision admitted fresh copy';
 exception when others then if sqlerrm not like 'RP404:%' then raise;end if;end;
 if exists(select 1 from studio_property_music_copies where actor_id=c) or exists(select 1 from studio_documents where user_id=c and org_id=f.org) then raise exception 'FAIL: private edit rejection leaked grant or draft';end if;
 r:=studio_production_copy(f.actor,f.org,f.actor,'edit:'||f.listing,1,2);
 if (r#>>'{document,revision}')::int<>3 then raise exception 'FAIL: author cannot restore own historical version';end if;
 raise notice 'PASS: withdrawal/private edits block fresh recipients; existing copy and author restore remain valid';
end $$;
reset role;
create temp table original_grant(version_id uuid);
insert into original_grant select source_version_id from studio_property_music_copies where actor_id=(select reviewer from music_fixture);
insert into studio_production_versions(document_user_id,org_id,document_key,listing_id,document_revision,reason,payload)
 select actor,org,'edit:'||listing,listing,99,'before_replace',jsonb_set(payload,'{draft,music,source,sha256}',to_jsonb(repeat('f',64))) from music_fixture;
update studio_property_music_copies set source_version_id=(select id from studio_production_versions where document_user_id=(select actor from music_fixture) and document_revision=99) where actor_id=(select reviewer from music_fixture);
set local role service_role;
do $$declare f record;begin select * into f from music_fixture;
 begin perform studio_assert_property_music(f.org,f.listing,f.reviewer,f.payload);raise exception 'FAIL: mismatching immutable source version authorized music';exception when others then if sqlerrm not like 'RP422:%' then raise;end if;end;
 raise notice 'PASS: a valid foreign key to the wrong immutable SHA cannot authorize music';
end$$;
rollback;
