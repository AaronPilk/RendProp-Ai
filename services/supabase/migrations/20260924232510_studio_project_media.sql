begin;
-- Private originals for named Studio projects. Objects are immutable bounded
-- chunks; reservations enumerate every possible key before any storage write.
create table public.studio_project_media (
 id uuid primary key,
 actor_id uuid not null,
 org_id uuid not null references public.orgs(id) on delete cascade,
 sha256 text not null check(sha256 ~ '^[0-9a-f]{64}$'),
 bytes integer not null check(bytes between 1 and 134217728),
 mime text not null check(mime in('image/jpeg','image/png','image/webp','video/mp4','video/quicktime','video/webm','audio/mpeg','audio/mp4','audio/wav','audio/x-wav','audio/wave','audio/ogg','audio/webm')),
 filename text not null check(length(filename) between 1 and 255),
 modified bigint not null check(modified>=0),
 parts integer generated always as ((bytes+8388607)/8388608) stored,
 receipts jsonb not null default '{}' check(jsonb_typeof(receipts)='object' and octet_length(receipts::text)<=16384),
 created_at timestamptz not null default now(),
 write_deadline timestamptz not null default now()+interval '30 minutes',
 unique(actor_id,org_id,sha256)
);
create index studio_project_media_org on public.studio_project_media(org_id,actor_id);
alter table public.studio_project_media enable row level security;
revoke all on public.studio_project_media from public,anon,authenticated,service_role;
grant select on public.studio_project_media to service_role;

create function public.studio_project_media_write(p_actor uuid,p_org uuid,p_id uuid,p_action text,p_data jsonb)
returns jsonb language plpgsql security definer set search_path='' as $$
declare r public.studio_project_media%rowtype; part integer; receipt jsonb; expected integer; attempts integer;
begin
 if current_setting('role',true) is distinct from 'service_role' then raise insufficient_privilege using message='service role required';end if;
 if p_actor is null or p_org is null or p_id is null or p_action is null or p_action not in('reserve','read','inspect','claim','finish') then raise exception 'RP400: Invalid media action';end if;
 perform 1 from auth.users where id=p_actor for update;
 if not found then raise exception 'RP403: Account unavailable';end if;
 perform 1 from public.orgs where id=p_org and deleted_at is null for update;
 if not found or exists(select 1 from public.deletion_requests where user_id=p_actor and status<>'completed') or not exists(select 1 from public.memberships where user_id=p_actor and org_id=p_org and (p_action='read' or role in('owner','admin','agent'))) then raise exception 'RP403: Workspace cannot access media';end if;
 if p_action='reserve' then
  select * into r from public.studio_project_media where actor_id=p_actor and org_id=p_org and sha256=p_data->>'sha256' for update;
  if found then
   if r.bytes<>(p_data->>'bytes')::integer or r.mime<>p_data->>'mime' then raise exception 'RP409: This original has different metadata';end if;
   if r.write_deadline<=clock_timestamp() then update public.studio_project_media set write_deadline=clock_timestamp()+interval '30 minutes' where id=r.id returning * into r;end if;
   return to_jsonb(r);
  end if;
  if (select coalesce(sum(bytes),0) from public.studio_project_media where org_id=p_org)+(p_data->>'bytes')::bigint>536870912 then raise exception 'RP400: Project media storage has reached 512 MiB in this workspace';end if;
  insert into public.studio_project_media(id,actor_id,org_id,sha256,bytes,mime,filename,modified)
   values(p_id,p_actor,p_org,p_data->>'sha256',(p_data->>'bytes')::integer,p_data->>'mime',p_data->>'filename',(p_data->>'modified')::bigint) returning * into r;
  return to_jsonb(r);
 end if;
 select * into r from public.studio_project_media where id=p_id and actor_id=p_actor and org_id=p_org for update;
 if not found then raise exception 'RP404: Original media unavailable';end if;
 if p_action='read' then return to_jsonb(r);end if;
 if r.write_deadline<=clock_timestamp() then raise exception 'RP409: This media upload expired; its existing data is preserved';end if;
 part:=(p_data->>'part')::integer;
 if part is null or part<0 or part>=r.parts or p_data->>'sha256' is null or p_data->>'sha256' !~ '^[0-9a-f]{64}$' then raise exception 'RP400: Invalid upload part';end if;
 expected:=least(8388608,r.bytes-part*8388608);
 if (p_data->>'bytes')::integer is distinct from expected then raise exception 'RP400: Upload part has the wrong size';end if;
 receipt:=r.receipts->part::text;
 if receipt is not null and (receipt->>'sha256'<>p_data->>'sha256' or (receipt->>'bytes')::integer<>expected) then raise exception 'RP409: This upload part belongs to different bytes';end if;
 attempts:=coalesce((receipt->>'attempts')::integer,0);
 -- A verification-only read remains possible after the dispatch retry limit.
 -- The edge function can confirm an immutable object already written by a
 -- recorded attempt, without admitting another storage write.
 if p_action='inspect' then return jsonb_build_object('dispatch',false,'media',to_jsonb(r));end if;
 if p_action='claim' then
  if receipt->>'state'='complete' then return jsonb_build_object('dispatch',false,'media',to_jsonb(r));end if;
  if attempts>=3 then raise exception 'RP409: Upload retry limit reached; existing data is preserved';end if;
  receipt:=jsonb_build_object('sha256',p_data->>'sha256','bytes',expected,'state','claimed','attempts',attempts+1);
 else
  if receipt is null then raise exception 'RP409: Upload part has no recorded attempt';end if;
  receipt:=receipt||jsonb_build_object('state','complete');
 end if;
 update public.studio_project_media set receipts=jsonb_set(receipts,array[part::text],receipt) where id=r.id returning * into r;
 return jsonb_build_object('dispatch',p_action='claim','media',to_jsonb(r));
