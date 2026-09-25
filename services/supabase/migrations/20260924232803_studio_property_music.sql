begin;
-- An explicit attachment grants property collaborators access to one uploaded
-- licensed audio file. Account-private project media remains private otherwise.
create table public.studio_property_music (
 org_id uuid not null references public.orgs(id) on delete cascade,
 listing_id uuid not null references public.listings(id) on delete cascade,
 sha256 text not null check(sha256 ~ '^[0-9a-f]{64}$'),
 media_id uuid not null references public.studio_project_media(id) on delete cascade,
 attached_by uuid not null,
 attached_at timestamptz not null default now(),
 primary key(org_id,listing_id,sha256)
);
alter table public.studio_property_music enable row level security;
revoke all on public.studio_property_music from public,anon,authenticated,service_role;
grant select on public.studio_property_music to service_role;
create table public.studio_property_music_copies (
 actor_id uuid not null references auth.users(id) on delete cascade,
 org_id uuid not null,
 listing_id uuid not null,
 sha256 text not null,
 source_version_id uuid not null references public.studio_production_versions(id) on delete cascade,
 primary key(actor_id,org_id,listing_id,sha256),
 foreign key(org_id,listing_id,sha256) references public.studio_property_music(org_id,listing_id,sha256) on delete cascade
);
alter table public.studio_property_music_copies enable row level security;
revoke all on public.studio_property_music_copies from public,anon,authenticated,service_role;
grant select,insert on public.studio_property_music_copies to service_role;

create function public.studio_property_music_attach(p_actor uuid,p_org uuid,p_listing uuid,p_sha256 text)
returns jsonb language plpgsql security definer set search_path='' as $$
declare r public.studio_project_media%rowtype; existing public.studio_property_music%rowtype;
begin
 if current_setting('role',true) is distinct from 'service_role' then raise insufficient_privilege using message='service role required';end if;
 if p_sha256 is null or p_sha256 !~ '^[0-9a-f]{64}$' then raise exception 'RP400: Choose a saved music source';end if;
 perform 1 from auth.users where id=p_actor for update;
 if not found then raise exception 'RP403: Account unavailable';end if;
 perform 1 from public.orgs where id=p_org and deleted_at is null for update;
 if not found or exists(select 1 from public.deletion_requests where user_id=p_actor and status<>'completed')
  or not exists(select 1 from public.memberships where org_id=p_org and user_id=p_actor and role in('owner','admin','agent'))
  or not exists(select 1 from public.listings where id=p_listing and org_id=p_org and deleted_at is null) then raise exception 'RP403: This property cannot attach music';end if;
 select * into existing from public.studio_property_music where org_id=p_org and listing_id=p_listing and sha256=p_sha256;
 if found then
  if not exists(select 1 from public.studio_project_media where id=existing.media_id and actor_id=p_actor)
   and not exists(select 1 from public.studio_property_music_copies where actor_id=p_actor and org_id=p_org and listing_id=p_listing and sha256=p_sha256) then raise exception 'RP409: This music belongs to another contributor; use their authorized edit handoff';end if;
  return to_jsonb(existing);
 end if;
 select * into r from public.studio_project_media where actor_id=p_actor and org_id=p_org and sha256=p_sha256 for share;
 if not found or r.bytes>16777216 or r.mime not in('audio/mpeg','audio/mp4','audio/wav','audio/x-wav','audio/wave','audio/ogg','audio/webm') then raise exception 'RP422: Upload this music file before sharing its edit';end if;
 if exists(select 1 from generate_series(0,r.parts-1) i where r.receipts->i::text->>'state' is distinct from 'complete') then raise exception 'RP422: Music upload has not finished';end if;
 insert into public.studio_property_music(org_id,listing_id,sha256,media_id,attached_by) values(p_org,p_listing,p_sha256,r.id,p_actor) returning * into existing;
 return to_jsonb(existing);
end $$;
revoke all on function public.studio_property_music_attach(uuid,uuid,uuid,text) from public,anon,authenticated;
grant execute on function public.studio_property_music_attach(uuid,uuid,uuid,text) to service_role;

