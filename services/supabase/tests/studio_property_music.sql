-- Only the disposable CI/local PostgreSQL fixture. No external media/provider.
begin;
create temp table music_fixture(actor uuid,reviewer uuid,newcomer uuid,org uuid,listing uuid,media uuid,sha text,payload jsonb);
do $$declare a uuid:=gen_random_uuid();b uuid:=gen_random_uuid();c uuid:=gen_random_uuid();o uuid;l uuid:=gen_random_uuid();begin
 insert into auth.users(id,email,raw_user_meta_data) values(a,'music-author@fixture.invalid','{}'),(b,'music-reviewer@fixture.invalid','{}'),(c,'music-newcomer@fixture.invalid','{}');
 select org_id into strict o from public.memberships where user_id=a;
 insert into public.memberships(user_id,org_id,role) values(b,o,'agent'),(c,o,'agent');
 insert into public.listings(id,org_id,agent_id,address) values(l,o,a,'Synthetic music property');
 insert into music_fixture values(a,b,c,o,l,gen_random_uuid(),repeat('a',64),jsonb_build_object('listingId',l,'sources','[]'::jsonb,'draft',jsonb_build_object('clips','[]'::jsonb,'music',jsonb_build_object('licensed',true,'source',jsonb_build_object('sha256',repeat('a',64),'size',3)))));
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
 begin perform public.studio_production_copy(f.newcomer,f.org,f.actor,'edit:'||f.listing,1,0);raise exception 'Withdrawn snapshot issued a new copy';exception when others then if sqlerrm not like 'RP404: This version is no longer shared%' then raise;end if;end;
 if exists(select 1 from public.studio_documents where user_id=f.newcomer and org_id=f.org and key='edit:'||f.listing)
  or exists(select 1 from public.studio_property_music_copies where actor_id=f.newcomer and org_id=f.org and listing_id=f.listing) then raise exception 'Rejected copy left private content or a music grant';end if;
 -- A private new revision also ends new copies, even though history is retained.
 perform public.studio_production_review(f.actor,f.org,f.actor,'edit:'||f.listing,'submit',1,2);
 update public.studio_documents set revision=2 where user_id=f.actor and org_id=f.org and key='edit:'||f.listing;
 begin perform public.studio_production_copy(f.newcomer,f.org,f.actor,'edit:'||f.listing,1,0);raise exception 'Private new revision issued a historical copy';exception when others then if sqlerrm not like 'RP404: This version is no longer shared%' then raise;end if;end;
 perform public.studio_assert_property_music(f.org,f.listing,f.reviewer,f.payload);
 -- Author restoration is allowed; it must not silently resubmit the source.
 perform public.studio_production_copy(f.actor,f.org,f.actor,'edit:'||f.listing,1,2);
 begin perform public.studio_production_copy(f.newcomer,f.org,f.actor,'edit:'||f.listing,1,0);raise exception 'Private restored version became shared';exception when others then if sqlerrm not like 'RP404: This version is no longer shared%' then raise;end if;end;
end $$;
reset role;
do $$begin
 if has_table_privilege('anon','public.studio_property_music','select') or has_table_privilege('authenticated','public.studio_property_music','select')
  or has_table_privilege('service_role','public.studio_property_music','insert') or has_table_privilege('authenticated','public.studio_property_music_copies','select')
  or has_function_privilege('authenticated','public.studio_property_music_attach(uuid,uuid,uuid,text)','execute')
  or has_function_privilege('anon','public.studio_assert_property_music(uuid,uuid,uuid,jsonb)','execute') then raise exception 'Music sharing privilege leaked';end if;
end $$;
insert into public.deletion_requests(user_id,email,status,payload) select actor,'music-deletion@fixture.invalid','pending','{}' from music_fixture;
set local role service_role;
do $$declare f record;begin select * into f from music_fixture;
 begin perform public.studio_assert_property_music(f.org,f.listing,f.reviewer,f.payload);raise exception 'Deleting source still accessible';exception when others then if sqlerrm not like 'RP422: Music is unavailable%' then raise;end if;end;
end $$;
reset role;
delete from public.studio_project_media where id=(select media from music_fixture);
do $$begin if exists(select 1 from public.studio_property_music where listing_id=(select listing from music_fixture)) or exists(select 1 from public.studio_property_music_copies where listing_id=(select listing from music_fixture)) then raise exception 'Deleted media retained music capabilities';end if;end $$;
rollback;
select 'PASS: property music upload, attachment, privacy, review handoff, revocation and deletion invariants';