end $$;
revoke all on function public.studio_project_media_write(uuid,uuid,uuid,text,jsonb) from public,anon,authenticated;
grant execute on function public.studio_project_media_write(uuid,uuid,uuid,text,jsonb) to service_role;

create function public.studio_project_deletion_targets(p_actor uuid,p_solo uuid[],p_bucket text)
returns jsonb language plpgsql security definer set search_path='' as $$
declare targets jsonb;
begin
 if current_setting('role',true) is distinct from 'service_role' then raise insufficient_privilege using message='service role required';end if;
 perform 1 from public.studio_project_media where actor_id=p_actor or org_id=any(p_solo) order by id for update;
 select coalesce(jsonb_agg(jsonb_build_object('bucket',p_bucket,'key','studio-project/'||m.org_id||'/'||m.actor_id||'/'||m.id||'/'||part::text,'valid',true)),'[]'::jsonb) into targets
 from public.studio_project_media m cross join lateral generate_series(0,m.parts-1) part where m.actor_id=p_actor or m.org_id=any(p_solo);
 return targets;
end $$;
revoke all on function public.studio_project_deletion_targets(uuid,uuid[],text) from public,anon,authenticated,service_role;
-- Extend the existing durable deletion snapshot, with guards against drift.
do $$
declare definition text;
 needle text:='object_targets:=object_targets||spatial_keys||public.studio_voice_deletion_targets(solo,p_upload_bucket);';
 cleanup text:='delete from public.orgs where id=any(solo);';
begin
 definition:=pg_get_functiondef('public.prepare_account_deletion(uuid,text,text)'::regprocedure);
 if (length(definition)-length(replace(definition,needle,'')))/length(needle)<>1 or (length(definition)-length(replace(definition,cleanup,'')))/length(cleanup)<>1 then raise exception 'Deletion inventory changed; review before adding project originals';end if;
 definition:=replace(definition,needle,needle||E'\n  object_targets:=object_targets||public.studio_project_deletion_targets(p_user,solo,p_upload_bucket);\n  select greatest(storage_after,max(write_deadline)+interval ''1 hour'') into storage_after from public.studio_project_media where actor_id=p_user or org_id=any(solo);');
 definition:=replace(definition,cleanup,E'delete from public.studio_project_media where actor_id=p_user;\n  '||cleanup);
 execute definition;
end $$;
commit;