-- Keep copy/review RPCs honest even when called by another service handler.
-- Music in an immutable version must still be retrievable for this property.
create function public.studio_assert_property_music(p_org uuid,p_listing uuid,p_author uuid,p_payload jsonb)
returns void language plpgsql security definer set search_path='' as $$
declare sha text; r public.studio_project_media%rowtype;
begin
 if current_setting('role',true) is distinct from 'service_role' then raise insufficient_privilege using message='service role required';end if;
 if p_payload#>'{draft,music}' is null or p_payload#>'{draft,music}'='null'::jsonb then return;end if;
 sha:=p_payload#>>'{draft,music,source,sha256}';
 if sha is null or sha !~ '^[0-9a-f]{64}$' or p_payload#>'{draft,music,licensed}' is distinct from 'true'::jsonb then raise exception 'RP422: Confirm and save the music source before sharing this edit';end if;
 select m.* into r from public.studio_project_media m join public.studio_property_music b on b.media_id=m.id
  where b.org_id=p_org and b.listing_id=p_listing and b.sha256=sha and m.org_id=p_org and m.sha256=sha;
 if not found or r.bytes>16777216 or r.mime not in('audio/mpeg','audio/mp4','audio/wav','audio/x-wav','audio/wave','audio/ogg','audio/webm')
  or exists(select 1 from public.deletion_requests where user_id=r.actor_id and status<>'completed')
  or exists(select 1 from generate_series(0,r.parts-1) i where r.receipts->i::text->>'state' is distinct from 'complete')
  or (p_payload#>>'{draft,music,source,size}')::bigint is distinct from r.bytes::bigint then raise exception 'RP422: Music is unavailable; restore it before sharing or copying this edit';end if;
 if r.actor_id<>p_author and not exists(select 1 from public.studio_property_music_copies c join public.studio_production_versions v on v.id=c.source_version_id where c.actor_id=p_author and c.org_id=p_org and c.listing_id=p_listing and c.sha256=sha and v.org_id=p_org and v.listing_id=p_listing and v.payload#>>'{draft,music,source,sha256}'=sha and v.payload#>'{draft,music,licensed}'='true'::jsonb) then raise exception 'RP422: This music was not attached by you or handed off with this edit';end if;
end $$;
revoke all on function public.studio_assert_property_music(uuid,uuid,uuid,jsonb) from public,anon,authenticated;
grant execute on function public.studio_assert_property_music(uuid,uuid,uuid,jsonb) to service_role;

do $$
declare definition text; needle text;
begin
 definition:=pg_get_functiondef('public.studio_production_copy(uuid,uuid,uuid,text,integer,integer)'::regprocedure);
 needle:='  select * into source from public.studio_production_versions';
 if (length(definition)-length(replace(definition,needle,'')))/length(needle)<>1 then raise exception 'Production copy changed; review live sharing guard';end if;
 definition:=replace(definition,needle,$guard$  -- A submitted historical snapshot is not a perpetual invitation to make
  -- new copies. The document locks above serialize withdrawal/private editing
  -- with this grant. The original author may still restore their own history.
  if p_actor<>p_document_user_id then
    perform 1 from public.studio_production_reviews r
      join public.studio_documents d on d.user_id=r.document_user_id and d.org_id=r.org_id and d.key=r.document_key
      where r.document_user_id=p_document_user_id and r.org_id=p_org_id and r.document_key=p_key and r.listing_id=v_listing
        and r.submitted_at is not null and r.status<>'draft'
        and r.document_revision=p_document_revision and d.revision=p_document_revision
      for share of r;
    if not found then raise exception 'RP404: This version is no longer shared for copying';end if;
  end if;
$guard$||needle);
 needle:='v_payload:=source.payload;';
 if (length(definition)-length(replace(definition,needle,'')))/length(needle)<>1 then raise exception 'Production copy changed; review music handoff guard';end if;
 execute replace(definition,needle,needle||E'\n  perform public.studio_assert_property_music(p_org_id,v_listing,p_document_user_id,v_payload);\n  if v_payload#>''{draft,music}'' is not null and v_payload#>''{draft,music}''<>''null''::jsonb then\n    insert into public.studio_property_music_copies(actor_id,org_id,listing_id,sha256,source_version_id) values(p_actor,p_org_id,v_listing,v_payload#>>''{draft,music,source,sha256}'',source.id) on conflict(actor_id,org_id,listing_id,sha256) do nothing;\n  end if;');
 definition:=pg_get_functiondef('public.studio_production_review(uuid,uuid,uuid,text,text,integer,integer,text,integer)'::regprocedure);
 needle:='v_status:=case p_action when ''submit'' then ''in_review'' when ''approve'' then ''approved'' when ''request_changes'' then ''changes_requested'' when ''withdraw'' then ''draft'' else v_status end;';
 if (length(definition)-length(replace(definition,needle,'')))/length(needle)<>1 then raise exception 'Production review changed; review music submission guard';end if;
 execute replace(definition,needle,needle||E'\n  if p_action in (''submit'',''approve'') then perform public.studio_assert_property_music(p_org_id,v_listing,p_document_user_id,d.payload);end if;');
end $$;
commit;
