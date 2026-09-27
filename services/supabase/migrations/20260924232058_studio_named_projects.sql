begin;
alter table public.studio_documents drop constraint if exists studio_documents_kind_check;
alter table public.studio_documents add constraint studio_documents_kind_check
  check (kind in ('edit','planner','creative','native','production','prompts','project'));
alter table public.studio_documents add constraint studio_project_key_scope
  check (kind <> 'project' or (key ~ '^project:[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
    and payload->>'schema' = '1' and jsonb_typeof(payload->'name') = 'string'
    and length(btrim(payload->>'name')) between 1 and 80 and jsonb_typeof(payload->'archived') = 'boolean'
    and payload->>'listingId' is not distinct from listing_id::text));
-- One private project list per actor/workspace; bounded creation and CAS writes
-- are atomic with current role/deletion checks. No client EXECUTE grant.
create function public.studio_save_project(p_actor uuid,p_org_id uuid,p_key text,p_listing_id uuid,p_expected integer,p_payload jsonb)
returns jsonb language plpgsql security definer set search_path=public,pg_temp as $$
declare v_doc public.studio_documents%rowtype;
begin
 if current_setting('role',true) is distinct from 'service_role' then raise insufficient_privilege using message='service role required';end if;
 if p_actor is null or p_org_id is null or p_key is null or p_key !~ '^project:[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' or p_expected is null or p_expected < 0 or p_expected >= 2147483647 then raise exception 'RP400: Choose a valid project revision'; end if;
 perform 1 from auth.users where id=p_actor for update;
 if not found then raise exception 'RP403: Account unavailable';end if;
 perform 1 from public.orgs where id=p_org_id and deleted_at is null for update;
 if not found then raise exception 'RP403: Workspace unavailable';end if;
 perform pg_advisory_xact_lock(hashtextextended(p_actor::text||':'||p_org_id::text||':projects',0));
 if not exists(select 1 from public.memberships where user_id=p_actor and org_id=p_org_id and role in ('owner','admin','agent'))
 or not exists(select 1 from public.orgs where id=p_org_id and deleted_at is null)
 or exists(select 1 from public.deletion_requests where user_id=p_actor and status <> 'completed')
 then raise exception 'RP403: This workspace cannot save projects'; end if;
 if p_listing_id is not null and not exists(select 1 from public.listings where id=p_listing_id and org_id=p_org_id and deleted_at is null) then raise exception 'RP403: This property is unavailable'; end if;
 select * into v_doc from public.studio_documents where user_id=p_actor and org_id=p_org_id and key=p_key for update;
 if found then
  if v_doc.kind <> 'project' or v_doc.revision <> p_expected or v_doc.listing_id is distinct from p_listing_id then raise exception 'RP409: This project changed on another device'; end if;
  update public.studio_documents set payload=p_payload,revision=revision+1,updated_at=now() where user_id=p_actor and org_id=p_org_id and key=p_key returning * into v_doc;
 else
  if p_expected <> 0 then raise exception 'RP409: This project changed on another device'; end if;
  if (select count(*) from public.studio_documents where user_id=p_actor and org_id=p_org_id and kind='project') >=100 then raise exception 'RP400: This workspace already has 100 saved projects'; end if;
  insert into public.studio_documents(user_id,org_id,key,kind,listing_id,payload) values(p_actor,p_org_id,p_key,'project',p_listing_id,p_payload) returning * into v_doc;
 end if;
 return jsonb_build_object('key',v_doc.key,'kind',v_doc.kind,'listing_id',v_doc.listing_id,'revision',v_doc.revision,'payload',v_doc.payload,'updated_at',v_doc.updated_at);
end $$;
revoke all on function public.studio_save_project(uuid,uuid,text,uuid,integer,jsonb) from public,anon,authenticated;
grant execute on function public.studio_save_project(uuid,uuid,text,uuid,integer,jsonb) to service_role;
-- Operational view does not need definer access for application roles.
alter view public.ai_routes_expiring set (security_invoker=true);
commit;
