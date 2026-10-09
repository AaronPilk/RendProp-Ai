begin;
-- Team seats fund private listing libraries. They are no longer shared-content
-- memberships. Historical org/listing/storage/subscription identifiers stay put.
create table if not exists public.team_private_libraries(
 id uuid primary key default gen_random_uuid(),
 team_org_id uuid not null references public.orgs(id) on delete cascade,
 team_owner_user_id uuid not null references public.profiles(id) on delete cascade,
 agent_user_id uuid not null references public.profiles(id) on delete cascade,
 private_org_id uuid not null references public.orgs(id) on delete cascade,
 accepted_invite_id uuid not null references public.org_invites(id),
 starts_at timestamptz not null default now(),revoked_at timestamptz,
 check(team_org_id<>private_org_id and team_owner_user_id<>agent_user_id)
);
create unique index if not exists team_private_library_live_agent on public.team_private_libraries(agent_user_id) where revoked_at is null;
create unique index if not exists team_private_library_live_org on public.team_private_libraries(private_org_id) where revoked_at is null;
create index if not exists team_private_library_owner on public.team_private_libraries(team_org_id,team_owner_user_id) where revoked_at is null;
alter table public.team_private_libraries enable row level security;
revoke all on public.team_private_libraries from public,anon,authenticated;
grant select,insert,update,delete on public.team_private_libraries to service_role;

-- Stored Team plans, private-org owner roles and product-admin status are not
-- delegation. The host must currently have exactly one named Team owner.
create or replace function public.team_library_owner(p_org uuid) returns uuid
language sql stable security definer set search_path='' as $$
 select min(m.user_id::text)::uuid from public.memberships m
 join public.orgs o on o.id=m.org_id and o.deleted_at is null
 join auth.users u on u.id=m.user_id and not u.is_anonymous
 where m.org_id=p_org and m.role='owner'
 and public.effective_plan(p_org)='team'
 and not exists(select 1 from public.team_private_libraries b where b.private_org_id=p_org and b.revoked_at is null)
 and not exists(select 1 from public.private_internal_testing_sponsorships s where s.private_org_id=p_org and s.revoked_at is null)
 and not exists(select 1 from public.deletion_requests d where d.user_id=m.user_id and d.status in('pending','processing'))
 having count(*)=1 and (select count(*) from public.memberships x where x.org_id=p_org and x.role='owner')=1;
$$;
-- Structural relation validity is separate from current paid benefits. This
-- retains historical accounting attribution after cancellation/removal.
create or replace function public.team_library_binding_valid(p_id uuid) returns boolean
language sql stable security definer set search_path='' as $$
 select exists(select 1 from public.team_private_libraries b
 join public.orgs t on t.id=b.team_org_id and t.deleted_at is null
 join public.orgs o on o.id=b.private_org_id and o.deleted_at is null
 join public.memberships a on a.org_id=b.private_org_id and a.user_id=b.agent_user_id and a.role='owner'
 join public.memberships seat on seat.org_id=b.team_org_id and seat.user_id=b.agent_user_id and seat.role in('agent','admin','marketing')
 join public.org_invites i on i.id=b.accepted_invite_id and i.org_id=b.team_org_id and i.accepted_by=b.agent_user_id
  and i.accepted_at is not null and i.invited_by=b.team_owner_user_id and not i.private_testing
 join auth.users u on u.id=b.agent_user_id and not u.is_anonymous
 where b.id=p_id and b.revoked_at is null and b.starts_at<=now()
 and public.team_library_owner(b.team_org_id)=b.team_owner_user_id
 and (select count(*) from public.memberships x where x.org_id=b.private_org_id)=1
 and not exists(select 1 from public.deletion_requests d where d.user_id=b.agent_user_id and d.status in('pending','processing'))
 and not exists(select 1 from public.private_internal_testing_sponsorships s where s.private_org_id=b.private_org_id and s.revoked_at is null));
$$;
create or replace function public.library_billing_org(p_org uuid) returns uuid
language sql stable security definer set search_path='' as $$
 select coalesce((select b.team_org_id from public.team_private_libraries b where b.private_org_id=p_org
  and public.team_library_binding_valid(b.id) limit 1),p_org);
$$;
create or replace function public.private_team_content_binding_valid(p_id uuid)returns boolean
language sql stable security definer set search_path='' as $$
 select exists(select 1 from public.private_internal_testing_sponsorships s
 join public.orgs o on o.id=s.private_org_id and o.deleted_at is null
 join public.memberships m on m.org_id=s.private_org_id and m.user_id=s.beneficiary_user_id and m.role='owner'
 join auth.users u on u.id=s.beneficiary_user_id and not u.is_anonymous
 where s.id=p_id and s.revoked_at is null and s.starts_at<=now()and(s.expires_at is null or s.expires_at>now())
 and public.private_internal_testing_master_owner(s.sponsor_org_id)=s.sponsor_owner_user_id
 and public.team_library_owner(s.sponsor_org_id)=s.sponsor_owner_user_id
 and not exists(select 1 from public.memberships x where x.org_id=s.private_org_id and x.user_id<>s.beneficiary_user_id)
 and not exists(select 1 from public.memberships x where x.org_id=s.sponsor_org_id and x.user_id=s.beneficiary_user_id)
 and not exists(select 1 from public.org_invites i where i.org_id=s.private_org_id and i.accepted_at is null and i.revoked_at is null and i.expires_at>now())
 and not exists(select 1 from public.brokerage_contracts c where c.org_id=s.private_org_id and c.status='active'and c.starts_at<=now()and(c.ends_at is null or c.ends_at>now()))
 and not exists(select 1 from public.deletion_requests d where d.user_id=s.beneficiary_user_id and d.status in('pending','processing')));
$$;
revoke all on function public.private_team_content_binding_valid(uuid)from public,anon,authenticated;
grant execute on function public.private_team_content_binding_valid(uuid)to service_role,postgres;
-- A live internal testing seat is an explicit owner-content grant, but its
-- existing unlimited child funding is deliberately NOT projected to the host.
create or replace function public.library_team_owner(p_org uuid) returns uuid
language sql stable security definer set search_path='' as $$
 select coalesce((select b.team_owner_user_id from public.team_private_libraries b where b.private_org_id=p_org
  and public.team_library_binding_valid(b.id) limit 1),
 (select s.sponsor_owner_user_id from public.private_internal_testing_sponsorships s where s.private_org_id=p_org
  and public.private_team_content_binding_valid(s.id)
  and public.team_library_owner(s.sponsor_org_id)=s.sponsor_owner_user_id
  and s.revoked_at is null limit 1));
$$;
create or replace function public.library_team_org(p_org uuid) returns uuid
language sql stable security definer set search_path='' as $$
 select coalesce((select b.team_org_id from public.team_private_libraries b where b.private_org_id=p_org
  and public.team_library_binding_valid(b.id) limit 1),
 (select s.sponsor_org_id from public.private_internal_testing_sponsorships s where s.private_org_id=p_org
  and public.private_team_content_binding_valid(s.id)and public.team_library_owner(s.sponsor_org_id)=s.sponsor_owner_user_id
  and s.revoked_at is null limit 1));
$$;
create or replace function public.library_content_access(p_actor uuid,p_org uuid,p_write boolean default false) returns boolean
language sql stable security definer set search_path='' as $$
 select p_actor is not null and exists(select 1 from public.orgs o where o.id=p_org and o.deleted_at is null)
 and not exists(select 1 from public.deletion_requests d where d.user_id=p_actor and d.status in('pending','processing'))
 and (coalesce(public.library_team_owner(p_org)=p_actor,false)or exists(select 1 from public.memberships m where m.user_id=p_actor and m.org_id=p_org
   and (not p_write or m.role in('owner','admin','agent'))
   -- A seat in someone else's Team is roster membership, not shared access.
   and (m.role='owner'and(select count(*)from public.memberships x where x.org_id=p_org and x.role='owner')=1 or not exists(select 1 from public.orgs t where t.id=p_org and t.plan='team')
     and not exists(select 1 from public.org_invites i where i.org_id=p_org and i.accepted_by=p_actor and i.accepted_at is not null))));
$$;
create or replace function public.library_access(p_actor uuid,p_org uuid) returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare own uuid;r text;b uuid;t uuid;delegated boolean;
begin
 if current_setting('role',true) not in('service_role','postgres','supabase_admin') and not(current_setting('role',true)='none'and session_user in('postgres','supabase_admin'))then raise insufficient_privilege;end if;
 if not public.library_content_access(p_actor,p_org,false) then raise exception 'RP403: This listing library is not available to this account';end if;
 select user_id into own from public.memberships where org_id=p_org and role='owner' order by user_id limit 1;
 delegated:=public.library_team_owner(p_org)=p_actor and own<>p_actor;
 select role into r from public.memberships where org_id=p_org and user_id=p_actor;
 b:=public.library_billing_org(p_org);t:=public.library_team_org(p_org);
 return jsonb_build_object('actor_id',p_actor,'org_id',p_org,'library_owner_user_id',own,'role',case when delegated then 'team_owner'else r end,
 'access_mode',case when delegated then 'team_owner'else 'own'end,'can_read',true,'can_write',public.library_content_access(p_actor,p_org,true),
 'can_manage_subscription',not delegated and own=p_actor and b=p_org and t is null,'billing_org_id',b,'team_org_id',t);
end$$;
create or replace function public.agent_private_library(p_actor uuid)returns uuid
language sql stable security definer set search_path='' as $$
 select coalesce((select b.private_org_id from public.team_private_libraries b where b.agent_user_id=p_actor
 and exists(select 1 from public.memberships m join public.orgs o on o.id=m.org_id and o.deleted_at is null where m.org_id=b.private_org_id and m.user_id=p_actor and m.role='owner')order by (b.revoked_at is null)desc,b.starts_at desc,b.id limit 1),
 (select s.private_org_id from public.private_internal_testing_sponsorships s where s.beneficiary_user_id=p_actor and s.revoked_at is null limit 1),
 (select min(m.org_id::text)::uuid from public.memberships m join public.orgs o on o.id=m.org_id and o.deleted_at is null
 where m.user_id=p_actor and m.role='owner' having count(*)=1));
$$;
create or replace function public.listing_owner_library(p_listing uuid)returns uuid
language sql stable security definer set search_path='' as $$
 select case when exists(select 1 from public.org_invites i where i.org_id=l.org_id and i.accepted_by=l.agent_id and i.accepted_at is not null)
 then public.agent_private_library(l.agent_id)else l.org_id end from public.listings l where l.id=p_listing and l.deleted_at is null;
$$;
revoke all on function public.listing_owner_library(uuid)from public,anon,authenticated;
grant execute on function public.listing_owner_library(uuid)to service_role,postgres;
create or replace function public.listing_content_access(p_actor uuid,p_listing uuid,p_write boolean default false)returns boolean
language sql stable security definer set search_path='' as $$
 select coalesce(public.library_content_access(p_actor,public.listing_owner_library(p_listing),p_write),false);
$$;
create or replace function public.listing_library_scope(p_actor uuid,p_listing uuid)returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare l public.listings;library uuid;owner_id uuid;a jsonb;
begin
 if current_setting('role',true)not in('service_role','postgres','supabase_admin')and not(current_setting('role',true)='none'and session_user in('postgres','supabase_admin'))then raise insufficient_privilege;end if;
 select * into l from public.listings where id=p_listing and deleted_at is null;
 if l.id is null then raise exception 'RP404: Listing not found';end if;
 if not public.listing_content_access(p_actor,p_listing,false)then raise exception 'RP403: This listing is not available to this account';end if;
 library:=public.listing_owner_library(l.id);
 a:=public.library_access(p_actor,library);
 return a||jsonb_build_object('actor_id',p_actor,'org_id',l.org_id,'library_org_id',library,'listing_id',l.id,'listing_owner_user_id',l.agent_id,
  'can_write',public.listing_content_access(p_actor,p_listing,true),'billing_org_id',public.library_billing_org(library));
end$$;
create or replace function public.list_library_listings(p_actor uuid,p_org uuid,p_limit integer default 500,p_offset integer default 0)returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare a jsonb;rows jsonb;total integer;begin
 a:=public.library_access(p_actor,p_org);
 if p_limit is null or p_limit not between 1 and 500 or p_offset is null or p_offset<0 then raise exception 'RP400: Invalid listing page';end if;
 select count(*)into total from public.listings l where l.deleted_at is null and public.listing_owner_library(l.id)=p_org and public.listing_content_access(p_actor,l.id,false);
 select coalesce(jsonb_agg(to_jsonb(x)||jsonb_build_object('library_org_id',p_org)order by x.created_at desc,x.id),'[]'::jsonb)into rows
 from(select l.*from public.listings l where l.deleted_at is null and public.listing_owner_library(l.id)=p_org and public.listing_content_access(p_actor,l.id,false)
 order by l.created_at desc,l.id limit p_limit offset p_offset)x;
 return jsonb_build_object('actor_id',p_actor,'org_id',p_org,'listings',rows,'total',total,'next_offset',case when p_offset+p_limit<total then p_offset+p_limit else null end);
end$$;



create or replace function public.revoke_removed_team_library()returns trigger language plpgsql security definer set search_path='' as $$begin
 if tg_op='DELETE'or new.org_id is distinct from old.org_id or new.user_id is distinct from old.user_id then
  update public.team_private_libraries set revoked_at=coalesce(revoked_at,clock_timestamp())where team_org_id=old.org_id and agent_user_id=old.user_id and revoked_at is null;
 end if;
 if tg_op='DELETE'then return old;end if;return new;
end$$;
revoke all on function public.revoke_removed_team_library()from public,anon,authenticated;
drop trigger if exists team_library_seat_removed on public.memberships;
create trigger team_library_seat_removed after delete or update on public.memberships for each row execute function public.revoke_removed_team_library();

-- Exact listing identity extends private libraries to the existing inquiry inbox.
create or replace function public.library_listing_ids(p_actor uuid,p_org uuid)returns uuid[]
language plpgsql stable security definer set search_path='' as $$begin
 perform public.library_access(p_actor,p_org);
 return coalesce((select array_agg(l.id order by l.id)from public.listings l where public.listing_owner_library(l.id)=p_org and public.listing_content_access(p_actor,l.id,false)),'{}'::uuid[]);
end$$;
create or replace function public.lead_library_scope(p_actor uuid,p_lead uuid)returns jsonb
language plpgsql stable security definer set search_path='' as $$declare l public.leads;a jsonb;begin
 select *into l from public.leads where id=p_lead;
 if l.id is null then raise exception 'RP404: Inquiry not found';end if;
 a:=public.listing_library_scope(p_actor,l.listing_id);
 if (a->>'org_id')::uuid is distinct from l.org_id then raise exception 'RP403: Inquiry is not available';end if;
 return a||jsonb_build_object('actor_id',p_actor,'lead_id',l.id,'listing_id',l.listing_id,'org_id',l.org_id,'library_org_id',a->'library_org_id');
end$$;
create or replace function public.list_library_leads(p_actor uuid,p_org uuid,p_limit integer default 100,p_since timestamptz default null,p_status text default null,p_listing uuid default null)returns jsonb
language plpgsql stable security definer set search_path='' as $$declare r jsonb;begin
 perform public.library_access(p_actor,p_org);
 if p_limit is null or p_limit not between 1 and 500 or(p_status is not null and p_status not in('new','contacted','won','lost'))then raise exception 'RP400: Invalid inquiry page';end if;
 select coalesce(jsonb_agg(x.row order by x.created_at desc,x.id),'[]'::jsonb)into r from(
 select to_jsonb(l)||jsonb_build_object('library_org_id',p_org,'listings',jsonb_build_object('address',q.address,'space_type',q.space_type))as row,l.created_at,l.id
 from public.leads l join public.listings q on q.id=l.listing_id and q.org_id=l.org_id
 where public.listing_owner_library(q.id)=p_org and public.listing_content_access(p_actor,q.id,false)
 and(p_since is null or l.created_at>=p_since)and(p_status is null or l.status=p_status)and(p_listing is null or l.listing_id=p_listing)
 order by l.created_at desc,l.id limit p_limit)x;return r;
end$$;
revoke all on function public.library_listing_ids(uuid,uuid),public.lead_library_scope(uuid,uuid),public.list_library_leads(uuid,uuid,integer,timestamptz,text,uuid)from public,anon,authenticated;
grant execute on function public.library_listing_ids(uuid,uuid),public.lead_library_scope(uuid,uuid),public.list_library_leads(uuid,uuid,integer,timestamptz,text,uuid)to service_role,postgres;

do $$begin if(select md5(prosrc)from pg_proc where oid='public.set_lead_status(uuid,text)'::regprocedure)not in('6d1a62fbd31b185cbe8ad36eb7015426','22b1983390c8b51d3fa1b023fcc6e28d')then raise exception 'Review changed function set_lead_status';end if;end$$;
CREATE OR REPLACE FUNCTION public.set_lead_status(p_lead uuid, p_status text)
 RETURNS leads
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_lead leads;
  v_role text;
begin
  if p_status is null or p_status not in ('new','contacted','won','lost') then
    raise exception 'RP400: status must be new, contacted, won, or lost';
  end if;
  select l.* into v_lead from leads l where l.id = p_lead;
  if not found or v_lead.org_id is null then raise exception 'RP404: lead not found'; end if;

  v_role := case when public.listing_content_access(auth.uid(),v_lead.listing_id,true)then 'agent'else null end;
  if v_role is null then raise exception 'RP404: lead not found'; end if;  -- don't reveal existence
  if v_role not in ('owner','admin','agent') then
    raise exception 'RP403: your role does not permit updating leads';
  end if;

  update leads set status = p_status where id = p_lead returning * into v_lead;
  return v_lead;
end;
$function$
;

do $$begin if(select md5(prosrc)from pg_proc where oid='public.client_lead_delivery_list(uuid,uuid,uuid[])'::regprocedure)not in('edd0cf1aaebef5ed20caa7d578bb7717','f9c81658d33f81cd0f911c54446ca7f2')then raise exception 'Review changed function client_lead_delivery_list';end if;end$$;
CREATE OR REPLACE FUNCTION public.client_lead_delivery_list(p_user uuid, p_org uuid, p_leads uuid[])
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare result jsonb:='{}';item uuid;summary jsonb;v_role text;
begin
 if current_setting('role',true)is distinct from 'service_role'then raise insufficient_privilege using message='service role required';end if;
 if cardinality(p_leads)>500 then raise exception 'RP400: too many leads';end if;
 if not exists(select 1 from public.profiles where id=p_user)then raise exception 'RP401: session no longer exists';end if;
 if exists(select 1 from public.deletion_requests where user_id=p_user and status in('pending','processing'))then raise exception 'RP409: this account is being deleted';end if;
 v_role:=public.library_scope_role(p_user,p_org);
 if v_role is null then raise exception 'RP403: workspace is unavailable';end if;
 foreach item in array coalesce(p_leads,'{}')loop
  if exists(select 1 from public.leads l where id=item and public.listing_owner_library(l.listing_id)=p_org and public.listing_content_access(p_user,l.listing_id,false))then
   summary:=public.client_delivery_summary(item);
   if summary is not null and v_role not in('owner','admin','agent')then summary:=summary||jsonb_build_object('can_resend',false);end if;
   result:=result||jsonb_build_object(item::text,summary);
  end if;
 end loop;return result;
end$function$
;

do $$begin if(select md5(prosrc)from pg_proc where oid='public.delete_workspace_lead(uuid,uuid,uuid)'::regprocedure)not in('ebb3984dfb09340d91512cdcee6b4398','b7f38e52d81b3bf56a0d623b90c4460c')then raise exception 'Review changed function delete_workspace_lead';end if;end$$;
CREATE OR REPLACE FUNCTION public.delete_workspace_lead(p_user uuid, p_org uuid, p_lead uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare lead public.leads;payload jsonb;pending boolean:=false;
begin
 if current_setting('role',true)is distinct from 'service_role'then raise insufficient_privilege using message='service role required';end if;
 perform 1 from public.profiles where id=p_user for update;
 perform 1 from public.orgs where id=p_org and deleted_at is null for update;
 if not found or not exists(select 1 from auth.users where id=p_user and not is_anonymous)
  or not exists(select 1 from public.leads l where l.id=p_lead and l.org_id=p_org and public.listing_content_access(p_user,l.listing_id,true))
  or exists(select 1 from public.deletion_requests where user_id=p_user and status in('pending','processing'))then raise exception 'RP403: this workspace does not permit deleting inquiries';end if;
 select * into lead from public.leads where id=p_lead and org_id=p_org for update;
 if not found then raise exception 'RP404: inquiry not found in this workspace';end if;
 if(lead.synced_crm or lead.created_at<=(select legacy_crm_cutoff from public.privacy_runtime where singleton))and
  (nullif(btrim(lead.email),'')is not null or nullif(btrim(lead.phone),'')is not null)then
  payload:=jsonb_build_object('r2','[]'::jsonb,'stream_uids','[]'::jsonb,'ghl_targets',jsonb_build_array(jsonb_strip_nulls(jsonb_build_object('org_id',p_org,'email',nullif(lower(btrim(lead.email)),''),'phone',nullif(btrim(lead.phone),'')))));
  insert into public.privacy_cleanup_jobs(kind,org_id,source_id,source_user_id,payload,remaining)values('lead',p_org,p_lead,p_user,payload,payload)on conflict(kind,source_id)do nothing;
  pending:=true;
 end if;
 -- Client delivery FK cascades remove frozen buyer snapshots and their outbox
 -- rows. Ordinary inbox alerts have no lead FK, so remove their payload too.
 delete from public.notification_outbox o where o.payload#>>'{data,lead_id}'=p_lead::text;
 delete from public.leads where id=p_lead and org_id=p_org;
 return jsonb_build_object('ok',true,'lead_id',p_lead,'deleted',true,'cleanup_pending',pending);
end$function$
;

do $$begin if(select md5(prosrc)from pg_proc where oid='public.notification_on_lead_insert()'::regprocedure)not in('61b999198617954279bbe2d15c01f6f5','7424655304081a971573469d362d8428')then raise exception 'Review changed function notification_on_lead_insert';end if;end$$;
CREATE OR REPLACE FUNCTION public.notification_on_lead_insert()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_address text;
  v_slug    text;
  v_member  record;
begin
  if new.org_id is null then
    -- The demo tour (slug estate-demo) captures leads with no org. Nobody to tell.
    return new;
  end if;

  select l.address into v_address from listings l where l.id = new.listing_id;
  select r.slug    into v_slug    from renders  r where r.id = new.render_id;

  for v_member in
    select m.user_id from memberships m where m.org_id=public.listing_owner_library(new.listing_id)and m.role='owner'and public.listing_content_access(m.user_id,new.listing_id,false)
    union select public.library_team_owner(public.listing_owner_library(new.listing_id))where public.library_team_owner(public.listing_owner_library(new.listing_id))is not null
  loop
    begin
      perform notification_enqueue(
        new.org_id,
        v_member.user_id,
        'lead_received',
        jsonb_build_object(
          -- A PATH, not a URL: the drain owns the public base (TOUR_PUBLIC_BASE_URL)
          -- so a domain change does not have to rewrite queued rows.
          'deep_link', case when v_slug is not null then '/f/' || v_slug else null end,
          'data', jsonb_build_object(
            'lead_id',         new.id,
            'lead_name',       nullif(btrim(coalesce(new.name, '')), ''),
            'has_phone',       (new.phone is not null),
            'has_email',       (new.email is not null),
            'listing_id',      new.listing_id,
            'listing_address', v_address,
            'slug',            v_slug)),
        'lead_received:' || new.id::text || ':' || v_member.user_id::text,
        null);
    exception when others then
      raise warning '0047: lead_received enqueue failed for lead % / user % (% — %)',
        new.id, v_member.user_id, sqlstate, sqlerrm;
    end;
  end loop;

  return new;
end;
$function$
;

do $$begin if(select md5(prosrc)from pg_proc where oid='public.compliance_audit(uuid,uuid,timestamptz,timestamptz)'::regprocedure)not in('f5aa5d3505e365757788d197a41e3549','955f19d690fa82a49696c64a9b0d4706')then raise exception 'Review changed function compliance_audit';end if;end$$;
CREATE OR REPLACE FUNCTION public.compliance_audit(p_org uuid, p_actor uuid, p_from timestamp with time zone, p_to timestamp with time zone)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  c_iso  constant text    := 'YYYY-MM-DD"T"HH24:MI:SS"Z"';
  c_max  constant integer := 5000;
  v_role text;
  v_rows jsonb;
  v_seen bigint;
begin
  if p_org is null or p_actor is null then
    raise exception 'RP400: workspace and caller are required';
  end if;
  if auth.uid() is not null and auth.uid() <> p_actor then
    raise exception 'RP403: the caller does not match the session';
  end if;

  perform 1 from orgs where id = p_org and deleted_at is null;
  if not found then raise exception 'RP404: workspace not found'; end if;

  v_role:=public.library_scope_role(p_actor,p_org);
  if v_role is null or v_role not in ('owner', 'admin') then
    raise exception 'RP403: only the owner or an admin can export the team''s AI record';
  end if;

  with src as (
    select mp.id, mp.org_id,mp.created_at, mp.listing_id, mp.render_id, mp.kind, mp.label,
           mp.edit, mp.style, mp.model_id, mp.prompt_summary, mp.disclosure,
           case when public.studio_presenter_key_access(mp.listing_id,mp.original_key) then mp.original_key else null end as original_key,
           case when public.studio_presenter_key_access(mp.listing_id,mp.altered_key) then mp.altered_key else null end as altered_key,
           li.address as listing_address, li.space_type, li.agent_id
      from media_provenance mp
      left join listings li on li.id = mp.listing_id and li.org_id = mp.org_id
     where((mp.listing_id is not null and public.listing_owner_library(mp.listing_id)=p_org and public.listing_content_access(p_actor,mp.listing_id,false))or(mp.listing_id is null and mp.org_id=p_org and public.library_content_access(p_actor,p_org,false)))
       and (p_from is null or mp.created_at >= p_from)
       and (p_to   is null or mp.created_at <  p_to)
     order by mp.created_at desc, mp.id desc
     limit c_max + 1
  ), numbered as (
    select s.*, row_number() over (order by s.created_at desc, s.id desc) as rn
      from src s
  )
  select coalesce(jsonb_agg(jsonb_build_object(
             'id',              n.id,
             'org_id',          n.org_id,
             'created_at',      to_char(n.created_at at time zone 'UTC', c_iso),
             'listing_id',      n.listing_id,
             'listing_address', n.listing_address,
             'space_type',      n.space_type,
             'render_id',       n.render_id,
             'kind',            n.kind,
             'label',           n.label,
             'edit',            n.edit,
             'style',           n.style,
             'model_id',        n.model_id,
             'prompt_summary',  n.prompt_summary,
             'disclosure',      n.disclosure,
             'original_key',    n.original_key,
             'altered_key',     n.altered_key,
             'agent_id',        n.agent_id,
             'agent_name',      case when n.agent_id is null then null else
                                  coalesce(nullif(btrim(p.name), ''),
                                           nullif(btrim(p.email), ''),
                                           'member ' || left(n.agent_id::text, 8)) end,
             'agent_email',     p.email)
           order by n.rn) filter (where n.rn <= c_max), '[]'::jsonb),
         count(*)
    into v_rows, v_seen
    from numbered n
    left join profiles p on p.id = n.agent_id;

  return jsonb_build_object(
    'org_id',    p_org,
    'scope',     'org',
    'from',      to_char(p_from at time zone 'UTC', c_iso),
    'to',        to_char(p_to   at time zone 'UTC', c_iso),
    'count',     least(v_seen, c_max),
    'truncated', v_seen > c_max,
    'max_rows',  c_max,
    'rows',      v_rows);
end;
$function$
;


create or replace function public.list_library_provenance(p_actor uuid,p_org uuid,p_from timestamptz default null,p_to timestamptz default null,p_listing uuid default null,p_limit integer default 5001)returns jsonb
language plpgsql stable security definer set search_path='' as $$declare r jsonb;begin
 perform public.library_access(p_actor,p_org);
 if p_limit is null or p_limit not between 1 and 5001 then raise exception 'RP400: Invalid compliance page';end if;
 select coalesce(jsonb_agg(x.row order by x.created_at desc,x.id),'[]'::jsonb)into r from(
 select to_jsonb(m)||jsonb_build_object('library_org_id',p_org,'listings',jsonb_build_object('address',l.address,'space_type',l.space_type))as row,m.created_at,m.id
 from public.media_provenance m left join public.listings l on l.id=m.listing_id and l.org_id=m.org_id
 where ((m.listing_id is not null and public.listing_owner_library(m.listing_id)=p_org and public.listing_content_access(p_actor,m.listing_id,false))or(m.listing_id is null and m.org_id=p_org))
 and(p_from is null or m.created_at>=p_from)and(p_to is null or m.created_at<p_to)and(p_listing is null or m.listing_id=p_listing)
 order by m.created_at desc,m.id desc limit p_limit)x;return r;
end$$;
revoke all on function public.list_library_provenance(uuid,uuid,timestamptz,timestamptz,uuid,integer)from public,anon,authenticated;
grant execute on function public.list_library_provenance(uuid,uuid,timestamptz,timestamptz,uuid,integer)to service_role,postgres;

-- UI directory contains only genuine private libraries and explicit owner
-- delegation. Unselected/revoked libraries never silently fall back.
create or replace function public.workspace_directory(p_user uuid,p_preferred_org uuid default null)returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare active uuid;own uuid;rows jsonb;switch boolean:=false;
begin
 if current_setting('role',true)<> 'service_role'then raise insufficient_privilege using message='service role required';end if;
 if not exists(select 1 from public.profiles where id=p_user)then raise exception 'RP401: Sign in again';end if;
 if exists(select 1 from public.deletion_requests where user_id=p_user and status in('pending','processing'))then raise exception 'RP409: This account is being deleted';end if;
 own:=public.agent_private_library(p_user);
 active:=coalesce(p_preferred_org,(select active_org_id from public.user_workspace_state where user_id=p_user));
 if active is not null and not public.library_content_access(p_user,active,false)then
  if p_preferred_org is not null then raise exception 'RP403: This listing library is no longer available';end if;active:=own;
 end if;
 if active is null then select m.org_id into active from public.memberships m where m.user_id=p_user and public.library_content_access(p_user,m.org_id,false)order by m.id limit 1;end if;
 select coalesce(jsonb_agg(jsonb_build_object('id',o.id,'name',o.name)|| (public.library_access(p_user,o.id)-'org_id'-'actor_id')order by o.id),'[]'::jsonb)into rows
 from public.orgs o where o.deleted_at is null and public.library_content_access(p_user,o.id,false);
 switch:=exists(select 1 from jsonb_array_elements(rows)x where x->>'access_mode'='team_owner');
 return jsonb_build_object('actor_id',p_user,'own_org_id',own,'billing_org_id',coalesce(public.library_team_org(own),public.library_billing_org(own)),'can_switch_agent_libraries',switch,'active_org_id',active,'workspaces',rows);
end$$;
create or replace function public.select_workspace(p_user uuid,p_org uuid)returns jsonb
language plpgsql security definer set search_path='' as $$
declare a jsonb;
begin
 if current_setting('role',true)<>'service_role'then raise insufficient_privilege using message='service role required';end if;
 perform 1 from public.profiles where id=p_user for update;
 perform 1 from public.orgs where id=public.library_team_org(p_org)and deleted_at is null for update;
 if exists(select 1 from public.deletion_requests where user_id=p_user and status in('pending','processing'))then raise exception 'RP409: This account is being deleted';end if;
 perform 1 from public.orgs where id=p_org and deleted_at is null for update;
 if not found then raise exception 'RP403: This listing library is unavailable';end if;
 a:=public.library_access(p_user,p_org);
 insert into public.user_workspace_state(user_id,active_org_id)values(p_user,p_org)on conflict(user_id)do update set active_org_id=excluded.active_org_id,updated_at=now();
 return jsonb_build_object('ok',true,'actor_id',p_user,'org_id',p_org,'role',a->>'role','active_org_id',p_org,'org_name',(select name from public.orgs where id=p_org));
end$$;

create or replace function public.bind_team_private_library(p_actor uuid,p_team uuid,p_agent uuid,p_invite uuid)returns uuid
language plpgsql security definer set search_path='' as $$
declare private_id uuid;n integer;owner_id uuid;
begin
 -- Match account deletion's Auth/profile-before-org order. Inserting this
 -- relation also takes profile FK locks; acquiring them after the Team org
 -- lock can deadlock with an owner's concurrent deletion preflight.
 perform 1 from auth.users where id=any(array[p_actor,p_agent])order by id for key share;
 perform 1 from public.profiles where id=any(array[p_actor,p_agent])order by id for update;
 if exists(select 1 from public.deletion_requests where user_id=any(array[p_actor,p_agent])and status in('pending','processing'))then raise exception 'RP409: An account is being deleted';end if;
 owner_id:=public.team_library_owner(p_team);
 if owner_id is null or p_actor<>owner_id or p_agent=owner_id then raise exception 'RP403: Only the current Team owner may link an accepted agent';end if;
 perform 1 from public.orgs where id=p_team for update;
 if public.team_library_owner(p_team)is distinct from owner_id then raise exception 'RP403: Team ownership changed';end if;
 if not exists(select 1 from public.org_invites i where id=p_invite and org_id=p_team and invited_by=owner_id and accepted_by=p_agent and accepted_at is not null and not private_testing)
  or not exists(select 1 from public.memberships m where m.org_id=p_team and m.user_id=p_agent and m.role in('agent','admin','marketing'))then raise exception 'RP403: A current accepted Team seat is required';end if;
 select count(*),min(o.id::text)::uuid into n,private_id from public.orgs o join public.memberships m on m.org_id=o.id and m.user_id=p_agent and m.role='owner'
 where o.deleted_at is null and o.id<>p_team and(select count(*) from public.memberships x where x.org_id=o.id)=1
 and not exists(select 1 from public.private_internal_testing_sponsorships s where s.private_org_id=o.id and s.revoked_at is null)
 and not exists(select 1 from public.brokerage_contracts c where c.org_id=o.id and c.status='active');
 if n<>1 then raise exception 'RP409: Select one existing private listing library before joining this Team';end if;
 perform 1 from public.orgs where id=private_id for update;
 if exists(select 1 from public.team_private_libraries b where b.agent_user_id=p_agent and b.revoked_at is null and(b.team_org_id<>p_team or b.private_org_id<>private_id))then raise exception 'RP409: An existing Team seat must be removed first';end if;
 insert into public.team_private_libraries(team_org_id,team_owner_user_id,agent_user_id,private_org_id,accepted_invite_id)
 values(p_team,owner_id,p_agent,private_id,p_invite)on conflict(agent_user_id)where revoked_at is null do nothing;
 return private_id;
end$$;
-- Exact accepted invitations plus a unique sole-owned private org are the only
-- rollout evidence. Ambiguous owners/libraries are preserved and not guessed.
do $$declare r record;begin
 for r in select distinct on(i.accepted_by)i.* from public.org_invites i
 where i.accepted_at is not null and not i.private_testing and i.accepted_by is not null
  and public.team_library_owner(i.org_id)=i.invited_by
 order by i.accepted_by,i.accepted_at desc,i.id
 loop
  begin perform public.bind_team_private_library(r.invited_by,r.org_id,r.accepted_by,r.id);
  exception when raise_exception then if sqlerrm not like 'RP409:%'and sqlerrm not like 'RP403:%'then raise;end if;end;
 end loop;
end$$;
-- Keep the reviewed invitation atomicity/seat lock and immutable old receipts.
-- The wrapper can replay the accepted seat, then returns its own private library.
CREATE OR REPLACE FUNCTION public.effective_plan_before_team(p_org uuid)
 RETURNS text
 LANGUAGE sql
 STABLE
 SET search_path TO 'public'
AS $function$
  select case
           when public.org_has_app_review_funding(p_org) then 'pro'
           when exists (
             select 1 from public.brokerage_contracts c
              where c.org_id = p_org and c.status = 'active'
                and c.starts_at <= now()
                and (c.ends_at is null or c.ends_at > now()))
             then 'brokerage'
           when o.plan = 'trial' and o.trial_ends_at is not null and o.trial_ends_at < now()
             then 'free'
           when o.plan_source = 'apple'
                and o.plan_expires_at is not null
                and o.plan_expires_at < now() - interval '16 days'
             then 'free'
           else coalesce(o.plan, 'trial')
         end
    from orgs o where o.id = p_org;
$function$
;

revoke all on function public.effective_plan_before_team(uuid) from public,anon,authenticated;
grant execute on function public.effective_plan_before_team(uuid) to service_role,postgres;

CREATE OR REPLACE FUNCTION public.org_entitlement_before_team(p_org uuid)
 RETURNS plan_entitlements
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'public'
AS $function$
declare
  v_base public.plan_entitlements;
  v_over public.plan_entitlement_overrides;
  v_con  public.brokerage_contracts;
begin
  v_base := plan_entitlement(effective_plan(p_org));
  if public.org_has_private_internal_testing(p_org) then
    v_base.plan := 'team';
    v_base.seats := 1;
    v_base.renders_per_month := 2147483647;
    v_base.photo_edits_per_month := 2147483647;
    v_base.reels_per_month := 2147483647;
    v_base.aerials_per_month := 2147483647;
    v_base.topaz_per_month := 2147483647;
    v_base.cogs_ceiling_cents := 2147483647;
    return v_base;
  end if;
  if public.org_has_internal_testing_grant(p_org) then
    v_base.seats := 2147483647;
    v_base.renders_per_month := 2147483647;
    v_base.photo_edits_per_month := 2147483647;
    v_base.reels_per_month := 2147483647;
    v_base.aerials_per_month := 2147483647;
    v_base.topaz_per_month := 2147483647;
    v_base.cogs_ceiling_cents := 2147483647;
    return v_base;
  end if;

  select o.* into v_over
    from plan_entitlement_overrides o
    join orgs g on g.id = p_org
   where o.plan = v_base.plan and o.space_type = g.space_type;
  if found then
    v_base.renders_per_month     := coalesce(v_over.renders_per_month,     v_base.renders_per_month);
    v_base.photo_edits_per_month := coalesce(v_over.photo_edits_per_month, v_base.photo_edits_per_month);
    v_base.reels_per_month       := coalesce(v_over.reels_per_month,       v_base.reels_per_month);
    v_base.aerials_per_month     := coalesce(v_over.aerials_per_month,     v_base.aerials_per_month);
    v_base.topaz_per_month       := coalesce(v_over.topaz_per_month,       v_base.topaz_per_month);
    v_base.seats                 := coalesce(v_over.seats,                 v_base.seats);
    v_base.cogs_ceiling_cents    := coalesce(v_over.cogs_ceiling_cents,    v_base.cogs_ceiling_cents);
  end if;

  -- LAST, so it wins. A signed contract is the deal; nothing above it applies.
  v_con := brokerage_contract(p_org);
  if v_con.org_id is not null then
    v_base.plan                  := 'brokerage';
    v_base.seats                 := v_con.seats;
    v_base.renders_per_month     := v_con.seats * v_con.renders_per_seat;
    v_base.photo_edits_per_month := v_con.seats * v_con.photo_edits_per_seat;
    v_base.reels_per_month       := v_con.seats * v_con.reels_per_seat;
    v_base.aerials_per_month     := v_con.seats * v_con.aerials_per_seat;
    v_base.topaz_per_month       := v_con.seats * v_con.topaz_per_seat;
    v_base.cogs_ceiling_cents    := brokerage_cogs_ceiling_cents(v_con);
    v_base.price_cents           := v_con.seats * v_con.price_cents_per_seat;
  end if;

  if public.org_has_app_review_funding(p_org) then
    v_base := public.plan_entitlement('pro');
    v_base.seats := 1;
    v_base.topaz_per_month := 1;
    v_base.cogs_ceiling_cents := 500;
    return v_base;
  end if;
  return v_base;
end;
$function$
;

revoke all on function public.org_entitlement_before_team(uuid) from public,anon,authenticated;
grant execute on function public.org_entitlement_before_team(uuid) to service_role,postgres;

CREATE OR REPLACE FUNCTION public.plan_serving_ceiling_before_team(p_org uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare o public.orgs;e public.plan_entitlements;s public.apple_subscriptions;plan text;annual boolean;commission integer;margin integer;reserve integer;
 monthly_net numeric;envelope integer;sku text;trial_cap integer;ps timestamptz;pe timestamptz;term_start timestamptz;term_end timestamptz;grace_end timestamptz;slice interval;k integer;
 month_start timestamptz:=date_trunc('month',now());
begin
 select * into o from public.orgs where id=p_org and deleted_at is null;
 if o.id is null then raise exception 'RP404: Workspace unavailable';end if;
 if public.org_has_private_internal_testing(p_org)or public.org_has_internal_testing_grant(p_org)then
  return jsonb_build_object('ceiling_cents',2147483647,'basis','period','kind','sponsored','plan','team','sku',null,'period_start',month_start,'period_end',month_start+interval '1 month','window','calendar_month');end if;
 if public.org_has_app_review_funding(p_org)then
  return jsonb_build_object('ceiling_cents',500,'basis','period','kind','app_review','plan','pro','sku',null,'period_start',month_start,'period_end',month_start+interval '1 month','window','calendar_month');end if;
 e:=public.org_entitlement(p_org);plan:=e.plan;trial_cap:=public.serving_envelope_int('trial_ceiling_cents',500);
 if plan='brokerage'then return jsonb_build_object('ceiling_cents',coalesce(e.cogs_ceiling_cents,0),'basis','period','kind','brokerage','plan',plan,'sku',null,'period_start',month_start,'period_end',month_start+interval '1 month','window','calendar_month');end if;
 if plan='free'then return jsonb_build_object('ceiling_cents',public.serving_envelope_int('free_lifetime_cents',300),'basis','lifetime','kind','free','plan',plan,'sku',null,'period_start',null,'period_end',null,'window','lifetime');end if;
 if plan='trial'then
  -- One Sandbox window: the seven days the grant opened, never a calendar refill.
  if o.trial_ends_at is not null then ps:=o.trial_ends_at-interval '7 days';pe:=o.trial_ends_at;
  else ps:=month_start;pe:=month_start+interval '1 month';end if;
  return jsonb_build_object('ceiling_cents',trial_cap,'basis','period','kind','trial','plan',plan,'sku',null,'period_start',ps,'period_end',pe,'window','trial_window');end if;
 if plan in('starter','solo','pro','team')then
  if o.plan_source='manual'then return jsonb_build_object('ceiling_cents',coalesce(e.cogs_ceiling_cents,0),'basis','period','kind','manual','plan',plan,'sku',null,'period_start',month_start,'period_end',month_start+interval '1 month','window','calendar_month');end if;
  sku:=o.apple_product_id;annual:=coalesce(sku,'')like '%.annual';
  commission:=public.serving_envelope_int('apple_commission_bps',3000);margin:=public.serving_envelope_int('net_margin_bps',7500);
  reserve:=public.serving_envelope_int('hosting_reserve_cents',50);
  -- Annual SKUs are ten monthly prices for twelve months of service.
  monthly_net:=case when annual then coalesce(e.price_cents,0)*10.0*(10000-commission)/10000/12 else coalesce(e.price_cents,0)*(10000-commission)/10000.0 end;
  envelope:=greatest(0,floor(monthly_net*(10000-margin)/10000.0)::integer-reserve);
  select * into s from public.apple_subscriptions where org_id=p_org and environment='Production' and status in('active','grace')
   order by expires_at desc nulls last limit 1;
  if s.original_transaction_id is not null and s.expires_at is not null then
   term_end:=s.expires_at;
   term_start:=coalesce(s.transaction_purchased_at,term_end-(case when annual then interval '1 year' else interval '1 month' end));
   if term_start>=term_end then term_start:=term_end-(case when annual then interval '1 year' else interval '1 month' end);end if;
   -- A free introductory term never turns into paid AI allowance merely
   -- because its renewal notification is delayed. Its sponsor week has ended.
   if s.status='active' and s.transaction_purchased_at is not null and s.expires_at<=s.transaction_purchased_at+interval '8 days' then
    return jsonb_build_object('ceiling_cents',case when s.expires_at>now() then least(envelope,trial_cap) else 0 end,
     'basis','period','kind','trial','plan',plan,'sku',sku,'period_start',s.transaction_purchased_at,'period_end',s.expires_at,'window','intro_window');end if;
   -- A grace snapshot overwrites expires_at with Apple's grace deadline.
   -- This schema does not retain the transaction's signed paid expiry or offer
   -- facts in ceiling mode. A seven-day free intro plus 28-day grace can look
   -- longer than a normal monthly term: duration cannot prove paid funds.
   -- Do not invent money or infer annual slices from that deadline. Complete
   -- commercial grace needs authoritative paid-term/proceeds evidence first.
   if s.status='grace' then
    return jsonb_build_object('ceiling_cents',0,'basis','period','kind','grace','plan',plan,'sku',sku,
     'period_start',term_start,'period_end',s.expires_at,'window','apple_grace');
   end if;
   -- A delayed EXPIRED notification retains the existing 16-day entitlement
   -- fallback. Its active snapshot still carries the signed paid expiry, so
   -- unused paid money can carry through without adding a second allowance.
   grace_end:=term_end+interval '16 days';
   if term_end<=now() then
    ps:=case when annual then term_end-(term_end-term_start)/12 else term_start end;
    pe:=grace_end;
    if now()>=pe then envelope:=0;end if;
    -- Count the original paid term (last annual slice) AND every grace attempt
    -- against one allowance. A recovered transaction later starts its verified
    -- new term, which includes any backdated grace expense in that new term.
    return jsonb_build_object('ceiling_cents',envelope,'basis','period','kind','grace','plan',plan,'sku',sku,'period_start',ps,'period_end',pe,'window','apple_grace');
   end if;
   if annual then
    slice:=(term_end-term_start)/12;
    k:=least(11,greatest(0,floor(extract(epoch from(now()-term_start))/extract(epoch from slice))::integer));
    return jsonb_build_object('ceiling_cents',envelope,'basis','period','kind','retail','plan',plan,'sku',sku,'period_start',term_start+slice*k,'period_end',term_start+slice*(k+1),'window','apple_slice');end if;
   return jsonb_build_object('ceiling_cents',envelope,'basis','period','kind','retail','plan',plan,'sku',sku,'period_start',term_start,'period_end',term_end,'window','apple_term');
  end if;
  return jsonb_build_object('ceiling_cents',envelope,'basis','period','kind','retail','plan',plan,'sku',sku,'period_start',month_start,'period_end',month_start+interval '1 month','window','calendar_month');
 end if;
 return jsonb_build_object('ceiling_cents',coalesce(e.cogs_ceiling_cents,0),'basis','period','kind','other','plan',plan,'sku',null,'period_start',month_start,'period_end',month_start+interval '1 month','window','calendar_month');
end$function$
;

revoke all on function public.plan_serving_ceiling_before_team(uuid) from public,anon,authenticated;
grant execute on function public.plan_serving_ceiling_before_team(uuid) to service_role,postgres;

CREATE OR REPLACE FUNCTION public.accept_org_invite_before_team(p_user uuid, p_token_hash text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_private_result jsonb;
  v_org uuid;
  v_invite public.org_invites%rowtype;
  v_existing_role text;
  v_allowed integer;
  v_used integer;
  v_name text;
begin
  v_private_result := public.accept_private_internal_test_invite(p_user,p_token_hash);
  if v_private_result is not null then return v_private_result; end if;
  -- Serialise this user's own joins/adoptions against each other.
  perform 1 from public.profiles where id = p_user for update;
  if not found then raise exception 'RP401: session no longer exists'; end if;
  if exists (select 1 from public.deletion_requests
             where user_id = p_user and status in ('processing','pending')) then
    raise exception 'RP409: this account is being deleted';
  end if;

  select org_id into v_org from public.org_invites where token_hash = p_token_hash;
  if not found then raise exception 'RP404: that invite code is not valid, or it has expired'; end if;

  -- THE lock. Every seat mutation takes it before reading any count.
  select name into v_name from public.orgs
    where id = v_org and deleted_at is null for update;
  if not found then raise exception 'RP404: that invite code is not valid, or it has expired'; end if;

  select * into v_invite from public.org_invites
    where token_hash = p_token_hash and org_id = v_org for update;
  if not found then raise exception 'RP404: that invite code is not valid, or it has expired'; end if;

  select role into v_existing_role from public.memberships
    where user_id = p_user and org_id = v_org;

  if v_invite.accepted_at is not null then
    -- Idempotent for the person who accepted it — but a REMOVED member cannot
    -- walk back in by replaying their own old code.
    if v_invite.accepted_by is distinct from p_user or v_existing_role is null then
      raise exception 'RP404: that invite code is not valid, or it has expired';
    end if;
  else
    if v_invite.revoked_at is not null then
      raise exception 'RP404: that invite code is not valid, or it has expired';
    end if;
    if v_invite.expires_at <= now() then
      raise exception 'RP404: that invite code is not valid, or it has expired';
    end if;
    if v_existing_role is null then
      v_used    := public.org_seats_used(v_org);
      v_allowed := public.org_seats_allowed(v_org);
      if v_allowed is null or v_allowed < 1 then
        raise exception 'RP503: this team''s plan is unavailable right now';
      end if;
      -- This pending invite is itself counted in `used`, so the test is
      -- strictly greater than.
      if v_used > v_allowed then
        raise exception 'RP402: this team is full — every seat on its plan is taken';
      end if;
      insert into public.memberships(user_id, org_id, role)
        values (p_user, v_org, v_invite.role);
      v_existing_role := v_invite.role;
    end if;
    update public.org_invites set accepted_at = now(), accepted_by = p_user
      where id = v_invite.id;
  end if;

  insert into public.user_workspace_state(user_id, active_org_id)
    values (p_user, v_org)
    on conflict (user_id) do update
      set active_org_id = excluded.active_org_id, updated_at = now();

  return jsonb_build_object('ok', true, 'org_id', v_org,
                            'org_name', v_name, 'role', v_existing_role);
end;
$function$
;

revoke all on function public.accept_org_invite_before_team(uuid,text) from public,anon,authenticated;
grant execute on function public.accept_org_invite_before_team(uuid,text) to service_role,postgres;

CREATE OR REPLACE FUNCTION public.hosting_retention_state_before_team(p_org uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare deadline timestamptz;qa boolean;comped boolean:=false;
begin
 if current_setting('role',true)not in('service_role','postgres','supabase_admin')and not(current_setting('role',true)='none'and session_user in('postgres','supabase_admin'))then raise insufficient_privilege using message='service role required';end if;
 if not exists(select 1 from public.orgs where id=p_org and deleted_at is null)then raise exception 'RP404: Workspace unavailable';end if;
 qa:=public.org_has_internal_testing_grant(p_org)or public.org_has_private_internal_testing(p_org);
 -- Refund/revocation does not erase the already promised grace. A renewal can
 -- extend it, while App Review grants never impose a retail retention policy.
 select greatest((select max(retention_ends_at) from public.serving_funding where org_id=p_org and source in('retail','trial')),
  (select max(retention_ends_at) from public.hosting_retention_enrollments where org_id=p_org))into deadline;
 -- An owner-granted paid plan or a signed brokerage contract is not subject to
 -- a lapsed App Store subscription's grace deadline.
 comped:=(exists(select 1 from public.orgs o where o.id=p_org and o.plan_source='manual')and public.effective_plan(p_org)in('starter','solo','pro','team'))or public.effective_plan(p_org)='brokerage';
 if qa or comped or deadline is null then return jsonb_build_object('org_id',p_org,'policy','preserved','protected',qa,'retention_ends_at',null,'hosting_available',true);end if;
 return jsonb_build_object('org_id',p_org,'policy','prospective_90_day_grace','protected',false,'retention_ends_at',deadline,'hosting_available',clock_timestamp()<deadline);
end$function$
;

revoke all on function public.hosting_retention_state_before_team(uuid) from public,anon,authenticated;
grant execute on function public.hosting_retention_state_before_team(uuid) to service_role,postgres;

CREATE OR REPLACE FUNCTION public.subscription_trial_paid_or_override_before_team(p_org uuid)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
 select exists(select 1 from public.orgs o where o.id=p_org and o.deleted_at is null and (
  public.org_has_internal_testing_grant(p_org)or public.org_has_private_internal_testing(p_org)or public.org_has_app_review_funding(p_org)
  or(o.plan_source='manual'and public.effective_plan(p_org)in('starter','pro','team'))
  or exists(select 1 from public.brokerage_contracts c where c.org_id=p_org and c.status='active'and c.starts_at<=now()and(c.ends_at is null or c.ends_at>now()))
  or(o.plan_source='apple'and public.serving_mode()='ceiling'and public.effective_plan(p_org)in('starter','pro','team'))
  or(o.plan_source='apple'and exists(select 1 from public.serving_funding f join public.apple_subscriptions s
   on s.original_transaction_id=f.apple_original_transaction_id and s.org_id=f.org_id
   where f.org_id=p_org and f.source='retail'and f.revoked_at is null and f.starts_at<=now()and f.ends_at>now()
    and s.environment='Production'and s.status='active'and s.expires_at>now()))));
$function$
;

revoke all on function public.subscription_trial_paid_or_override_before_team(uuid) from public,anon,authenticated;
grant execute on function public.subscription_trial_paid_or_override_before_team(uuid) to service_role,postgres;


create or replace function public.library_internal_content_unlimited(p_org uuid)returns boolean language sql stable security definer set search_path='' as $$
 select exists(select 1 from public.private_internal_testing_sponsorships s where s.private_org_id=p_org and public.private_team_content_binding_valid(s.id)
 and(current_setting('role',true)in('service_role','postgres','supabase_admin')or auth.uid()in(s.beneficiary_user_id,s.sponsor_owner_user_id)));
$$;
revoke all on function public.library_internal_content_unlimited(uuid)from public,anon,authenticated;
grant execute on function public.library_internal_content_unlimited(uuid)to service_role,postgres;
create or replace function public.effective_plan(p_org uuid)returns text language sql stable security definer set search_path='' as $$
 select case when public.library_internal_content_unlimited(p_org)then 'team'else public.effective_plan_before_team(public.library_billing_org(p_org))end;$$;
create or replace function public.org_entitlement(p_org uuid)returns public.plan_entitlements language plpgsql stable security definer set search_path='' as $$
declare e public.plan_entitlements;b uuid;begin b:=public.library_billing_org(p_org);e:=public.org_entitlement_before_team(b);if public.library_internal_content_unlimited(p_org)then e.plan:='team';e.price_cents:=0;e.seats:=1;e.renders_per_month:=2147483647;e.photo_edits_per_month:=2147483647;e.reels_per_month:=2147483647;e.aerials_per_month:=2147483647;e.topaz_per_month:=2147483647;e.cogs_ceiling_cents:=2147483647;elsif b<>p_org then e.seats:=1;end if;return e;end$$;
create or replace function public.plan_serving_ceiling(p_org uuid)returns jsonb language sql stable security definer set search_path='' as $$
 select public.plan_serving_ceiling_before_team(public.library_billing_org(p_org));$$;
create or replace function public.hosting_retention_state(p_org uuid)returns jsonb language sql stable security definer set search_path='' as $$
 select public.hosting_retention_state_before_team(public.library_billing_org(p_org))||jsonb_build_object('org_id',p_org,'billing_org_id',public.library_billing_org(p_org));$$;
create or replace function public.subscription_trial_paid_or_override(p_org uuid)returns boolean language sql stable security definer set search_path='' as $$
 select public.library_internal_content_unlimited(p_org)or public.subscription_trial_paid_or_override_before_team(public.library_billing_org(p_org));$$;
create or replace function public.accept_org_invite(p_user uuid,p_token_hash text)returns jsonb language plpgsql security definer set search_path='' as $$
declare r jsonb;i public.org_invites;private_id uuid;was_accepted boolean;current_owner uuid;lock_users uuid[];begin
 select *into i from public.org_invites where token_hash=p_token_hash;
 was_accepted:=i.accepted_at is not null;
 if found and(public.effective_plan_before_team(i.org_id)='team'or i.private_testing)then
  current_owner:=public.team_library_owner(i.org_id);
  lock_users:=array[p_user,i.invited_by,current_owner];
  -- Acquire every participant in deterministic Auth/profile order before the
  -- original accepted-seat org lock. Never weaken the binding FK or allow an
  -- invite to revive a participant whose deletion already won this race.
  perform 1 from auth.users where id=any(lock_users)order by id for key share;
  perform 1 from public.profiles where id=any(lock_users)order by id for update;
  if exists(select 1 from public.deletion_requests where user_id=any(lock_users)and status in('pending','processing'))then raise exception 'RP409: An account is being deleted';end if;
 end if;
 r:=public.accept_org_invite_before_team(p_user,p_token_hash);
 if coalesce((r->>'private_testing')::boolean,false)then return r;end if;
 select *into i from public.org_invites where token_hash=p_token_hash;
 if public.team_library_owner(i.org_id)is not null then
  private_id:=public.bind_team_private_library(i.invited_by,i.org_id,p_user,i.id);
  if not coalesce(was_accepted,false)then insert into public.user_workspace_state(user_id,active_org_id)values(p_user,private_id)on conflict(user_id)do update set active_org_id=excluded.active_org_id,updated_at=now();end if;
  return r||jsonb_build_object('org_id',private_id,'org_name',(select name from public.orgs where id=private_id),'private_org_id',private_id,'team_org_id',i.org_id,'role','owner','access_mode','own','private_team',true);
 end if;
 return r;
end$$;
create or replace function public.library_scope_role(p_actor uuid,p_org uuid,p_listing uuid default null)returns text
language plpgsql stable security definer set search_path='' as $$declare r text;logical uuid:=p_org;begin
 if p_listing is not null then
  if not exists(select 1 from public.listings where id=p_listing and org_id=p_org)or not public.listing_content_access(p_actor,p_listing,false)then return null;end if;
  logical:=public.listing_owner_library(p_listing);
 elsif not public.library_content_access(p_actor,p_org,false)then return null;end if;
 select role into r from public.memberships where org_id=logical and user_id=p_actor;
 if public.library_team_owner(logical)=p_actor then return 'owner';end if;
 return r;
end$$;
create or replace function public.library_financial_actor(p_actor uuid,p_org uuid)returns boolean
language sql stable security definer set search_path='' as $$
 select public.library_content_access(p_actor,p_org,true)or exists(select 1 from public.listings l where l.org_id=p_org and l.agent_id=p_actor and public.listing_content_access(p_actor,l.id,true));$$;
create or replace function public.library_actor_billing_org(p_actor uuid,p_org uuid)returns uuid
language sql stable security definer set search_path='' as $$
 select case when public.library_content_access(p_actor,p_org,false)then public.library_billing_org(p_org)
 else coalesce((select public.library_billing_org(public.listing_owner_library(l.id))from public.listings l where l.org_id=p_org and l.agent_id=p_actor and public.listing_content_access(p_actor,l.id,false)order by l.id limit 1),p_org)end;$$;

create or replace function public.team_library_owner(p_org uuid)returns uuid language sql stable security definer set search_path='' as $$
 select min(m.user_id::text)::uuid from public.memberships m join public.orgs o on o.id=m.org_id and o.deleted_at is null join auth.users u on u.id=m.user_id and not u.is_anonymous where m.org_id=p_org and m.role='owner'and public.effective_plan_before_team(p_org)='team'and not exists(select 1 from public.team_private_libraries b where b.private_org_id=p_org and b.revoked_at is null)and not exists(select 1 from public.private_internal_testing_sponsorships s where s.private_org_id=p_org and s.revoked_at is null)and not exists(select 1 from public.deletion_requests d where d.user_id=m.user_id and d.status in('pending','processing'))having count(*)=1 and(select count(*) from public.memberships x where x.org_id=p_org and x.role='owner')=1;$$;

CREATE OR REPLACE FUNCTION public.library_serving_envelope_admit(p_content_org uuid, p_billing_org uuid, p_hold_cents numeric, p_request_key text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare env jsonb;ceiling numeric;kind text;ps timestamptz;pe timestamptz;spent numeric;pre numeric;pool jsonb;pool_spent numeric;
begin
 if p_hold_cents is null or p_hold_cents<=0 then raise exception 'RP400: A positive hold is required';end if;
 perform pg_advisory_xact_lock(hashtextextended('org_month_spend:'||p_billing_org::text,42));
 env:=public.plan_serving_ceiling(p_billing_org);
 ceiling:=(env->>'ceiling_cents')::numeric;kind:=env->>'kind';ps:=(env->>'period_start')::timestamptz;pe:=(env->>'period_end')::timestamptz;
 if kind='sponsored' then return env||jsonb_build_object('spent_cents',0,'hold_cents',p_hold_cents);end if;
 spent:=public.serving_ceiling_spent_cents(p_billing_org,ps,pe);
 -- The first serving reservation for an attempt that already holds money
 -- through the legacy video/erase writer replaces that hold rather than adding
 -- to it. Only net holds that `spent` still counts: once a live serving
 -- reservation exists for the key, spent has already excluded them.
 pre:=0;
 if p_request_key is not null and not exists(select 1 from public.serving_cost_reservations r
   where r.org_id=p_content_org and r.request_key=p_request_key and r.budget_source='ceiling' and r.ledger_id is null and r.state<>'rejected')then
  pre:=coalesce((select sum(v.hold_cents)from public.app_video_cost_reservations v where v.org_id=p_content_org and v.idempotency_key=p_request_key and v.cost_ledger_id is null and v.released_at is null
     and(ps is null or v.created_at>=ps)and(pe is null or v.created_at<pe)),0)
   +coalesce((select sum(j.cost_cents)from public.video_erase_jobs j where j.org_id=p_content_org and j.idempotency_key::text=p_request_key and j.provider='fal' and j.cost_ledger_id is null and j.cost_hold_released_at is null
     and(ps is null or j.created_at>=ps)and(pe is null or j.created_at<pe)),0);
 end if;
 spent:=greatest(0,spent-pre);
 if ceiling is null or spent+p_hold_cents>ceiling then
  raise exception 'RP402: AI usage limit reached [kind=%] (% of % cents this %)',kind,round(spent),coalesce(ceiling,0),case when ps is null then 'lifetime' else 'period' end;end if;
 if kind='trial' then
  perform pg_advisory_xact_lock(hashtextextended('serving:trial-sponsor',72452));
  pool:=public.trial_sponsor_pool();
  if pool is null or now()<(pool->>'starts_at')::timestamptz or now()>=(pool->>'ends_at')::timestamptz then raise exception 'RP402: Free-trial AI limit reached [pool=closed]';end if;
  pool_spent:=public.trial_sponsor_spent_cents();
  if pool_spent+p_hold_cents>(pool->>'cap_cents')::numeric then raise exception 'RP402: Free-trial AI limit reached [pool=cap]';end if;
 end if;
 return env||jsonb_build_object('spent_cents',spent,'hold_cents',p_hold_cents);
end$function$
;
revoke all on function public.library_serving_envelope_admit(uuid,uuid,numeric,text)from public,anon,authenticated;
grant execute on function public.library_serving_envelope_admit(uuid,uuid,numeric,text)to service_role,postgres;

alter table public.cost_ledger add column if not exists billing_org_id uuid;
alter table public.cost_ledger drop constraint if exists cost_ledger_billing_org_id_fkey;
update public.cost_ledger set billing_org_id=org_id where billing_org_id is null;
alter table public.render_jobs add column if not exists billing_org_id uuid;
update public.render_jobs j set billing_org_id=l.org_id from public.listings l where l.id=j.listing_id and j.billing_org_id is null;
create index if not exists render_jobs_billing_org on public.render_jobs(billing_org_id);
create index if not exists cost_ledger_billing_org on public.cost_ledger(billing_org_id);

alter table public.serving_cost_reservations add column if not exists billing_org_id uuid;
alter table public.serving_cost_reservations drop constraint if exists serving_cost_reservations_billing_org_id_fkey;
update public.serving_cost_reservations set billing_org_id=org_id where billing_org_id is null;
create index if not exists serving_cost_reservations_billing_org on public.serving_cost_reservations(billing_org_id);

alter table public.app_video_cost_reservations add column if not exists billing_org_id uuid;
alter table public.app_video_cost_reservations drop constraint if exists app_video_cost_reservations_billing_org_id_fkey;
update public.app_video_cost_reservations set billing_org_id=org_id where billing_org_id is null;
create index if not exists app_video_cost_reservations_billing_org on public.app_video_cost_reservations(billing_org_id);

alter table public.video_erase_jobs add column if not exists billing_org_id uuid;
alter table public.video_erase_jobs drop constraint if exists video_erase_jobs_billing_org_id_fkey;
update public.video_erase_jobs set billing_org_id=org_id where billing_org_id is null;
create index if not exists video_erase_jobs_billing_org on public.video_erase_jobs(billing_org_id);

alter table public.upload_reservations add column if not exists billing_org_id uuid;
alter table public.upload_reservations drop constraint if exists upload_reservations_billing_org_id_fkey;
update public.upload_reservations set billing_org_id=org_id where billing_org_id is null;
create index if not exists upload_reservations_billing_org on public.upload_reservations(billing_org_id);

alter table public.media_storage_receipts add column if not exists billing_org_id uuid;
alter table public.media_storage_receipts add column if not exists actor_id uuid;
alter table public.media_storage_receipts drop constraint if exists media_storage_receipts_billing_org_id_fkey;
update public.media_storage_receipts set billing_org_id=org_id where billing_org_id is null;
create index if not exists media_storage_receipts_billing_org on public.media_storage_receipts(billing_org_id);


create or replace function public.stamp_library_financial_liability()returns trigger language plpgsql security definer set search_path='' as $$
declare actor uuid;b uuid;matches integer;row_data jsonb:=to_jsonb(new);begin
 if tg_op='UPDATE'then if new.billing_org_id is distinct from old.billing_org_id then raise exception 'RP409: Billing liability identity is immutable';end if;return new;end if;
 actor:=coalesce(nullif(row_data->>'actor_id','')::uuid,nullif(row_data->>'user_id','')::uuid);
 if tg_table_name='cost_ledger'then
  -- Exact existing request/stage/provider/model is accounting authority. Never
  -- choose a FIFO predecessor or the most convenient current Team relationship.
  select count(*),min(r.billing_org_id::text)::uuid into matches,b from public.serving_cost_reservations r
  where r.org_id=new.org_id and r.request_key=coalesce(nullif(new.meta->>'request_key',''),new.idempotency_key)and r.stage=new.meta->>'stage'and r.provider=new.provider and r.model=new.model
    and (new.meta->>'actor_id'is null or r.actor_id::text=new.meta->>'actor_id');
  if matches<>1 then b:=null;end if;
  if b is null and new.meta->>'app_video_reservation_id'~'^[a-f0-9]{8}(-[a-f0-9]{4}){3}-[a-f0-9]{12}$'then
   select r.billing_org_id into b from public.app_video_cost_reservations r where r.id=(new.meta->>'app_video_reservation_id')::uuid and r.org_id=new.org_id and r.provider=new.provider and r.model=new.model and r.idempotency_key=new.meta->>'request_key'and r.feature=new.meta->>'stage';
  end if;
  if b is null and new.meta->>'erase_job_id'~'^[a-f0-9]{8}(-[a-f0-9]{4}){3}-[a-f0-9]{12}$'then
   select j.billing_org_id into b from public.video_erase_jobs j where j.id=(new.meta->>'erase_job_id')::uuid and j.org_id=new.org_id and j.provider=new.provider and new.meta->>'stage'in('reflection.fal','reflection.mask','reflection.erase');
  end if;
  if b is null and new.job_id is not null then select j.billing_org_id,l.agent_id into b,actor from public.render_jobs j join public.listings l on l.id=j.listing_id where j.id=new.job_id;end if;
 end if;
 if tg_table_name='media_storage_receipts'then actor:=new.actor_id;b:=case when actor is null then public.library_storage_billing_org(new.org_id,new.bucket,new.object_key)else public.library_actor_billing_org(actor,new.org_id)end;end if;
 b:=coalesce(b,case when actor is null then public.library_billing_org(new.org_id)else public.library_actor_billing_org(actor,new.org_id)end);
 if new.billing_org_id is not null and new.billing_org_id<>b then raise exception 'RP403: Billing org is server-owned';end if;
 new.billing_org_id:=b;return new;
end$$;

drop trigger if exists z_team_billing_liability on public.cost_ledger;
create trigger z_team_billing_liability before insert or update on public.cost_ledger for each row execute function public.stamp_library_financial_liability();

drop trigger if exists z_team_billing_liability on public.serving_cost_reservations;
create trigger z_team_billing_liability before insert or update on public.serving_cost_reservations for each row execute function public.stamp_library_financial_liability();

drop trigger if exists z_team_billing_liability on public.app_video_cost_reservations;
create trigger z_team_billing_liability before insert or update on public.app_video_cost_reservations for each row execute function public.stamp_library_financial_liability();

drop trigger if exists z_team_billing_liability on public.video_erase_jobs;
create trigger z_team_billing_liability before insert or update on public.video_erase_jobs for each row execute function public.stamp_library_financial_liability();

drop trigger if exists z_team_billing_liability on public.upload_reservations;
create trigger z_team_billing_liability before insert or update on public.upload_reservations for each row execute function public.stamp_library_financial_liability();

drop trigger if exists z_team_billing_liability on public.media_storage_receipts;
create trigger z_team_billing_liability before insert or update on public.media_storage_receipts for each row execute function public.stamp_library_financial_liability();

do $$begin if(select md5(prosrc) from pg_proc where oid='public.serving_ceiling_spent_cents(uuid,timestamp with time zone,timestamp with time zone)'::regprocedure)not in('3e92a419dbc8ca71e2337640c78ead68','d053fe5bd094d958041a48f0c02dfa4f')then raise exception 'Review changed function serving_ceiling_spent_cents(uuid,timestamp with time zone,timestamp with time zone)';end if;end$$;

CREATE OR REPLACE FUNCTION public.serving_ceiling_spent_cents(p_org uuid, p_start timestamp with time zone, p_end timestamp with time zone)
 RETURNS numeric
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
 select coalesce((select sum(total_cents) from public.cost_ledger c where c.billing_org_id=public.library_billing_org(p_org) and(p_start is null or c.created_at>=p_start)and(p_end is null or c.created_at<p_end)),0)
  +coalesce((select sum(hold_cents) from public.serving_cost_reservations r where r.billing_org_id=public.library_billing_org(p_org) and r.budget_source='ceiling' and r.ledger_id is null
     and r.state in('reserved','uncertain','succeeded')),0)
  +coalesce((select sum(v.hold_cents) from public.app_video_cost_reservations v where v.billing_org_id=public.library_billing_org(p_org) and v.cost_ledger_id is null and v.released_at is null

     and not exists(select 1 from public.serving_cost_reservations r where r.org_id=v.org_id and r.request_key=v.idempotency_key and r.budget_source='ceiling' and r.ledger_id is null and r.state<>'rejected')),0)
  +coalesce((select sum(j.cost_cents) from public.video_erase_jobs j where j.billing_org_id=public.library_billing_org(p_org) and j.provider='fal' and j.cost_ledger_id is null and j.cost_hold_released_at is null

     and not exists(select 1 from public.serving_cost_reservations r where r.org_id=j.org_id and r.request_key=j.idempotency_key::text and r.budget_source='ceiling' and r.ledger_id is null and r.state<>'rejected')),0)
  +coalesce((select sum(st.cost_cents) from public.video_erase_stages st join public.video_erase_jobs j on j.id=st.job_id where j.billing_org_id=public.library_billing_org(p_org) and st.cost_ledger_id is null and st.cost_hold_released_at is null
     ),0);
$function$
;

do $$begin if(select md5(prosrc) from pg_proc where oid='public.serving_cost_reserve(uuid,uuid,text,text,text,text,text,numeric,text)'::regprocedure)not in('86e4278cf840d1adbee40be15df8ed41','cb21cbb5723dbc3cddb6fa5d7b5a7895')then raise exception 'Review changed function serving_cost_reserve(uuid,uuid,text,text,text,text,text,numeric,text)';end if;end$$;

CREATE OR REPLACE FUNCTION public.serving_cost_reserve(p_actor uuid, p_org uuid, p_key text, p_stage text, p_provider text, p_model text, p_input_sha256 text, p_hold_cents numeric, p_tariff_version text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare prior public.serving_cost_reservations;f public.serving_funding;s public.serving_funding_slices;
 unlimited boolean;spent numeric;reservation uuid;envelope jsonb;ceiling numeric;basis text;kind text;
begin
 if current_setting('role',true)is distinct from 'service_role'then raise insufficient_privilege;end if;
 if p_key is null or p_key !~ '^[A-Za-z0-9:_-]{8,128}$'or p_stage is null or p_stage !~ '^[a-z0-9:._-]{1,80}$'
  or p_input_sha256 is null or p_input_sha256 !~ '^[a-f0-9]{64}$'or p_hold_cents is null
  or p_hold_cents::text in('NaN','Infinity','-Infinity')or p_hold_cents<=0 or p_hold_cents>100000000
  or p_hold_cents<>round(p_hold_cents,4)or p_provider is null or length(p_provider)not between 1 and 40
  or p_model is null or length(p_model)not between 1 and 240 or p_tariff_version is null or length(p_tariff_version)not between 1 and 120 then raise exception 'RP400: A bounded verified attempt quote is required';end if;
 perform pg_advisory_xact_lock(hashtextextended('serving:'||public.library_actor_billing_org(p_actor,p_org),72452));
 if public.serving_mode()='ceiling' then perform pg_advisory_xact_lock(hashtextextended('org_month_spend:'||public.library_actor_billing_org(p_actor,p_org)::text,42));end if;
 perform 1 from public.orgs where id=public.library_actor_billing_org(p_actor,p_org)and deleted_at is null for update;
 perform 1 from public.orgs where id=p_org and deleted_at is null for update;
 if not found or not public.library_financial_actor(p_actor,p_org)
  or (not exists(select 1 from auth.users where id=p_actor and is_anonymous is false) and not public.org_has_verified_retail_guest(p_actor,p_org))
  or exists(select 1 from public.deletion_requests where user_id=p_actor and status in('pending','processing'))then raise exception 'RP403: Current editor access is required';end if;
 select * into prior from public.serving_cost_reservations where org_id=p_org and actor_id=p_actor and request_key=p_key and stage=p_stage;
 if prior.id is not null then raise exception 'RP409: This provider attempt is already journaled; restore its existing result';end if;
 unlimited:=public.org_has_internal_testing_grant(public.library_actor_billing_org(p_actor,p_org))or public.org_has_private_internal_testing(public.library_actor_billing_org(p_actor,p_org));
 if not unlimited then
  if p_tariff_version='unpriced-private-sponsorship' then raise exception 'RP403: An unpriced route is restricted to unlimited private sponsorship';end if;
  if public.serving_mode()='ceiling' then
   -- Ceiling mode: serving_envelope_admit is the single money authority shared
   -- with the video and erase writers (same org_month_spend lock).
   envelope:=public.library_serving_envelope_admit(p_org,public.library_actor_billing_org(p_actor,p_org),p_hold_cents,p_key);
   ceiling:=(envelope->>'ceiling_cents')::numeric;basis:=envelope->>'basis';kind:=envelope->>'kind';spent:=(envelope->>'spent_cents')::numeric;
   insert into public.serving_cost_reservations(org_id,actor_id,request_key,stage,provider,model,input_sha256,tariff_version,hold_cents,sponsored_unlimited,budget_source,trial_kind)
   values(p_org,p_actor,p_key,p_stage,p_provider,p_model,p_input_sha256,p_tariff_version,p_hold_cents,false,'ceiling',kind='trial')returning id into reservation;
   return jsonb_build_object('reserved',true,'id',reservation,'hold_cents',p_hold_cents,'sponsored_unlimited',false,'budget','ceiling','ceiling_cents',ceiling,'spent_cents',spent,'basis',basis,'kind',kind,'period_end',envelope->'period_end');
  end if;
  select funding.* into f from public.serving_funding funding where org_id=public.library_actor_billing_org(p_actor,p_org) and revoked_at is null and starts_at<=now()and ends_at>now();
  if f.id is null then raise exception 'RP402: This workspace has no funded serving allowance';end if;
  if f.source<>'retail'and f.actor_id is distinct from p_actor then raise exception 'RP403: Sponsored funds belong to the named test account';end if;
  if f.source='app_review'and not public.org_has_app_review_funding(p_org)then raise exception 'RP403: App Review authority is unavailable';end if;
  select * into s from public.serving_funding_slices where funding_id=f.id and starts_at<=now()and ends_at>now();
  if s.funding_id is null then raise exception 'RP402: This paid service interval is not funded';end if;
  select coalesce(sum(hold_cents),0)into spent from public.serving_cost_reservations where funding_id=s.funding_id and slice_index=s.slice_index and state<>'rejected';
  if spent+p_hold_cents>s.total_budget_cents-s.recurring_reserve_cents then raise exception 'RP402: This attempt exceeds the shared funded serving allowance';end if;
 end if;
 insert into public.serving_cost_reservations(org_id,actor_id,request_key,stage,funding_id,slice_index,provider,model,input_sha256,tariff_version,hold_cents,sponsored_unlimited)
 values(p_org,p_actor,p_key,p_stage,s.funding_id,s.slice_index,p_provider,p_model,p_input_sha256,p_tariff_version,p_hold_cents,unlimited)returning id into reservation;
 return jsonb_build_object('reserved',true,'id',reservation,'hold_cents',p_hold_cents,'sponsored_unlimited',unlimited);
end$function$
;

do $$begin if(select md5(prosrc) from pg_proc where oid='public.app_video_cost_reserve(uuid,uuid,text,text,text,text,text,numeric,numeric,numeric,jsonb)'::regprocedure)not in('210594d9aaf95e609f7f6967491ba7d0','9828980adb313656910f14caee8a8111')then raise exception 'Review changed function app_video_cost_reserve(uuid,uuid,text,text,text,text,text,numeric,numeric,numeric,jsonb)';end if;end$$;

CREATE OR REPLACE FUNCTION public.app_video_cost_reserve(p_actor uuid, p_org uuid, p_key text, p_feature text, p_provider text, p_model text, p_input_sha256 text, p_hold_cents numeric, p_units numeric, p_unit_cost_cents numeric, p_meta jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare e public.plan_entitlements; r public.app_video_cost_reservations;
  priced numeric; spent numeric; cap integer;
begin
  if p_actor is null or p_org is null or p_key is null or p_key !~ '^[!-~]{8,128}$'
    or p_feature is null or p_feature not in ('drone_render','aerial','reel')
    or p_provider is null or p_provider not in ('fal','kie','higgsfield')
    or p_model is null or length(p_model) not between 1 and 240 or p_model !~ '^[A-Za-z0-9][A-Za-z0-9._:/@+-]*$'
    or p_input_sha256 is null or p_input_sha256 !~ '^[a-f0-9]{64}$' then
    raise exception 'RP400: Invalid video reservation identity';
  end if;
  -- Bounded numeric comparisons reject NaN and both infinities as well as
  -- overflow. Retain precise input quantities; ledger total is rounded once.
  if p_units is null or not(p_units>0 and p_units<=1000000)
    or p_unit_cost_cents is null or not(p_unit_cost_cents>0 and p_unit_cost_cents<=999999)
    or p_hold_cents is null or not(p_hold_cents>0 and p_hold_cents<=99999999) then
    raise exception 'RP400: Video pricing must be positive, finite and bounded';
  end if;
  priced:=round(p_units*p_unit_cost_cents,4);
  if priced<=0 or priced>p_hold_cents then raise exception 'RP400: Video hold does not cover its priced attempt'; end if;
  -- Only server-generated scalar routing/price facts; never prompts, URLs,
  -- customer labels, arbitrary room text, secrets or media bodies.
  if p_meta is null or jsonb_typeof(p_meta)<>'object' or octet_length(p_meta::text)>4096 then
    raise exception 'RP400: Invalid video accounting metadata';
  end if;
  if exists(select 1 from jsonb_each(p_meta) x where x.key not in
      ('tier','upscale_factor','target_fps','interpolated','estimate_cents','output_fps',
       'grounded','seconds','aspect','motion','motion_requested','space_type',
       'route_id','task','unit','price_estimated')
      or jsonb_typeof(x.value) not in ('string','number','boolean','null')
      or (jsonb_typeof(x.value)='string' and
        (length(x.value#>>'{}')>128 or (x.value#>>'{}') !~ '^[A-Za-z0-9._:/+-]*$' or strpos(x.value#>>'{}','://')>0))) then
    raise exception 'RP400: Unsupported video accounting metadata';
  end if;

  -- Identical lock identity to reflection and log_job_cost. The hold commits
  -- before the caller receives reserved:true and may make its single POST.
  perform pg_advisory_xact_lock(hashtextextended('org_month_spend:'||public.library_actor_billing_org(p_actor,p_org)::text,42));
  perform 1 from public.orgs where id=public.library_actor_billing_org(p_actor,p_org)and deleted_at is null for update;
 perform 1 from public.orgs where id=p_org and deleted_at is null for update;
  if not found then raise exception 'RP403: Workspace is unavailable for video processing'; end if;
  perform 1 where public.library_financial_actor(p_actor,p_org);
  if not found then raise exception 'RP403: Your role does not permit video processing'; end if;
  if exists(select 1 from public.deletion_requests where user_id=p_actor and status in ('pending','processing')) then
    raise exception 'RP409: This account is being deleted; no video submission was admitted';
  end if;
  if exists(select 1 from public.app_video_cost_reservations where org_id=p_org and idempotency_key=p_key) then
    -- Even the same actor/input/route is never a second dispatch permission.
    raise exception 'RP409: This video submission already has a reservation; no retry was made';
  end if;
  e:=public.org_entitlement(public.library_actor_billing_org(p_actor,p_org));
  cap:=case p_feature when 'drone_render' then e.topaz_per_month when 'aerial' then e.aerials_per_month else e.reels_per_month end;
  if coalesce(cap,0)<=0 or coalesce(e.cogs_ceiling_cents,0)<=0 then raise exception 'RP402: Video processing is not included in this workspace plan'; end if;
  spent:=public.org_month_spend_cents(public.library_actor_billing_org(p_actor,p_org));
  if spent is null or spent<0 or spent+p_hold_cents>e.cogs_ceiling_cents then
    raise exception 'RP402: Workspace monthly processing budget would be exceeded';
  end if;
  if public.serving_mode()='ceiling' then perform public.library_serving_envelope_admit(p_org,public.library_actor_billing_org(p_actor,p_org),p_hold_cents,p_key);end if;
  insert into public.app_video_cost_reservations(org_id,actor_id,idempotency_key,feature,provider,model,
    input_sha256,units,unit_cost_cents,total_cents,hold_cents,meta)
  values(p_org,p_actor,p_key,p_feature,p_provider,p_model,p_input_sha256,p_units,p_unit_cost_cents,priced,p_hold_cents,p_meta)
  returning * into r;
  return jsonb_build_object('reserved',true,'id',r.id,'org_id',r.org_id,'key',r.idempotency_key,
    'hold_cents',r.hold_cents,'total_cents',r.total_cents);
end $function$
;

do $$begin if(select md5(prosrc) from pg_proc where oid='public.log_job_cost(uuid,uuid,text,text,text,numeric,numeric,jsonb,numeric)'::regprocedure)not in('aaf6c4140b810b764696c7cc19358185','af067453945a28bd6d59df9d5dcbc5ed')then raise exception 'Review changed function log_job_cost(uuid,uuid,text,text,text,numeric,numeric,jsonb,numeric)';end if;end$$;

CREATE OR REPLACE FUNCTION public.log_job_cost(p_job uuid, p_org uuid, p_feature text, p_provider text, p_model text, p_units numeric, p_unit_cost numeric, p_meta jsonb, p_cap_cents numeric)
 RETURNS numeric
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_total numeric;
  v_line numeric;
  v_org uuid := p_org;
  v_billing uuid;
  v_plan text;
  v_ceiling integer;
  v_month numeric;
begin
  perform 1 from render_jobs where id = p_job for update;
  if not found then raise exception 'RP404: render job not found'; end if;

  -- Resolve the org from the job when the caller didn't supply one, so the
  -- monthly ceiling can never be skipped by omitting org_id.
  if v_org is null then
    select l.org_id into v_org
      from render_jobs rj join listings l on l.id = rj.listing_id
     where rj.id = p_job;
  end if;

  select j.billing_org_id into v_billing from render_jobs j where j.id=p_job;
  if v_billing is null then raise exception 'RP503: Render financial identity is unavailable';end if;
  select coalesce(sum(total_cents), 0) into v_total from cost_ledger where job_id = p_job;
  v_line := round((coalesce(p_units, 1) * coalesce(p_unit_cost, 0))::numeric, 4);

  -- Per-job cap (unchanged).
  if v_total + v_line > p_cap_cents then
    raise exception 'RP402: cost cap exceeded — job at %¢, +%¢ would pass the %¢ cap', v_total, v_line, p_cap_cents;
  end if;

  -- Per-org MONTHLY ceiling.
  if v_org is not null then
    -- audit P0-3: serialize read+insert per org so two concurrent jobs can
    -- never both read the pre-spend total and both pass. Acquired BEFORE the
    -- sum below and held for the rest of this transaction (through the
    -- insert), so a second caller for the same org blocks here until the
    -- first caller's transaction actually completes, then sees the true,
    -- up-to-date total rather than a stale snapshot.
    perform pg_advisory_xact_lock(hashtextextended('org_month_spend:' || v_billing::text, 42));

    v_plan := effective_plan(v_billing);
    select cogs_ceiling_cents into v_ceiling from public.org_entitlement(v_billing);
    v_month := org_month_spend_cents(v_billing);
    if v_ceiling is not null and v_month + v_line > v_ceiling then
      raise exception
        'RP402: monthly AI spend ceiling reached for the % plan (%¢ of %¢) — upgrade or wait for the next cycle',
        v_plan, round(v_month), v_ceiling;
    end if;
  end if;

  insert into cost_ledger (job_id, org_id, billing_org_id, feature, provider, model, units, unit_cost_cents, total_cents, meta)
  values (p_job, v_org, v_billing, p_feature, p_provider, p_model, coalesce(p_units, 1), coalesce(p_unit_cost, 0), v_line, coalesce(p_meta, '{}'::jsonb));

  update render_jobs set cost_cents = round(v_total + v_line) where id = p_job;
  return v_total + v_line;
end;
$function$
;

do $$begin if(select md5(prosrc) from pg_proc where oid='public.serving_envelope_admit(uuid,numeric,text)'::regprocedure)not in('2bd8a27cd94f0d8740d3a65a5f9e7824','143bda8e2ec6b0f9e095d853c942640a')then raise exception 'Review changed function serving_envelope_admit(uuid,numeric,text)';end if;end$$;

CREATE OR REPLACE FUNCTION public.serving_envelope_admit(p_org uuid, p_hold_cents numeric, p_request_key text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare env jsonb;ceiling numeric;kind text;ps timestamptz;pe timestamptz;spent numeric;pre numeric;pool jsonb;pool_spent numeric;
begin
 if p_hold_cents is null or p_hold_cents<=0 then raise exception 'RP400: A positive hold is required';end if;
 perform pg_advisory_xact_lock(hashtextextended('org_month_spend:'||public.library_billing_org(p_org)::text,42));
 env:=public.plan_serving_ceiling(p_org);
 ceiling:=(env->>'ceiling_cents')::numeric;kind:=env->>'kind';ps:=(env->>'period_start')::timestamptz;pe:=(env->>'period_end')::timestamptz;
 if kind='sponsored' then return env||jsonb_build_object('spent_cents',0,'hold_cents',p_hold_cents);end if;
 spent:=public.serving_ceiling_spent_cents(p_org,ps,pe);
 -- The first serving reservation for an attempt that already holds money
 -- through the legacy video/erase writer replaces that hold rather than adding
 -- to it. Only net holds that `spent` still counts: once a live serving
 -- reservation exists for the key, spent has already excluded them.
 pre:=0;
 if p_request_key is not null and not exists(select 1 from public.serving_cost_reservations r
   where r.org_id=p_org and r.request_key=p_request_key and r.budget_source='ceiling' and r.ledger_id is null and r.state<>'rejected')then
  pre:=coalesce((select sum(v.hold_cents) from public.app_video_cost_reservations v where v.org_id=p_org and v.idempotency_key=p_request_key and v.cost_ledger_id is null and v.released_at is null
     and(ps is null or v.created_at>=ps)and(pe is null or v.created_at<pe)),0)
   +coalesce((select sum(j.cost_cents) from public.video_erase_jobs j where j.org_id=p_org and j.idempotency_key::text=p_request_key and j.provider='fal' and j.cost_ledger_id is null and j.cost_hold_released_at is null
     and(ps is null or j.created_at>=ps)and(pe is null or j.created_at<pe)),0);
 end if;
 spent:=greatest(0,spent-pre);
 if ceiling is null or spent+p_hold_cents>ceiling then
  raise exception 'RP402: AI usage limit reached [kind=%] (% of % cents this %)',kind,round(spent),coalesce(ceiling,0),case when ps is null then 'lifetime' else 'period' end;end if;
 if kind='trial' then
  perform pg_advisory_xact_lock(hashtextextended('serving:trial-sponsor',72452));
  pool:=public.trial_sponsor_pool();
  if pool is null or now()<(pool->>'starts_at')::timestamptz or now()>=(pool->>'ends_at')::timestamptz then raise exception 'RP402: Free-trial AI limit reached [pool=closed]';end if;
  pool_spent:=public.trial_sponsor_spent_cents();
  if pool_spent+p_hold_cents>(pool->>'cap_cents')::numeric then raise exception 'RP402: Free-trial AI limit reached [pool=cap]';end if;
 end if;
 return env||jsonb_build_object('spent_cents',spent,'hold_cents',p_hold_cents);
end$function$
;

do $$begin if(select md5(prosrc) from pg_proc where oid='public.serving_operation_begin(uuid,uuid,text,text,text)'::regprocedure)not in('606ac70efc8d9a43e601d68099b8349b','0426efff1d6ad4670b00f3c4b1a410fb')then raise exception 'Review changed function serving_operation_begin(uuid,uuid,text,text,text)';end if;end$$;

CREATE OR REPLACE FUNCTION public.serving_operation_begin(p_actor uuid, p_org uuid, p_key text, p_operation text, p_input_sha256 text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare prior public.serving_operations;saved jsonb;
begin
 if current_setting('role',true)is distinct from 'service_role'then raise insufficient_privilege;end if;
 if p_key is null or p_key !~ '^[A-Za-z0-9:_-]{8,128}$'or p_operation is null or length(p_operation)not between 1 and 200
  or p_input_sha256 is null or p_input_sha256 !~ '^[a-f0-9]{64}$'then raise exception 'RP400: A permanent operation identifier is required';end if;
 perform pg_advisory_xact_lock(hashtextextended('serving:'||p_org,72452));
 perform 1 from public.orgs where id=p_org and deleted_at is null for update;
 if not found or not public.library_financial_actor(p_actor,p_org)
  or (not exists(select 1 from auth.users where id=p_actor and is_anonymous is false) and not public.org_has_verified_retail_guest(p_actor,p_org))
  or exists(select 1 from public.deletion_requests where user_id=p_actor and status in('pending','processing'))then raise exception 'RP403: Current editor access is required';end if;
 select * into prior from public.serving_operations where org_id=p_org and actor_id=p_actor and request_key=p_key for update;
 if prior.org_id is not null then
  if prior.operation<>p_operation or prior.input_sha256<>p_input_sha256 then raise exception 'RP409: A request identifier cannot change its operation or inputs';end if;
  if prior.state='completed'then
   select result into saved from public.serving_operation_results where org_id=p_org and actor_id=p_actor and request_key=p_key;
   if saved is not null then return jsonb_build_object('begun',false,'replay',true,'result',saved);end if;
  end if;
  if prior.state='not_dispatched'and not exists(select 1 from public.serving_cost_reservations where org_id=p_org and actor_id=p_actor and request_key=p_key)then
   update public.serving_operations set state='started'where org_id=p_org and actor_id=p_actor and request_key=p_key;
   return jsonb_build_object('begun',true,'retry_after_no_dispatch',true);
  end if;
  raise exception 'RP409: This operation already started. Check its saved result or status before starting another';end if;
 insert into public.serving_operations(org_id,actor_id,request_key,operation,input_sha256)values(p_org,p_actor,p_key,p_operation,p_input_sha256);
 return jsonb_build_object('begun',true);
end$function$
;

do $$begin if(select md5(prosrc) from pg_proc where oid='public.serving_operation_complete(uuid,uuid,text,jsonb)'::regprocedure)not in('623d7c70efe002ddb3e17dd8c8bb74ad','af83eb2a66e122cf611890e9b82fb7b7')then raise exception 'Review changed function serving_operation_complete(uuid,uuid,text,jsonb)';end if;end$$;

CREATE OR REPLACE FUNCTION public.serving_operation_complete(p_actor uuid, p_org uuid, p_key text, p_result jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare prior public.serving_operations;saved jsonb;
begin
 if current_setting('role',true)is distinct from 'service_role'then raise insufficient_privilege;end if;
 if jsonb_typeof(p_result)is distinct from 'object'or octet_length(p_result::text)>262144 then raise exception 'RP400: A bounded generated result is required';end if;
 perform pg_advisory_xact_lock(hashtextextended('serving:'||p_org,72452));
 perform 1 from public.orgs where id=p_org and deleted_at is null for update;
 if not found or not public.library_financial_actor(p_actor,p_org)
  or (not exists(select 1 from auth.users where id=p_actor and is_anonymous is false) and not public.org_has_verified_retail_guest(p_actor,p_org))
  or exists(select 1 from public.deletion_requests where user_id=p_actor and status in('pending','processing'))then raise exception 'RP403: Current editor access is required';end if;
 select * into prior from public.serving_operations where org_id=p_org and actor_id=p_actor and request_key=p_key for update;
 if prior.org_id is null or prior.state='not_dispatched'then raise exception 'RP409: Generated result has no started operation';end if;
 if not exists(select 1 from public.serving_cost_reservations where org_id=p_org and actor_id=p_actor and request_key=p_key and state<>'rejected')then raise exception 'RP409: Generated result has no admitted provider attempt';end if;
 select result into saved from public.serving_operation_results where org_id=p_org and actor_id=p_actor and request_key=p_key;
 if saved is not null then
  if saved<>p_result then raise exception 'RP409: Generated result is immutable';end if;
  return jsonb_build_object('saved',true,'replay',true);
 end if;
 insert into public.serving_operation_results(org_id,actor_id,request_key,result)values(p_org,p_actor,p_key,p_result);
 update public.serving_operations set state='completed'where org_id=p_org and actor_id=p_actor and request_key=p_key;
 return jsonb_build_object('saved',true);
end$function$
;

do $$begin if(select md5(prosrc) from pg_proc where oid='public.serving_photo_package_context(uuid,uuid)'::regprocedure)not in('89267fc15e145628df46ae3bf935d0f8','b715c54a1fba7961e5389cc2c628d4e7')then raise exception 'Review changed function serving_photo_package_context(uuid,uuid)';end if;end$$;

CREATE OR REPLACE FUNCTION public.serving_photo_package_context(p_actor uuid, p_org uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare p public.serving_photo_partitions;f public.serving_funding;s public.serving_funding_slices;used integer;spent numeric;
begin
 if current_setting('role',true)is distinct from 'service_role'then raise insufficient_privilege;end if;
 if not exists(select 1 from public.orgs where id=p_org and deleted_at is null)
  or not public.library_financial_actor(p_actor,p_org)
  or(not exists(select 1 from auth.users where id=p_actor and is_anonymous is false)and not public.org_has_verified_retail_guest(p_actor,p_org))
  or exists(select 1 from public.deletion_requests where user_id=p_actor and status in('pending','processing'))then return null;end if;
 if public.org_has_internal_testing_grant(p_org)or public.org_has_private_internal_testing(p_org)then return null;end if;
 if not exists(select 1 from public.serving_photo_partitions package join public.serving_funding funding on funding.id=package.funding_id
  where package.org_id=p_org and package.starts_at<=now()and package.ends_at>now()and funding.revoked_at is null)then return null;end if;
 if(select count(*) from public.serving_funding where org_id=p_org and revoked_at is null and starts_at<=now()and ends_at>now())<>1
 then raise exception 'RP409: The configured package funding interval is ambiguous';end if;
 -- Same selected receipt/slice predicates as serving_cost_reserve. The exact
 -- one-row guards make selection independent of physical order or query plan.
 select funding.* into f from public.serving_funding funding where org_id=p_org and revoked_at is null and starts_at<=now()and ends_at>now();
 if f.source<>'retail'and f.actor_id is distinct from p_actor then return null;end if;
 if(select count(*) from public.serving_funding_slices where funding_id=f.id and starts_at<=now()and ends_at>now())<>1
 then raise exception 'RP409: The configured package service slice is ambiguous';end if;
 select * into s from public.serving_funding_slices where funding_id=f.id and starts_at<=now()and ends_at>now();
 select * into p from public.serving_photo_partitions where funding_id=s.funding_id and slice_index=s.slice_index and org_id=p_org;
 if not found then return null;end if;
 if row(p.starts_at,p.ends_at)is distinct from row(s.starts_at,s.ends_at)then raise exception 'RP409: The configured package interval was changed';end if;
 select count(*)into used from public.serving_photo_admissions where funding_id=p.funding_id and slice_index=p.slice_index;
 select coalesce(sum(hold_cents),0)into spent from public.serving_cost_reservations
  where funding_id=p.funding_id and slice_index=p.slice_index and state<>'rejected'
   and stage!~'^photo\.(twilight|sky|lawn|declutter|stage|custom):[01]$';
 return jsonb_build_object('org_id',p.org_id,'policy',p.policy,'tariff_version',p.tariff_version,'starts_at',p.starts_at,'ends_at',p.ends_at,
  'photo_admissions',jsonb_build_object('cap',p.photo_cap,'used',used,'remaining',greatest(0,p.photo_cap-used)),
  'photo_hold_cents',p.photo_hold_cents,'protected_photo_cents',p.protected_photo_cents,
  'other_ai',jsonb_build_object('cap_cents',p.other_ai_cents,'used_cents',ceil(spent)::bigint,'remaining_cents',greatest(0,floor(p.other_ai_cents-spent))::bigint));
end$function$
;

do $$begin if(select md5(prosrc) from pg_proc where oid='public.cancel_legacy_upload(uuid,uuid)'::regprocedure)not in('42c250a37abbb8708b0536aa23d9aac1','f34a39f8f1556f31bc75e0449e3bfdcd')then raise exception 'Review changed function cancel_legacy_upload(uuid,uuid)';end if;end$$;

CREATE OR REPLACE FUNCTION public.cancel_legacy_upload(p_asset uuid, p_actor uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO 'public'
AS $function$
declare a public.capture_assets; l public.listings; d date:=(clock_timestamp() at time zone 'UTC')::date; uid uuid:=gen_random_uuid();
begin
  perform public.upload_service_only();
  select * into l from listings where id=(select listing_id from capture_assets where id=p_asset) for update;
  select * into strict a from capture_assets where id=p_asset for update;
  if a.uploaded then raise exception 'RP409: completed upload cannot be cancelled'; end if;
  if a.transport_version=2 then return public.settle_upload_reservation(p_asset,false); end if;
  if not public.listing_content_access(p_actor,l.id,true) then
    raise exception 'RP403: legacy upload is not writable'; end if;
  insert into upload_budget_windows(org_id,day) values(l.org_id,d) on conflict do nothing;
  insert into upload_reservations(asset_id,org_id,listing_id,actor_id,day,spec,held_bytes,state,settled_at)
    values(a.id,l.org_id,l.id,p_actor,d,'{"legacy_physical_bytes":"unknown"}',0,'cancelled',clock_timestamp());
  insert into upload_operations(id,asset_id,kind,bucket,object_key,upload_id,bytes,expected_bytes,content_type,content_type_declared,asset_kind,state,claim,cleanup_after)
    values(uid,a.id,case when a.upload_id is null then 'single' else 'init' end,a.bucket,
      case when a.upload_id is null then '_staging/'||a.storage_key else a.storage_key end,a.upload_id,0,
      greatest(1,coalesce(a.bytes,1)),coalesce(a.content_type,'application/octet-stream'),coalesce(a.content_type_declared,false),
      a.kind,'uncertain',gen_random_uuid(),clock_timestamp()+interval '2 hours');
  update capture_assets set upload_aborted=true,idem_key=null,transport_version=2 where id=a.id returning * into a;
  return to_jsonb(a);
end $function$
;

do $$begin if(select md5(prosrc) from pg_proc where oid='public.reserve_upload_assets(uuid,jsonb)'::regprocedure)not in('ab8445b1c2c85848845b09a388b109c2','bf485a75663bd67d1ecb94d469b527b4')then raise exception 'Review changed function reserve_upload_assets(uuid,jsonb)';end if;end$$;

CREATE OR REPLACE FUNCTION public.reserve_upload_assets(p_actor uuid, p_assets jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO 'public'
AS $function$
declare
  s jsonb; a public.capture_assets; r public.upload_reservations; w public.upload_budget_windows;
  l public.listings; result jsonb := '[]'; n bigint; hold bigint; d date := (clock_timestamp() at time zone 'UTC')::date;
  spec jsonb; idem text; prefix text;
begin
  perform public.upload_service_only();
  if jsonb_typeof(p_assets) is distinct from 'array' or jsonb_array_length(p_assets) not between 1 and 200 then
    raise exception 'RP400: expected 1..200 assets';
  end if;
  perform 1 from public.orgs where id=(select org_id from public.listings where id=(p_assets->0->>'listing_id')::uuid)for update;
  select * into l from listings where id = (p_assets->0->>'listing_id')::uuid and deleted_at is null for update;
  if l.id is null or not exists (select 1 from orgs where id = l.org_id and deleted_at is null)
     or not public.listing_content_access(p_actor,l.id,true)
     or exists (select 1 from deletion_requests where user_id = p_actor and status <> 'completed') then
    raise exception 'RP403: upload workspace is not writable';
  end if;
  insert into upload_budget_windows(org_id,day) values(l.org_id,d) on conflict do nothing;
  select * into strict w from upload_budget_windows where org_id=l.org_id and day=d for update;
  for s in select value from jsonb_array_elements(p_assets) loop
    if (s->>'listing_id')::uuid <> l.id or jsonb_typeof(s->'bytes') is distinct from 'number'
       or (s->>'bytes')::numeric <> trunc((s->>'bytes')::numeric) then raise exception 'RP400: invalid asset identity/bytes'; end if;
    n := (s->>'bytes')::bigint;
    if n not between 1 and 12884901888 or s->>'kind' not in ('photo','video') or s->>'bucket' not in ('uploads','renders')
       or coalesce(s->>'content_type','') !~ '^[a-z0-9.+-]+/[a-z0-9.+-]+$' then raise exception 'RP400: invalid upload specification'; end if;
    if s->>'kind' = 'photo' and n > 52428800 then raise exception 'RP400: photo exceeds 50 MiB'; end if;
    if s->>'parts_total' is not null and (s->>'part_size' is null or (s->>'part_size')::bigint <> 33554432 or
       (s->>'parts_total')::integer <> ceil(n::numeric/33554432) or s->>'kind' <> 'video') then
      raise exception 'RP400: invalid bounded multipart shape';
    end if;
    if s->>'parts_total' is null and n > 67108864 then raise exception 'RP400: single upload exceeds 64 MiB'; end if;
    prefix := (s->>'bucket') || '/' || l.org_id || '/' || l.id || '/';
    if left(s->>'storage_key',length(prefix)) <> prefix or
       substring(s->>'storage_key' from length(prefix)+1) !~ ('^(original-|gallery-|contact-)?' || (s->>'id') || '\.[a-zA-Z0-9]{1,8}$') then
      raise exception 'RP400: invalid server-generated upload key';
    end if;
    if (s->>'kind'='video' and s->>'content_type' not in ('video/mp4','video/quicktime','video/x-m4v')) or
       (s->>'kind'='photo' and s->>'content_type' not in ('image/jpeg','image/png','image/webp','image/heic','image/heif')) or
       (s->>'kind'='photo' and s->>'bucket'='renders' and s->>'content_type' not in ('image/jpeg','image/png','image/webp')) or
       (s->>'kind'='photo' and s->>'bucket'='renders' and s->>'storage_key' not like '%/original-%' and n>10485760) then
      raise exception 'RP400: role-specific upload type or size denied';
    end if;
    idem := nullif(s->>'idem_key','');
    if idem is not null and length(idem) not between 8 and 128 then raise exception 'RP400: invalid idempotency key'; end if;
    -- Client computes this advisory digest asynchronously; it is not transport
    -- authority and may arrive on a later retry/complete request.
    if s->>'storage_key' like '%/contact-%' and (s->>'kind'<>'photo' or s->>'bucket'<>'renders') then raise exception 'RP400: client headshots must be public photos';end if;
    spec := s - array['id','storage_key','idem_key','sha256'];
    -- Role-bearing prefix is part of request identity, not just bucket/type.
    spec := spec || jsonb_build_object('key_role', case when s->>'storage_key' like '%/original-%' then 'original'
      when s->>'storage_key' like '%/gallery-%' then 'gallery' when s->>'storage_key' like '%/contact-%' then 'contact_photo' else 'default' end);
    a := null;
    if idem is not null then
      select * into a from capture_assets where listing_id=l.id and idem_key=idem and not uploaded and not upload_aborted;
    end if;
    if a.id is not null then
      select * into r from upload_reservations where asset_id=a.id;
      if r.asset_id is null or r.spec is distinct from spec or r.state <> 'open' or r.expires_at <= clock_timestamp() then
        raise exception 'RP409: idempotency key conflicts with an existing or expired upload';
      end if;
      result := result || jsonb_build_array(to_jsonb(a) || '{"replayed":true}'::jsonb);
      continue;
    end if;
    hold := n * case when s->>'parts_total' is null then 2 else 1 end;
    perform public.upload_new_admission(p_actor,l.org_id,hold);
    if w.tickets + 1 > 2000 or w.held_bytes + w.spent_bytes + hold > 214748364800 then
      raise exception 'RP429: daily physical upload reservation budget exhausted';
    end if;
    insert into capture_assets(id,listing_id,kind,bucket,storage_key,sha256,bytes,content_type,content_type_declared,
      part_size,parts_total,idem_key,transport_version)
      values ((s->>'id')::uuid,l.id,s->>'kind',s->>'bucket',s->>'storage_key',s->>'sha256',n,s->>'content_type',
        (s->>'content_type_declared')::boolean,(s->>'part_size')::bigint,(s->>'parts_total')::integer,idem,2)
      returning * into a;
    insert into upload_reservations(asset_id,org_id,listing_id,actor_id,day,spec,held_bytes)
      values(a.id,l.org_id,l.id,p_actor,d,spec,hold);
    w.tickets := w.tickets+1; w.held_bytes := w.held_bytes+hold;
    result := result || jsonb_build_array(to_jsonb(a) || '{"replayed":false}'::jsonb);
  end loop;
  update upload_budget_windows set tickets=w.tickets,held_bytes=w.held_bytes where org_id=l.org_id and day=d;
  return result;
end $function$
;

do $$begin if(select md5(prosrc) from pg_proc where oid='public.claim_upload_operation(uuid,uuid)'::regprocedure)not in('81338eb449729a86fc82b97ab664b2bf','ffcdbd6eebb25753a73bd448a96c8564')then raise exception 'Review changed function claim_upload_operation(uuid,uuid)';end if;end$$;

CREATE OR REPLACE FUNCTION public.claim_upload_operation(p_operation uuid, p_claim uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO 'public'
AS $function$
declare op public.upload_operations; a public.capture_assets; r public.upload_reservations;
begin
  perform public.upload_service_only();
  select * into strict op from upload_operations where id=p_operation;
  a:=public.lock_upload_asset(op.asset_id);
  select * into strict r from upload_reservations where asset_id=a.id for update;
  select * into strict op from upload_operations where id=p_operation for update;
  if op.state in ('stored','retained') and r.state <> 'cancelled' then return to_jsonb(op) || jsonb_build_object('dispatch',false); end if;
  if a.uploaded or a.upload_aborted or r.state <> 'open' or r.expires_at <= clock_timestamp()
     or op.expires_at <= clock_timestamp() or op.state <> 'planned' then raise exception 'RP503: transfer unavailable; recover or cancel, no new dispatch'; end if;
  if not exists (select 1 from listings where id=a.listing_id and org_id=r.org_id and deleted_at is null)
     or not exists (select 1 from orgs where id=r.org_id and deleted_at is null)
     or not public.listing_content_access(r.actor_id,r.listing_id,true)
     or exists (select 1 from deletion_requests where user_id=r.actor_id and status <> 'completed') then
    raise exception 'RP403: original upload authority no longer valid';
  end if;
  if p_claim is null or r.held_bytes < op.bytes then raise exception 'RP409: no held upload byte authority'; end if;
  update upload_budget_windows set held_bytes=held_bytes-op.bytes,spent_bytes=spent_bytes+op.bytes where org_id=r.org_id and day=r.day;
  update upload_reservations set held_bytes=held_bytes-op.bytes,spent_bytes=spent_bytes+op.bytes where asset_id=a.id;
  update upload_operations set state='dispatching',claim=p_claim,write_deadline=clock_timestamp()+interval '15 minutes'
    where id=op.id returning * into op;
  return to_jsonb(op) || jsonb_build_object('dispatch',true);
end $function$
;

do $$begin if(select md5(prosrc) from pg_proc where oid='public.settle_upload_reservation(uuid,boolean,uuid,jsonb)'::regprocedure)not in('bb001c386cfdfda482f7f866fc5033f0','61b54d9e84d089b9f71318a8f44dce94')then raise exception 'Review changed function settle_upload_reservation(uuid,boolean,uuid,jsonb)';end if;end$$;

CREATE OR REPLACE FUNCTION public.settle_upload_reservation(p_asset uuid, p_complete boolean, p_operation uuid DEFAULT NULL::uuid, p_metadata jsonb DEFAULT '{}'::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO 'public'
AS $function$
declare a public.capture_assets; r public.upload_reservations; op public.upload_operations; manifest jsonb;
begin
  a:=public.lock_upload_asset(p_asset);
  if p_complete is null or jsonb_typeof(p_metadata) is distinct from 'object' then raise exception 'RP400: invalid settlement'; end if;
  select * into strict r from upload_reservations where asset_id=a.id for update;
  if r.state <> 'open' then
    if (r.state='completed') <> p_complete then raise exception 'RP409: opposing terminal settlement'; end if;
    return to_jsonb(a);
  end if;
  if p_complete then
    if a.upload_aborted or r.expires_at <= clock_timestamp() then raise exception 'RP409: upload expired or cancelled'; end if;
    if not exists(select 1 from listings where id=a.listing_id and org_id=r.org_id and deleted_at is null)
       or not exists(select 1 from orgs where id=r.org_id and deleted_at is null)
       or not public.listing_content_access(r.actor_id,r.listing_id,true)
       or exists(select 1 from deletion_requests where user_id=r.actor_id and status <> 'completed') then
      raise exception 'RP403: original upload authority no longer valid';
    end if;
    if a.parts_total is null then
      select * into op from upload_operations where id=p_operation and asset_id=a.id and kind='copy' and state='stored' for update;
      if op.id is null then raise exception 'RP409: confirmed copy receipt required'; end if;
    else
      if not exists(select 1 from upload_operations where id=p_operation and asset_id=a.id and kind='assemble' and state='stored') then
        raise exception 'RP409: confirmed assembly receipt required';
      end if;
      select jsonb_agg(jsonb_build_object('number',part,'etag',etag) order by part) into manifest
        from upload_operations where asset_id=a.id and kind='part' and state='stored';
      if manifest is null or jsonb_array_length(manifest)<>a.parts_total or manifest is distinct from a.completion_parts then
        raise exception 'RP409: multipart publication requires every confirmed transfer receipt';
      end if;
    end if;
    update capture_assets set uploaded=true,upload_id=null,storage_key=coalesce(op.object_key,storage_key),
      duration_s=coalesce((p_metadata->>'duration_s')::numeric,duration_s),fps=coalesce((p_metadata->>'fps')::numeric,fps),
      width=coalesce((p_metadata->>'width')::integer,width),height=coalesce((p_metadata->>'height')::integer,height),
      content_type=coalesce(op.content_type,content_type),
      sha256=coalesce(p_metadata->>'sha256',sha256),
      codec=coalesce(p_metadata->>'codec',codec),is_drone=coalesce((p_metadata->>'is_drone')::boolean,is_drone),
      has_gyro=coalesce((p_metadata->>'has_gyro')::boolean,has_gyro)
      where id=a.id returning * into a;
    update upload_operations set state='retained',cleanup_after=null where asset_id=a.id and
      ((kind='copy' and id=p_operation) or (a.parts_total is not null and kind in ('init','part','assemble')));
  else
    if a.uploaded then raise exception 'RP409: completed upload cannot be cancelled'; end if;
    update capture_assets set upload_aborted=true,idem_key=null where id=a.id returning * into a;
  end if;
  update upload_budget_windows set held_bytes=held_bytes-r.held_bytes where org_id=r.org_id and day=r.day;
  update upload_reservations set held_bytes=0,state=case when p_complete then 'completed' else 'cancelled' end,
    settled_at=clock_timestamp() where asset_id=a.id;
  update upload_operations set cleanup_after=greatest(clock_timestamp(),coalesce(write_deadline,clock_timestamp()))+interval '1 hour'
    where asset_id=a.id and state<>'retained' and kind not in ('part','assemble');
  return to_jsonb(a);
end $function$
;

do $$begin if(select md5(prosrc) from pg_proc where oid='public.save_listing_facts(uuid,uuid,uuid,jsonb,jsonb,jsonb,jsonb)'::regprocedure)not in('79b9931a7ee69d46436a80304145cacb','55f233f7b32a3b50f6b01504499e30ba')then raise exception 'Review changed function save_listing_facts(uuid,uuid,uuid,jsonb,jsonb,jsonb,jsonb)';end if;end$$;

CREATE OR REPLACE FUNCTION public.save_listing_facts(p_actor uuid, p_org uuid, p_listing uuid, p_expected jsonb, p_changes jsonb, p_details_expected jsonb, p_details_changes jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare
 l public.listings; old_row jsonb; d jsonb; k text; desired jsonb; expected jsonb; actual jsonb;
 field_keys text[]:=array['space_type','address','tagline','beds','baths','sqft','price_cents','zillow_url','lat','lng','sold_at','status'];
 detail_keys text[]:=array['allow_indexing','capacitySeated','capacityStanding','startingPrice','eventTypes','catering','spaceSetting','amenities','bookingUrl','cuisineType','priceRange','hours','reservationUrl','menuUrl','phone','storeCategory','onlineStoreUrl','weeklySpecial','shoppingOptions','departments','facilityType','membershipPrice','dayPassPrice','is247','freeTrialOffer','website','nearbyAttractions'];
 current_matches boolean; desired_matches boolean;
begin
 perform public.upload_service_only();
 if p_actor is null or p_org is null or p_listing is null then
  raise exception 'Choose an account, workspace and listing' using errcode='22023'; end if;
 perform 1 from public.orgs where id=p_org and deleted_at is null for update;
 select * into l from public.listings where id=p_listing and org_id=p_org and deleted_at is null for update;
 if l.id is null then raise exception 'Listing not found' using errcode='P0002'; end if;
 if not exists(select 1 from public.orgs where id=p_org and deleted_at is null)
  or not public.listing_content_access(p_actor,p_listing,true)
  or exists(select 1 from public.deletion_requests where user_id=p_actor and status<>'completed') then
  raise exception 'Workspace is not writable' using errcode='42501'; end if;
 if pg_catalog.jsonb_typeof(p_expected) is distinct from 'object'
  or pg_catalog.jsonb_typeof(p_changes) is distinct from 'object'
  or pg_catalog.jsonb_typeof(p_details_expected) is distinct from 'object'
  or pg_catalog.jsonb_typeof(p_details_changes) is distinct from 'object'
  or (p_changes='{}'::jsonb and p_details_changes='{}'::jsonb)
  or pg_catalog.octet_length(p_expected::text||p_changes::text||p_details_expected::text||p_details_changes::text)>45000 then
  raise exception 'Invalid explicit listing edit' using errcode='22023'; end if;
 if (select array_agg(key order by key) from pg_catalog.jsonb_each(p_expected)) is distinct from
    (select array_agg(key order by key) from pg_catalog.jsonb_each(p_changes))
  or (select array_agg(key order by key) from pg_catalog.jsonb_each(p_details_expected)) is distinct from
    (select array_agg(key order by key) from pg_catalog.jsonb_each(p_details_changes)) then
  raise exception 'Every edit needs its cached value' using errcode='22023'; end if;
 if (p_changes ? 'lat') is distinct from (p_changes ? 'lng')
  or ((p_changes ? 'lat') and ((p_changes->'lat'='null'::jsonb) is distinct from (p_changes->'lng'='null'::jsonb))) then
  raise exception 'Save both coordinates together' using errcode='22023'; end if;
 old_row:=pg_catalog.to_jsonb(l); d:=coalesce(l.details,'{}');
 for k,desired in select key,value from pg_catalog.jsonb_each(p_changes) loop
  if not k=any(field_keys) then raise exception 'Unsupported listing field' using errcode='22023'; end if;
  expected:=p_expected->k; actual:=coalesce(old_row->k,'null'::jsonb);
  if desired<>'null'::jsonb then
   if k in('beds','baths','sqft','price_cents','lat','lng') then
    if pg_catalog.jsonb_typeof(desired)<>'number' then raise exception 'Invalid number' using errcode='22023'; end if;
    if k in('beds','sqft','price_cents') and ((desired#>>'{}')::numeric<0 or trunc((desired#>>'{}')::numeric)<>(desired#>>'{}')::numeric) then
     raise exception 'Invalid non-negative integer' using errcode='22023'; end if;
    if k='baths' and ((desired#>>'{}')::numeric<0 or (desired#>>'{}')::numeric>99
     or round((desired#>>'{}')::numeric,1)<>(desired#>>'{}')::numeric) then
     raise exception 'Bathrooms must use tenths' using errcode='22023'; end if;
    if k in('lat','lng') and (abs((desired#>>'{}')::numeric)>case when k='lat' then 90 else 180 end
     or round((desired#>>'{}')::numeric,3)<>(desired#>>'{}')::numeric) then
     raise exception 'Invalid coarse coordinate' using errcode='22023'; end if;
   elsif pg_catalog.jsonb_typeof(desired)<>'string' or length(desired#>>'{}')>500 then
    raise exception 'Invalid listing text' using errcode='22023'; end if;
  end if;
  if k='space_type' and (desired='null'::jsonb or desired#>>'{}' not in('real_estate','venue','restaurant','retail','fitness','other')) then
   raise exception 'Invalid business type' using errcode='22023'; end if;
  if k='status' and (desired='null'::jsonb or desired#>>'{}' not in('draft','capturing','uploading','processing','ready','expired','archived')) then
   raise exception 'Invalid listing status' using errcode='22023'; end if;
  if k='sold_at' then
   current_matches:= (actual#>>'{}')::timestamptz is not distinct from (expected#>>'{}')::timestamptz;
   desired_matches:= (actual#>>'{}')::timestamptz is not distinct from (desired#>>'{}')::timestamptz;
  else current_matches:=actual=expected; desired_matches:=actual=desired; end if;
  if not current_matches and not desired_matches then
   raise exception 'Listing details changed elsewhere' using errcode='PT409'; end if;
 end loop;
 for k,desired in select key,value from pg_catalog.jsonb_each(p_details_changes) loop
  if not k=any(detail_keys) or (desired<>'null'::jsonb and pg_catalog.jsonb_typeof(desired)<>'string') then
   raise exception 'Unsupported detail edit' using errcode='22023'; end if;
  if k='nearbyAttractions' and desired<>'null'::jsonb and length(desired#>>'{}')>500 then
   raise exception 'Nearby-place note is too long' using errcode='22023'; end if;
  expected:=p_details_expected->k; actual:=d->k;
  if pg_catalog.jsonb_typeof(expected) is distinct from 'object'
   or pg_catalog.jsonb_typeof(expected->'present') is distinct from 'boolean'
   or not(expected ? 'value') or (select count(*) from pg_catalog.jsonb_object_keys(expected))<>2 then
   raise exception 'Every detail edit needs its cached presence and value' using errcode='22023'; end if;
  current_matches:=case when expected->'present'='false'::jsonb then not(d ? k) else (d ? k) and actual=expected->'value' end;
  desired_matches:=case when desired='null'::jsonb then not(d ? k) else actual=desired end;
  if not coalesce(current_matches,false) and not coalesce(desired_matches,false) then
   raise exception 'Listing details changed elsewhere' using errcode='PT409'; end if;
  if desired='null'::jsonb then d:=d-k; else d:=d||pg_catalog.jsonb_build_object(k,desired); end if;
 end loop;
 if pg_catalog.octet_length(d::text)>16000 then raise exception 'Listing details too large' using errcode='22023'; end if;
 update public.listings set
  space_type=case when p_changes ? 'space_type' then p_changes->>'space_type' else l.space_type end,
  address=case when p_changes ? 'address' then p_changes->>'address' else l.address end,
  tagline=case when p_changes ? 'tagline' then p_changes->>'tagline' else l.tagline end,
  beds=case when p_changes ? 'beds' then (p_changes->>'beds')::smallint else l.beds end,
  baths=case when p_changes ? 'baths' then (p_changes->>'baths')::numeric else l.baths end,
  sqft=case when p_changes ? 'sqft' then (p_changes->>'sqft')::integer else l.sqft end,
  price_cents=case when p_changes ? 'price_cents' then (p_changes->>'price_cents')::bigint else l.price_cents end,
  zillow_url=case when p_changes ? 'zillow_url' then p_changes->>'zillow_url' else l.zillow_url end,
  lat=case when p_changes ? 'lat' then (p_changes->>'lat')::double precision else l.lat end,
  lng=case when p_changes ? 'lng' then (p_changes->>'lng')::double precision else l.lng end,
  sold_at=case when p_changes ? 'sold_at' then (p_changes->>'sold_at')::timestamptz else l.sold_at end,
  status=case when p_changes ? 'status' then p_changes->>'status' else l.status end,
  details=d where id=p_listing returning * into l;
 return pg_catalog.to_jsonb(l);
end $function$
;

do $$begin if(select md5(prosrc) from pg_proc where oid='public.save_listing_measurements(uuid,uuid,uuid,text,text)'::regprocedure)not in('18d0428995631a94c5506d8b8c14eee6','e140b8cbb7c6ed4bfaad6848678c0af9')then raise exception 'Review changed function save_listing_measurements(uuid,uuid,uuid,text,text)';end if;end$$;

CREATE OR REPLACE FUNCTION public.save_listing_measurements(p_actor uuid, p_org uuid, p_listing uuid, p_expected text, p_value text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare l public.listings; d jsonb; vals text[]; current_plan text; previous_setting text;
begin
 perform public.upload_service_only();
 perform 1 from public.orgs where id=p_org and deleted_at is null for update;
 select * into l from public.listings where id=p_listing and org_id=p_org and deleted_at is null for update;
 if l.id is null then raise exception 'Listing not found' using errcode='P0002'; end if;
 if not exists(select 1 from public.orgs where id=p_org and deleted_at is null)
  or not public.listing_content_access(p_actor,p_listing,true)
  or exists(select 1 from public.deletion_requests where user_id=p_actor and status<>'completed') then
  raise exception 'Workspace is not writable' using errcode='42501';
 end if;
 if p_value is null or pg_catalog.octet_length(p_value)>10000 then
  raise exception 'Invalid measurement size' using errcode='22023';
 end if;
 d:=p_value::jsonb;
 if pg_catalog.jsonb_typeof(d)<>'object' or pg_catalog.jsonb_typeof(d->'version') is distinct from 'number'
  or (d->>'version') is null or d->>'version' not in('1','2')
  or pg_catalog.jsonb_typeof(d->'rooms') is distinct from 'array'
  or pg_catalog.jsonb_array_length(d->'rooms')>24 then
  raise exception 'Invalid measurement plan' using errcode='22023';
 end if;
 if coalesce(d->>'unit','') not in('feet','meters')
  or pg_catalog.jsonb_typeof(d->'updatedAt') is distinct from 'number' then
  raise exception 'Invalid measurement metadata' using errcode='22023';
 end if;
 if d->>'version'='2' and (pg_catalog.jsonb_typeof(d->'outlines') is distinct from 'array'
  or pg_catalog.jsonb_array_length(d->'outlines')>12) then
  raise exception 'Invalid measurement outlines' using errcode='22023';
 end if;
 d:=public.canonical_measurement_details(l.details);
 select array_agg(distinct value) into vals from pg_catalog.jsonb_each_text(d)
  where pg_catalog.replace(pg_catalog.lower(key),'_','')='floormeasurementsv1';
 if pg_catalog.cardinality(vals)>1 then raise exception 'Conflicting legacy plans' using errcode='PT409'; end if;
 current_plan:=d->>'floor_measurements_v1';
 -- A response can be lost after commit. An identical retry is already saved.
 if current_plan is not distinct from p_value then return pg_catalog.to_jsonb(l); end if;
 if current_plan is distinct from p_expected then
  raise exception 'Measurements changed elsewhere' using errcode='PT409';
 end if;
 d:=d||pg_catalog.jsonb_build_object('floor_measurements_v1',p_value);
 if pg_catalog.octet_length(d::text)>16000 then raise exception 'Listing details too large' using errcode='22023'; end if;
 previous_setting:=pg_catalog.current_setting('rendprop.measurement_cas',true);
 perform pg_catalog.set_config('rendprop.measurement_cas','allowed',true);
 update public.listings set details=d where id=p_listing returning * into l;
 perform pg_catalog.set_config('rendprop.measurement_cas',coalesce(previous_setting,''),true);
 return pg_catalog.to_jsonb(l);
end $function$
;

do $$begin if(select md5(prosrc) from pg_proc where oid='public.studio_property_music_attach(uuid,uuid,uuid,text)'::regprocedure)not in('12d6d256dc7b0d1cad85b7fed7b0b571','cecf705d7e8d7851b55d97f7813d6c2e')then raise exception 'Review changed function studio_property_music_attach(uuid,uuid,uuid,text)';end if;end$$;

CREATE OR REPLACE FUNCTION public.studio_property_music_attach(p_actor uuid, p_org uuid, p_listing uuid, p_sha256 text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare r public.studio_project_media%rowtype; existing public.studio_property_music%rowtype;
begin
 if current_setting('role',true) is distinct from 'service_role' then raise insufficient_privilege using message='service role required';end if;
 if p_sha256 is null or p_sha256 !~ '^[0-9a-f]{64}$' then raise exception 'RP400: Choose a saved music source';end if;
 perform 1 from auth.users where id=p_actor for update;
 if not found then raise exception 'RP403: Account unavailable';end if;
 perform 1 from public.orgs where id=p_org and deleted_at is null for update;
 if not found or exists(select 1 from public.deletion_requests where user_id=p_actor and status<>'completed')
  or not public.listing_content_access(p_actor,p_listing,true)
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
end $function$
;

do $$begin if(select md5(prosrc) from pg_proc where oid='public.studio_photo_authority(uuid,uuid,uuid)'::regprocedure)not in('5c0921d258a7fcc6cb7f99854894c276','0af34e80d0f347c5aad1847844a0c798')then raise exception 'Review changed function studio_photo_authority(uuid,uuid,uuid)';end if;end$$;

CREATE OR REPLACE FUNCTION public.studio_photo_authority(p_actor uuid, p_org uuid, p_listing uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
begin
 if current_setting('role',true)is distinct from 'service_role'then
  raise insufficient_privilege using message='service role required';end if;
 perform 1 from public.profiles where id=p_actor for update;
 if not found or not exists(select 1 from auth.users where id=p_actor and is_anonymous is false)then
  raise exception 'RP403: A current signed-in account is required to edit photos';end if;
 if exists(select 1 from public.deletion_requests where user_id=p_actor and status in('pending','processing'))then
  raise exception 'RP409: This account is being deleted';end if;
 perform 1 from public.orgs where id=p_org and deleted_at is null for update;
 if not found then raise exception 'RP404: Property not found';end if;
 perform 1 from public.listings where id=p_listing and org_id=p_org and deleted_at is null for update;
 if not found then raise exception 'RP404: Property not found';end if;
 perform 1 where public.listing_content_access(p_actor,p_listing,true);
 if not found then raise exception 'RP403: Your role does not permit editing photos';end if;
end$function$
;

do $$begin if(select md5(prosrc) from pg_proc where oid='public.studio_attach_floorplan(uuid,uuid,uuid,uuid,jsonb,text)'::regprocedure)not in('9afe2477225c8f16a83a66fe47363d5e','87f462a38ec7de314ae32e111b086243')then raise exception 'Review changed function studio_attach_floorplan(uuid,uuid,uuid,uuid,jsonb,text)';end if;end$$;

CREATE OR REPLACE FUNCTION public.studio_attach_floorplan(p_actor uuid, p_org uuid, p_listing uuid, p_asset uuid, p_expected jsonb, p_url text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare l public.listings; a public.capture_assets; next_details jsonb;
begin
 perform public.upload_service_only();
 if p_actor is null or p_org is null or p_listing is null or p_asset is null
  or pg_catalog.jsonb_typeof(p_expected) is distinct from 'object' then
  raise exception 'Invalid floor plan attachment' using errcode='22023'; end if;
 -- Deletion/adoption locks profiles before orgs. Keep the same order and hold
 -- the actor/membership/asset proofs until this transaction completes.
 perform 1 from public.profiles where id=p_actor for share;
 if not found then raise exception 'Workspace is not writable' using errcode='42501'; end if;
 perform 1 from public.orgs where id=p_org and deleted_at is null for update;
 if not found then raise exception 'Workspace is not writable' using errcode='42501'; end if;
 perform 1 where public.listing_content_access(p_actor,p_listing,true);
 if not found or exists(select 1 from public.deletion_requests where user_id=p_actor and status<>'completed') then
  raise exception 'Workspace is not writable' using errcode='42501'; end if;
 select * into l from public.listings where id=p_listing and org_id=p_org and deleted_at is null for update;
 if not found then raise exception 'Listing not found' using errcode='P0002'; end if;
 select * into a from public.capture_assets where id=p_asset and listing_id=p_listing for share;
 if not found or a.kind is distinct from 'photo' or a.bucket is distinct from 'renders' or a.uploaded is distinct from true
  or a.content_type is null or a.content_type not in('image/jpeg','image/png','image/webp')
  or a.storage_key not like 'renders/'||p_org::text||'/'||p_listing::text||'/%'
  or length(a.storage_key)>=1024 or a.storage_key like '%..%' or a.storage_key ~ '[?#]'
  or a.storage_key like '%/contact-%' then
  raise exception 'Choose an uploaded floor plan from this listing' using errcode='22023'; end if;
 if p_url is null or length(p_url)>4096 or p_url !~ '^https://[^/?#@]+/' or p_url ~ '[?#]'
  or right(p_url,length(a.storage_key)+1) is distinct from '/'||a.storage_key then
  raise exception 'Invalid canonical floor plan URL' using errcode='22023'; end if;
 if l.details is distinct from p_expected then
  raise exception 'Listing details changed elsewhere' using errcode='PT409'; end if;
 next_details:=l.details||pg_catalog.jsonb_build_object('floorplan_url',p_url,'floorplan_asset_id',a.id);
 if pg_catalog.octet_length(next_details::text)>16000 then
  raise exception 'Listing details too large' using errcode='22023'; end if;
 update public.listings set details=next_details where id=p_listing returning * into l;
 return pg_catalog.jsonb_build_object('id',l.id,'details',l.details);
end $function$
;

do $$begin if(select md5(prosrc) from pg_proc where oid='public.reserve_voice_storage(uuid,uuid,uuid,uuid)'::regprocedure)not in('69a0bef2c154e3fa36a7d1465e32b068','c193eecec0af28b4177df44ec1d902ce')then raise exception 'Review changed function reserve_voice_storage(uuid,uuid,uuid,uuid)';end if;end$$;

CREATE OR REPLACE FUNCTION public.reserve_voice_storage(p_actor uuid, p_org uuid, p_id uuid, p_listing uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare reservation public.voice_storage_reservations%rowtype; reserved_at timestamptz;
begin
  if current_setting('role',true) is distinct from 'service_role' then
    raise insufficient_privilege using message='service role required';
  end if;
  if p_actor is null or p_org is null or p_id is null then
    raise exception 'RP400: invalid voice storage scope';
  end if;
  -- Match prepare_account_deletion's parent-lock order. Deletion cannot capture
  -- an empty inventory while this transaction reserves a future audio write.
  perform 1 from auth.users where id=p_actor for update;
  if not found then raise exception 'RP401: account no longer exists';end if;
  perform 1 from public.orgs where id=p_org and deleted_at is null for update;
  if not found then raise exception 'RP404: voice workspace unavailable';end if;
  if exists(select 1 from public.deletion_requests where user_id=p_actor and status<>'completed') then
    raise exception 'RP409: account deletion is in progress';
  end if;
  if not (case when p_listing is null then public.library_content_access(p_actor,p_org,true)else public.listing_content_access(p_actor,p_listing,true)end) then
    raise exception 'RP403: workspace does not permit voice generation';
  end if;
  if p_listing is not null then
    perform 1 from public.listings where id=p_listing and org_id=p_org and deleted_at is null for key share;
    if not found then raise exception 'RP404: voice listing unavailable';end if;
  end if;
  reserved_at:=clock_timestamp();
  insert into public.voice_storage_reservations(id,actor_id,org_id,listing_id,storage_key,created_at,write_deadline)
    values(p_id,p_actor,p_org,p_listing,'ai-voice/'||p_org::text||'/'||p_id::text||'.mp3',reserved_at,reserved_at+interval '15 minutes')
    on conflict(id) do nothing;
  select * into strict reservation from public.voice_storage_reservations where id=p_id for update;
  if reservation.actor_id<>p_actor or reservation.org_id<>p_org or reservation.listing_id is distinct from p_listing then
    raise exception 'RP409: voice storage reservation belongs to another request';
  end if;
  if reservation.write_deadline<=clock_timestamp() then
    raise exception 'RP409: voice storage reservation expired';
  end if;
  return jsonb_build_object('reservation_id',reservation.id,'key',reservation.storage_key,'write_deadline',reservation.write_deadline);
end;
$function$
;

do $$begin if(select md5(prosrc) from pg_proc where oid='public.studio_save_project(uuid,uuid,text,uuid,integer,jsonb)'::regprocedure)not in('9d811a8785da15a3aff9032d96426e67','ea912c6750db393eeba46fb273c3a571')then raise exception 'Review changed function studio_save_project(uuid,uuid,text,uuid,integer,jsonb)';end if;end$$;

CREATE OR REPLACE FUNCTION public.studio_save_project(p_actor uuid, p_org_id uuid, p_key text, p_listing_id uuid, p_expected integer, p_payload jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare v_doc public.studio_documents%rowtype;
begin
 if current_setting('role',true) is distinct from 'service_role' then raise insufficient_privilege using message='service role required';end if;
 if p_actor is null or p_org_id is null or p_key is null or p_key !~ '^project:[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' or p_expected is null or p_expected < 0 or p_expected >= 2147483647 then raise exception 'RP400: Choose a valid project revision'; end if;
 perform 1 from auth.users where id=p_actor for update;
 if not found then raise exception 'RP403: Account unavailable';end if;
 perform 1 from public.orgs where id=p_org_id and deleted_at is null for update;
 if not found then raise exception 'RP403: Workspace unavailable';end if;
 perform pg_advisory_xact_lock(hashtextextended(p_actor::text||':'||p_org_id::text||':projects',0));
 if not (case when p_listing_id is null then public.library_content_access(p_actor,p_org_id,true)else public.listing_content_access(p_actor,p_listing_id,true)end)
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
end $function$
;

do $$begin if(select md5(prosrc) from pg_proc where oid='public.studio_project_media_write(uuid,uuid,uuid,text,jsonb)'::regprocedure)not in('8254745696afa8e3fcbc0a7d194cf026','aa615460e48ca10c78fe5149740c923e')then raise exception 'Review changed function studio_project_media_write(uuid,uuid,uuid,text,jsonb)';end if;end$$;

CREATE OR REPLACE FUNCTION public.studio_project_media_write(p_actor uuid, p_org uuid, p_id uuid, p_action text, p_data jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare r public.studio_project_media%rowtype; part integer; receipt jsonb; expected integer; attempts integer;
begin
 if current_setting('role',true) is distinct from 'service_role' then raise insufficient_privilege using message='service role required';end if;
 if p_actor is null or p_org is null or p_id is null or p_action is null or p_action not in('reserve','read','inspect','claim','finish') then raise exception 'RP400: Invalid media action';end if;
 perform 1 from auth.users where id=p_actor for update;
 if not found then raise exception 'RP403: Account unavailable';end if;
 perform 1 from public.orgs where id=p_org and deleted_at is null for update;
 if not found or exists(select 1 from public.deletion_requests where user_id=p_actor and status<>'completed') or not public.library_content_access(p_actor,p_org,p_action<>'read') then raise exception 'RP403: Workspace cannot access media';end if;
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
end $function$
;

do $$begin if(select md5(prosrc) from pg_proc where oid='public.create_render_job(uuid,uuid,text,jsonb,text,text)'::regprocedure)not in('86848079316df105dc8db6f6e1fbfb06','bf33e3111e92ceb230cd8b3e3cb85787')then raise exception 'Review changed function create_render_job(uuid,uuid,text,jsonb,text,text)';end if;end$$;

CREATE OR REPLACE FUNCTION public.create_render_job(p_listing uuid, p_asset uuid, p_tier text DEFAULT 'smooth'::text, p_enhancements jsonb DEFAULT '{}'::jsonb, p_idem text DEFAULT NULL::text, p_source text DEFAULT 'worker'::text)
 RETURNS render_jobs
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_org uuid;
  v_billing uuid;
  v_role text;
  v_plan text;
  v_cap integer;
  v_used integer;
  v_active integer;
  v_recent integer;
  v_job render_jobs;
  v_asset capture_assets;
  v_source text := coalesce(nullif(trim(p_source), ''), 'worker');
  v_idem text := case when p_idem is not null and length(p_idem) between 8 and 128 then p_idem else null end;
begin
  if v_source not in ('worker','app') then
    raise exception 'RP400: source must be worker or app';
  end if;

  select l.org_id into v_org from listings l where l.id = p_listing and l.deleted_at is null;
  if v_org is null then raise exception 'RP404: listing not found'; end if;

  -- Role, not just membership: marketing is read-only on product data and must
  -- not be able to spend the workspace's paid render entitlement.
  v_role := public.library_scope_role(auth.uid(),v_org,p_listing);
  if v_role is null then raise exception 'RP403: not a member of this workspace'; end if;
  if v_role not in ('owner','admin','agent') then
    raise exception 'RP403: your role does not permit creating renders';
  end if;

  -- The asset must exist for this listing AND actually be uploaded (audit:
  -- creating a job for an unuploaded asset burned entitlement, then failed).
  select a.* into v_asset from capture_assets a
    where a.id = p_asset and a.listing_id = p_listing and a.uploaded is true;
  if not found then
    raise exception 'RP409: asset not found for this listing, or its upload is not complete';
  end if;
  -- An app publish must point at a role=render upload; checking here (not only
  -- in publish_render) means a bad asset fails BEFORE a job row exists.
  if v_source = 'app' then
    if coalesce(v_asset.bucket, 'uploads') <> 'renders' then
      raise exception 'RP400: an app publish must reference a role=render upload (renders bucket)';
    end if;
    if v_asset.kind <> 'video' then
      raise exception 'RP400: the publish asset must be a video';
    end if;
  end if;

  if p_tier not in ('smooth','premium4k','cinematic') then
    raise exception 'RP400: tier must be smooth, premium4k, or cinematic';
  end if;

  if not public.studio_presenter_media_access(p_asset) then raise exception 'RP409: Presenter source approval is no longer available'; end if;
  -- Fast path: an already-recorded idempotent replay.
  if v_idem is not null then
    select rj.* into v_job from render_jobs rj
      where rj.listing_id = p_listing and rj.idem_key = v_idem;
    if found then return v_job; end if;
  end if;

  v_billing:=public.library_billing_org(public.listing_owner_library(p_listing));
  perform 1 from public.orgs where id=v_billing and deleted_at is null for update;
  if not found then raise exception 'RP403: Current render allowance unavailable';end if;
  -- Serialize job creation per org so caps can't be raced past.
  perform pg_advisory_xact_lock(hashtextextended('render_jobs:' || v_billing::text, 42));

  -- RE-CHECK after the lock: a concurrent caller with the same key may have
  -- inserted while we waited (audit: the loser hit the unique index).
  if v_idem is not null then
    select rj.* into v_job from render_jobs rj
      where rj.listing_id = p_listing and rj.idem_key = v_idem;
    if found then return v_job; end if;
  end if;

  -- Self-heal: an app-source job that never reached publish_render (a crash
  -- between the two RPCs) is dead after an hour. Mark it failed so it can never
  -- be mistaken for in-flight work by anything that lists this org's jobs.
  update render_jobs rj
     set status = 'failed',
         finished_at = now(),
         error = coalesce(rj.error, '{}'::jsonb)
                 || jsonb_build_object('message', 'publish did not complete', 'code', 'stale_app_job')
    from listings l
   where l.id = rj.listing_id and l.org_id = v_org
     and rj.source = 'app' and rj.status = 'created'
     and rj.created_at < now() - interval '1 hour';

  if v_source = 'worker' then
    -- In-flight guard counts ONLY worker jobs: app jobs are transient (created →
    -- ready in the same request) and must never lock a workspace (F-supabase-05).
    select count(*) into v_active
      from render_jobs rj join listings l on l.id = rj.listing_id
      where rj.billing_org_id=v_billing and rj.source = 'worker'
        and (
          rj.status in ('created','queued','claimed')
          or (rj.status = 'processing'
              and (rj.lease_expires_at is null or rj.lease_expires_at > now()))
        );
    if v_active >= 3 then
      raise exception 'RP429: this workspace already has % renders in flight — wait for one to finish', v_active;
    end if;

    -- Monthly cap from org_entitlement() — plan_entitlements via effective_plan()
    -- (an expired trial is `free` here exactly as it is for the AI routes),
    -- coalesced against the org's industry override (0044: the single-location
    -- free week). App publishes are excluded from the count: pricing promises
    -- publishing is free.
    v_plan := coalesce(effective_plan(v_billing), 'free');
    select renders_per_month into v_cap from public.org_entitlement(v_billing);
    v_cap := coalesce(v_cap, 0);
    select count(*) into v_used
      from render_jobs rj join listings l on l.id = rj.listing_id
      where rj.billing_org_id=v_billing and rj.source = 'worker'
        and rj.created_at >= date_trunc('month', now());
    if v_used >= v_cap then
      raise exception 'RP402: monthly render limit reached for the % plan (% of %)', v_plan, v_used, v_cap;
    end if;
  else
    -- Free, but not unbounded: a runaway client loop must not mint slugs forever.
    select count(*) into v_recent
      from render_jobs rj join listings l on l.id = rj.listing_id
      where rj.billing_org_id=v_billing and rj.source = 'app'
        and rj.created_at >= now() - interval '1 hour';
    if v_recent >= 60 then
      raise exception 'RP429: too many publishes in the last hour for this workspace — try again later';
    end if;
  end if;

  insert into render_jobs (listing_id, capture_asset_id, billing_org_id, tier, enhancements, status, progress, idem_key, source)
  values (p_listing, p_asset, v_billing, p_tier, coalesce(p_enhancements, '{}'::jsonb), 'created', 0, v_idem, v_source)
  returning * into v_job;
  return v_job;
end;
$function$
;

do $$begin if(select md5(prosrc) from pg_proc where oid='public.publish_render(uuid,numeric,numeric,jsonb,uuid)'::regprocedure)not in('965c26447ca27ac12b278f2995268fba','356cdfa9a44b88f628d08af9fee72c13')then raise exception 'Review changed function publish_render(uuid,numeric,numeric,jsonb,uuid)';end if;end$$;

CREATE OR REPLACE FUNCTION public.publish_render(p_job uuid, p_duration numeric DEFAULT NULL::numeric, p_speed numeric DEFAULT 2.0, p_chapters jsonb DEFAULT '[]'::jsonb, p_poster_asset uuid DEFAULT NULL::uuid)
 RETURNS renders
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_job render_jobs;
  v_org uuid;
  v_role text;
  v_asset capture_assets;
  v_poster capture_assets;
  v_poster_key text := null;
  v_render renders;
  v_slug text;
  v_dur numeric;
  v_staged boolean;
  v_style text;
  attempt integer;
  -- 0047: recipients of the render_ready message. Never returned; the function's
  -- return type is byte-identical to 0046's.
  v_member record;
begin
  select rj.* into v_job from render_jobs rj where rj.id = p_job;
  if not found then raise exception 'RP404: render job not found'; end if;
  select l.org_id into v_org from listings l where l.id = v_job.listing_id and l.deleted_at is null;
  if v_org is null then raise exception 'RP404: listing not found'; end if;

  v_role := public.library_scope_role(auth.uid(),v_org,(select listing_id from public.render_jobs where id=p_job));
  if v_role is null then raise exception 'RP403: not a member of this workspace'; end if;
  if v_role not in ('owner','admin','agent') then
    raise exception 'RP403: your role does not permit publishing renders';
  end if;

  if v_job.capture_asset_id is not null and not public.studio_presenter_media_access(v_job.capture_asset_id) then raise exception 'RP409: Presenter source approval is no longer available'; end if;
  -- Poster: SERVER-DERIVED key from an asset the caller could only have created
  -- through /uploads {role:"render", kind:"photo"} for this same listing. A free
  -- string here would let a caller point og:image at anything in the bucket.
  if p_poster_asset is not null then
    select a.* into v_poster from capture_assets a where a.id = p_poster_asset;
    if not found
       or v_poster.listing_id <> v_job.listing_id
       or coalesce(v_poster.bucket, 'uploads') <> 'renders'
       or v_poster.uploaded is not true
       or v_poster.kind <> 'photo' then
      raise exception 'RP400: poster_asset_id must be an uploaded photo in the renders bucket for this listing';
    end if;
    v_poster_key := v_poster.storage_key;
  end if;

  -- Serialize per job, then re-check: concurrent publishes previously raced the
  -- unique(job_id) index and surfaced RP500 instead of the existing render.
  perform pg_advisory_xact_lock(hashtextextended('publish_render:' || p_job::text, 42));
  select r.* into v_render from renders r where r.job_id = p_job;
  if found then
    -- Idempotent replay. A retry that now carries a poster completes the earlier
    -- poster-less publish instead of being ignored.
    if v_poster_key is not null and v_render.poster_key is null then
      update renders set poster_key = v_poster_key where id = v_render.id returning * into v_render;
    end if;
    return v_render;
  end if;

  if v_job.capture_asset_id is null then raise exception 'RP400: job has no capture asset'; end if;
  select a.* into v_asset from capture_assets a where a.id = v_job.capture_asset_id;
  if not found then raise exception 'RP404: capture asset not found'; end if;
  if coalesce(v_asset.bucket, 'uploads') <> 'renders' then
    raise exception 'RP400: the job asset is not a role=render upload';
  end if;
  if v_asset.uploaded is not true then
    raise exception 'RP409: the render upload is not complete';
  end if;

  v_dur := coalesce(p_duration, v_asset.duration_s);
  if v_dur is null or v_dur <= 0 or v_dur > 7200 then
    raise exception 'RP400: duration_s is required (0 < s <= 7200)';
  end if;

  -- ── VIRTUAL-STAGING DISCLOSURE — SERVER-DERIVED, the caller gets no say ────
  -- `renders.staged` is a LEGAL DISCLOSURE, not a feature flag: it drives the
  -- "✦ Virtually staged" chip and the disclosure sheet on the public tour
  -- (services/edge/tour-host/src/player.ts). Under MLS virtual-media rules and
  -- California AB 723, getting it wrong is a compliance failure in BOTH
  -- directions — stamping a tour whose pixels were never altered is false
  -- advertising of an add-on that did not run; failing to stamp one that WAS
  -- altered is a disclosure violation. So the flag follows the OUTCOME the
  -- pipeline reports, and where no outcome exists it follows whichever answer
  -- cannot under-disclose:
  --
  --   1. enhancement_result carries `staged` → the worker MEASURED what it
  --      shipped (a segment passed QC and an edit landed). Trust it in both
  --      directions. This is the F-G-01 #2 / F-G-09 fix: before 0016 a tour was
  --      stamped because the user ticked a box, even when the pipeline skipped,
  --      QC denied the edit, the spend ceiling stopped it, or no worker was
  --      reachable at all.
  --   2. source='app' with no outcome → FALSE. An app publish is the phone's
  --      own on-device render, uploaded through /uploads role=render; no AI
  --      pipeline exists on that path (iOS decision A5 — Enhancements always
  --      ships `declutter:false, style:.asIs`), so nothing was altered and
  --      stamping it is exactly the false-advertising failure above. Photo-level
  --      edits made through /ai-enhance are disclosed separately and per-asset
  --      through media_provenance (0012); they are not this tour-level flag.
  --   3. source='worker' with no outcome → the pre-0016 intent-derived rule,
  --      byte-for-byte unchanged. A worker that died before writing its result,
  --      or one too old to write the column at all, must not silently turn a
  --      REAL virtual staging into an undisclosed one. Falling back to the
  --      requested toggles can only over-disclose, which is the survivable
  --      direction — and it is what this function does today, so the worker
  --      path does not regress.
  v_style := lower(trim(coalesce(v_job.enhancements->>'style', '')));
  if v_job.enhancement_result is not null and v_job.enhancement_result ? 'staged' then
    v_staged := coalesce((v_job.enhancement_result->>'staged')::boolean, false);
  elsif coalesce(v_job.source, 'worker') = 'app' then
    v_staged := false;
  else
    v_staged := coalesce((v_job.enhancements->>'declutter')::boolean, false)
                or (v_style <> '' and v_style not in ('as_is','as-is','asis','none'));
  end if;

  perform replace_asset_chapters(v_asset.id, p_chapters);

  for attempt in 1..6 loop
    v_slug := replace(pg_catalog.gen_random_uuid()::text,'-','');
    begin
      insert into renders (job_id, listing_id, slug, duration_s, speed_factor,
                           video_key, stream_uid, poster_key, staged, published_at)
      values (v_job.id, v_job.listing_id, v_slug, v_dur,
              greatest(0.25, least(8.0, coalesce(p_speed, 2.0))),
              v_asset.storage_key, null, v_poster_key, v_staged, now())
      returning * into v_render;
      exit;
    exception when unique_violation then
      if attempt = 6 then raise exception 'RP500: could not allocate a unique slug'; end if;
    end;
  end loop;

  -- 0046: the ACTIVATION fact, written exactly once. `coalesce` in the SET and
  -- `is null` in the WHERE both say the same thing on purpose — a later publish
  -- must never move the first one, and neither form alone survives a careless
  -- edit of the other.
  update orgs
     set first_tour_published_at = coalesce(first_tour_published_at, v_render.published_at)
   where id = v_org
     and first_tour_published_at is null;

  update render_jobs
     set status = 'ready', progress = 1, finished_at = now(), error = null
   where id = v_job.id;
  update listings set status = 'ready' where id = v_job.listing_id;

  -- 0047: "your tour is ready". LAST, after the job and listing are actually
  -- marked ready, so a message can never describe a state that has not been
  -- written yet. Its own exception block: a publish is the customer's work and
  -- must never be lost to a messaging fault.
  begin
    for v_member in
      select m.user_id from memberships m where m.org_id=public.listing_owner_library(v_job.listing_id)and m.role='owner'and public.listing_content_access(m.user_id,v_job.listing_id,false)
      union select public.library_team_owner(public.listing_owner_library(v_job.listing_id))where public.library_team_owner(public.listing_owner_library(v_job.listing_id))is not null
    loop
      perform notification_enqueue(
        v_org, v_member.user_id, 'render_ready',
        jsonb_build_object(
          'deep_link', '/f/' || v_render.slug,
          'data', jsonb_build_object(
            'render_id',       v_render.id,
            'slug',            v_render.slug,
            'listing_id',      v_render.listing_id,
            'listing_address', (select l.address from listings l where l.id = v_render.listing_id),
            'source',          coalesce(v_job.source, 'worker'))),
        'render_ready:' || v_render.id::text || ':' || v_member.user_id::text,
        null);
    end loop;
  exception when others then
    raise warning '0047: render_ready enqueue failed for render % (% — %)',
      v_render.id, sqlstate, sqlerrm;
  end;

  return v_render;
end;
$function$
;

do $$begin if(select md5(prosrc) from pg_proc where oid='public.studio_presenter_scope(uuid,uuid,uuid)'::regprocedure)not in('641c238c1e6fea6ffc5a55dc4237239c','92fecefdd5777b6ff8d6823186d646b3')then raise exception 'Review changed function studio_presenter_scope(uuid,uuid,uuid)';end if;end$$;

CREATE OR REPLACE FUNCTION public.studio_presenter_scope(p_actor uuid, p_org_id uuid, p_listing_id uuid)
 RETURNS text
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare v_role text;
begin
 if current_setting('role',true) is distinct from 'service_role' then raise insufficient_privilege using message='service role required'; end if;
 -- Every presenter action in this workspace uses the same transaction lock. This
 -- bounds the consent/CAS critical section, including creation of absent rows.
 perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('studio-presenter:'||p_org_id::text,0));
 if not public.studio_review_named_account(p_actor) then raise exception 'RP403: Your named account is unavailable'; end if;
 v_role:=public.library_scope_role(p_actor,p_org_id,p_listing_id);
 if v_role is null then raise exception 'RP403: Workspace membership is required'; end if;
 perform 1 from public.orgs where id=p_org_id and deleted_at is null for share;
 if not found then raise exception 'RP404: Workspace is unavailable'; end if;
 perform 1 from public.listings where id=p_listing_id and org_id=p_org_id and deleted_at is null for share;
 if not found then raise exception 'RP404: Property is unavailable'; end if;
 return v_role;
end;
$function$
;

do $$begin if(select md5(prosrc) from pg_proc where oid='public.studio_production_copy(uuid,uuid,uuid,text,integer,integer)'::regprocedure)not in('1d89a7552a8e5a80357ccbcb7504380e','dc28c808dc7d8c07d462dccf132b8de2')then raise exception 'Review changed function studio_production_copy(uuid,uuid,uuid,text,integer,integer)';end if;end$$;

CREATE OR REPLACE FUNCTION public.studio_production_copy(p_actor uuid, p_org_id uuid, p_document_user_id uuid, p_key text, p_document_revision integer, p_expected_target_revision integer)
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare source public.studio_production_versions%rowtype; target public.studio_documents%rowtype;
  preserved public.studio_production_versions%rowtype; voice public.studio_creative_results%rowtype;
  v_listing uuid; v_role text; v_payload jsonb; item jsonb; media jsonb; v_asset uuid; v_kind text;
  v_voice_id uuid; v_alias uuid; v_now timestamptz:=clock_timestamp();
begin
  if p_key is null or p_key !~ '^edit:[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
    or p_document_revision is null or p_document_revision<1 or p_expected_target_revision is null or p_expected_target_revision<0 or p_expected_target_revision>=2147483647 then
    raise exception 'RP400: Choose a saved version and the current target revision';
  end if;
  v_listing:=substring(p_key from 6)::uuid;
  if not public.studio_review_named_account(p_actor) then raise exception 'RP403: Your named account is unavailable'; end if;
  v_role:=public.library_scope_role(p_actor,p_org_id,v_listing);
  if v_role is null or v_role not in ('owner','admin','agent') then raise exception 'RP403: Your role cannot make an editable copy'; end if;
  perform 1 from public.orgs where id=p_org_id and deleted_at is null for share;
  if not found then raise exception 'RP404: Workspace is unavailable'; end if;
  perform 1 from public.listings where id=v_listing and org_id=p_org_id and deleted_at is null for share;
  if not found then raise exception 'RP404: Property is unavailable'; end if;
  perform 1 from public.profiles where id=p_document_user_id and public.studio_review_named_account(id)and public.listing_content_access(p_document_user_id,v_listing,false)for share;
  if not found then raise exception 'RP404: The source author is unavailable'; end if;
  -- Deterministic ordering prevents reciprocal reviewer copies deadlocking.
  perform 1 from public.studio_documents where org_id=p_org_id and key=p_key and user_id in (p_actor,p_document_user_id) order by user_id for update;
  if not exists(select 1 from public.studio_documents where user_id=p_document_user_id and org_id=p_org_id and key=p_key and kind='edit' and listing_id=v_listing) then
    raise exception 'RP404: This saved source is unavailable';
  end if;
  -- A submitted historical snapshot is not a perpetual invitation to make
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
  select * into source from public.studio_production_versions where document_user_id=p_document_user_id and org_id=p_org_id and document_key=p_key
    and listing_id=v_listing and document_revision=p_document_revision and (p_actor=p_document_user_id or reason='submitted');
  if not found then raise exception 'RP404: This saved version is unavailable'; end if;
  select * into target from public.studio_documents where user_id=p_actor and org_id=p_org_id and key=p_key;
  if coalesce(target.revision,0)<>p_expected_target_revision then raise exception 'RP409: Your current draft changed. Reload before making this copy'; end if;
  if target.key is not null and (target.kind<>'edit' or target.listing_id<>v_listing) then raise exception 'RP409: The target draft has a different property binding'; end if;
  v_payload:=source.payload;
  perform public.studio_assert_property_music(p_org_id,v_listing,p_document_user_id,v_payload);
  if v_payload#>'{draft,music}' is not null and v_payload#>'{draft,music}'<>'null'::jsonb then
    insert into public.studio_property_music_copies(actor_id,org_id,listing_id,sha256,source_version_id) values(p_actor,p_org_id,v_listing,v_payload#>>'{draft,music,source,sha256}',source.id) on conflict(actor_id,org_id,listing_id,sha256) do nothing;
  end if;
  if v_payload->>'listingId' is distinct from v_listing::text or jsonb_typeof(v_payload->'draft') is distinct from 'object'
    or jsonb_typeof(v_payload->'sources') is distinct from 'array' or jsonb_typeof(v_payload#>'{draft,clips}') is distinct from 'array'
    or (v_payload#>'{draft,overlays}' is not null and jsonb_typeof(v_payload#>'{draft,overlays}') is distinct from 'array') then
    raise exception 'RP400: The saved reel has an invalid edit or source list';
  end if;
  if jsonb_array_length(v_payload->'sources')>24 or jsonb_array_length(v_payload#>'{draft,clips}')>12
    or jsonb_array_length(coalesce(v_payload#>'{draft,overlays}','[]'))>12 then
    raise exception 'RP400: The saved reel exceeds supported source limits';
  end if;
  for media in select value from jsonb_array_elements((v_payload#>'{draft,clips}')||coalesce(v_payload#>'{draft,overlays}','[]')) loop
    if coalesce(media#>>'{source,sha256}','') !~ '^[0-9a-f]{64}$' or coalesce(media#>>'{source,kind}','') not in ('image','video')
      or not exists(select 1 from jsonb_array_elements(v_payload->'sources') s where s->>'sha256'=media#>>'{source,sha256}') then
      raise exception 'RP422: Upload every original file before handing off this reel';
    end if;
  end loop;
  for item in select value from jsonb_array_elements(v_payload->'sources') loop
    if item->>'listingId' is distinct from v_listing::text or coalesce(item->>'assetId','') !~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
      or coalesce(item->>'sha256','') !~ '^[0-9a-f]{64}$' then raise exception 'RP400: A saved source belongs to another property'; end if;
    v_asset:=(item->>'assetId')::uuid;
    -- References not used by the current cut still need valid listing ownership.
    if not exists(select 1 from public.capture_assets a where a.id=v_asset and a.listing_id=v_listing and a.uploaded
      and public.studio_review_media_key(a.storage_key,p_org_id,v_listing) and starts_with(a.storage_key,a.bucket||'/'))
      and not exists(select 1 from public.photos p where p.id=v_asset and p.listing_id=v_listing and
        (public.studio_review_media_key(p.original_key,p_org_id,v_listing) or public.studio_review_media_key(p.enhanced_key,p_org_id,v_listing)))
      and not exists(select 1 from public.renders r where r.id=v_asset and r.listing_id=v_listing and public.studio_review_media_key(r.video_key,p_org_id,v_listing)) then
      raise exception 'RP422: An original file is no longer available in this property';
    end if;
    for media in select value from jsonb_array_elements((v_payload#>'{draft,clips}')||coalesce(v_payload#>'{draft,overlays}','[]')) where value#>>'{source,sha256}'=item->>'sha256' loop
      v_kind:=case media#>>'{source,kind}' when 'image' then 'photo' else 'video' end;
      if not exists(select 1 from public.capture_assets a where a.id=v_asset and a.listing_id=v_listing and a.kind=v_kind and a.uploaded)
        and not (v_kind='photo' and exists(select 1 from public.photos p where p.id=v_asset and p.listing_id=v_listing))
        and not (v_kind='video' and exists(select 1 from public.renders r where r.id=v_asset and r.listing_id=v_listing)) then
        raise exception 'RP422: A saved source has a different media type';
      end if;
    end loop;
  end loop;
  if v_payload#>'{draft,narration}' is not null and v_payload#>'{draft,narration}'<>'null'::jsonb then
    if coalesce(v_payload#>>'{draft,narration,resultId}','') !~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then raise exception 'RP400: The saved narration reference is invalid'; end if;
    v_voice_id:=(v_payload#>>'{draft,narration,resultId}')::uuid;
    select * into voice from public.studio_creative_results where id=v_voice_id and user_id=p_document_user_id and org_id=p_org_id and listing_id=v_listing and kind='voice' for share;
    if not found or voice.metadata->>'state' is distinct from 'completed' or voice.bucket is distinct from 'uploads'
      or voice.storage_key is null or voice.storage_key !~ ('^ai-voice/'||p_org_id::text||'/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}[.]mp3$') then
      raise exception 'RP422: The saved narration is no longer available for handoff';
    end if;
    if p_actor<>p_document_user_id then
      v_alias:=gen_random_uuid();
      insert into public.studio_creative_results(id,user_id,org_id,listing_id,kind,storage_key,bucket,provenance_id,request_key,metadata)
        values(v_alias,p_actor,p_org_id,v_listing,'voice',voice.storage_key,'uploads',voice.provenance_id,'review-copy:'||v_alias::text,
          (voice.metadata-'request_id')||jsonb_build_object('copied_from_result_id',voice.id,'copied_from_version_id',source.id));
      v_payload:=jsonb_set(v_payload,'{draft,narration,resultId}',to_jsonb(v_alias::text));
    end if;
  end if;
  if target.key is not null then
    insert into public.studio_production_versions(document_user_id,org_id,document_key,listing_id,document_revision,reason,payload,brief)
      values(target.user_id,target.org_id,target.key,target.listing_id,target.revision,'before_replace',target.payload,(select payload from public.studio_documents where user_id=target.user_id and org_id=target.org_id and key='production:'||target.listing_id::text and kind='production' and listing_id=target.listing_id))
      on conflict(document_user_id,org_id,document_key,document_revision) do nothing;
    select * into preserved from public.studio_production_versions where document_user_id=target.user_id and org_id=target.org_id and document_key=target.key and document_revision=target.revision;
    if preserved.payload is distinct from target.payload then raise exception 'RP409: The current draft conflicts with its immutable version'; end if;
    update public.studio_documents set revision=target.revision+1,payload=v_payload,updated_at=v_now where user_id=p_actor and org_id=p_org_id and key=p_key returning * into target;
  else
    begin
      insert into public.studio_documents(user_id,org_id,key,kind,listing_id,revision,payload,updated_at)
        values(p_actor,p_org_id,p_key,'edit',v_listing,1,v_payload,v_now) returning * into target;
    exception when unique_violation then raise exception 'RP409: Your current draft changed. Reload before making this copy'; end;
  end if;
  return jsonb_build_object('document',jsonb_build_object('key',target.key,'kind',target.kind,'listing_id',target.listing_id,'revision',target.revision,'payload',target.payload,'updated_at',target.updated_at),
    'source_version',public.studio_production_version_metadata(source)||jsonb_build_object('brief',source.brief),
    'preserved_version',case when preserved.id is not null then public.studio_production_version_metadata(preserved) else null end);
end;
$function$
;

do $$begin if(select md5(prosrc) from pg_proc where oid='public.studio_production_review(uuid,uuid,uuid,text,text,integer,integer,text,integer)'::regprocedure)not in('708be2b8022e63edeaf90fde144fa983','2bf5b443908c29ce79e8dd395c75ad57')then raise exception 'Review changed function studio_production_review(uuid,uuid,uuid,text,text,integer,integer,text,integer)';end if;end$$;

CREATE OR REPLACE FUNCTION public.studio_production_review(p_actor uuid, p_org_id uuid, p_document_user_id uuid, p_key text, p_action text DEFAULT 'get'::text, p_expected_document_revision integer DEFAULT NULL::integer, p_expected_review_revision integer DEFAULT NULL::integer, p_message text DEFAULT NULL::text, p_position_ms integer DEFAULT NULL::integer)
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare d public.studio_documents%rowtype; r public.studio_production_reviews%rowtype;
  v_role text; v_agent uuid; v_listing uuid; v_permissions jsonb; v_status text;
  v_event jsonb; v_review jsonb; v_document jsonb; v_now timestamptz:=clock_timestamp();
begin
  if p_key is null or p_key !~ '^edit:[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
    or p_action is null or p_action not in ('get','submit','comment','request_changes','approve','withdraw') then
    raise exception 'RP400: Choose a saved property reel and review action';
  end if;
  v_listing:=substring(p_key from 6)::uuid;
  if not public.studio_review_named_account(p_actor) then
    raise exception 'RP403: Your named account is unavailable';
  end if;
  v_role:=public.library_scope_role(p_actor,p_org_id,v_listing);
  if v_role is null then raise exception 'RP403: Workspace membership is required'; end if;
  perform 1 from public.orgs where id=p_org_id and deleted_at is null for share;
  if not found then raise exception 'RP404: Workspace is unavailable'; end if;
  select agent_id into v_agent from public.listings where id=v_listing and org_id=p_org_id and deleted_at is null for share;
  if not found then raise exception 'RP404: Property is unavailable'; end if;
  perform 1 from public.profiles m where m.id=p_document_user_id and public.studio_review_named_account(m.id)and public.listing_content_access(p_document_user_id,v_listing,false)for share of m;
  if not found then raise exception 'RP404: Saved reel is unavailable'; end if;
  select * into d from public.studio_documents where user_id=p_document_user_id and org_id=p_org_id and key=p_key
    and kind='edit' and listing_id=v_listing for update;
  if not found then raise exception 'RP404: Save this property reel before requesting review'; end if;
  select * into r from public.studio_production_reviews where document_user_id=p_document_user_id and org_id=p_org_id and document_key=p_key for update;
  if p_actor<>p_document_user_id and r.submitted_at is null then raise exception 'RP404: This private reel has not been submitted'; end if;
  v_status:=coalesce(r.status,'draft');
  v_permissions:=public.studio_review_permissions(p_actor,p_document_user_id,v_agent,v_role,v_status);
  if p_action<>'get' then
    if p_expected_document_revision is null or p_expected_review_revision is null or p_expected_document_revision<1 or p_expected_review_revision<0 then
      raise exception 'RP400: Refresh saved reel and review revisions before changing them';
    end if;
    if p_expected_document_revision<>d.revision or p_expected_review_revision<>coalesce(r.revision,0) then
      raise exception 'RP409: This reel or review changed. Reload before continuing';
    end if;
    if coalesce((v_permissions->>('can_'||p_action))::boolean,false) is not true then
      raise exception 'RP403: Your role cannot perform this action in the current review state';
    end if;
    if p_message is not null and length(p_message)>2000 then
      raise exception 'RP400: Review comments must be 2000 characters or fewer';
    end if;
    if p_action in ('comment','request_changes') and coalesce(length(btrim(p_message)),0)=0 then
      raise exception 'RP400: Add a comment explaining the requested change';
    end if;
    if p_position_ms is not null and (p_position_ms<0 or p_position_ms>180000) then
      raise exception 'RP400: Comment time must be within the supported reel duration';
    end if;
    if jsonb_array_length(coalesce(r.events,'[]'::jsonb))>=250 then raise exception 'RP409: This review has reached its history limit'; end if;
    v_status:=case p_action when 'submit' then 'in_review' when 'approve' then 'approved' when 'request_changes' then 'changes_requested' when 'withdraw' then 'draft' else v_status end;
  if p_action in ('submit','approve') then perform public.studio_assert_property_music(p_org_id,v_listing,p_document_user_id,d.payload);end if;
    v_event:=jsonb_build_object('id',gen_random_uuid(),'action',p_action,'author_id',p_actor,'created_at',v_now,
      'document_revision',d.revision,'message',nullif(btrim(p_message),''),'position_ms',p_position_ms);
    insert into public.studio_production_reviews(document_user_id,org_id,document_key,listing_id,revision,document_revision,status,events,submitted_at,updated_at)
      values(p_document_user_id,p_org_id,p_key,v_listing,coalesce(r.revision,0)+1,d.revision,v_status,coalesce(r.events,'[]'::jsonb)||jsonb_build_array(v_event),
        case when p_action='submit' then v_now else r.submitted_at end,v_now)
      on conflict(document_user_id,org_id,document_key) do update set revision=excluded.revision,document_revision=excluded.document_revision,
        status=excluded.status,events=excluded.events,submitted_at=excluded.submitted_at,updated_at=excluded.updated_at returning * into r;
    if p_action='submit' then
      insert into public.studio_production_versions(document_user_id,org_id,document_key,listing_id,document_revision,reason,payload,brief)
        values(d.user_id,d.org_id,d.key,d.listing_id,d.revision,'submitted',d.payload,(select payload from public.studio_documents where user_id=d.user_id and org_id=d.org_id and key='production:'||d.listing_id::text and kind='production' and listing_id=d.listing_id)) on conflict(document_user_id,org_id,document_key,document_revision) do nothing;
      if not exists(select 1 from public.studio_production_versions v where v.document_user_id=d.user_id and v.org_id=d.org_id
        and v.document_key=d.key and v.document_revision=d.revision and v.payload=d.payload and v.reason='submitted') then
        raise exception 'RP409: This saved revision has a different immutable version';
      end if;
    end if;
    v_permissions:=public.studio_review_permissions(p_actor,p_document_user_id,v_agent,v_role,v_status);
  end if;
  v_review:=jsonb_build_object('document_user_id',d.user_id,'org_id',d.org_id,'key',d.key,'listing_id',d.listing_id,
    'revision',coalesce(r.revision,0),'document_revision',d.revision,'status',v_status,'events',coalesce(r.events,'[]'::jsonb),
    'submitted_at',r.submitted_at,'updated_at',coalesce(r.updated_at,d.updated_at));
  -- New edits are private again. A prior submission only grants metadata/history
  -- access until the author explicitly submits the new saved revision.
  if p_actor=d.user_id or (v_status<>'draft' and r.document_revision=d.revision) then
    v_document:=jsonb_build_object('key',d.key,'kind',d.kind,'listing_id',d.listing_id,'revision',d.revision,'payload',d.payload,'updated_at',d.updated_at);
  end if;
  return jsonb_build_object('review',v_review,'document',v_document,'permissions',v_permissions,'source_revision',d.revision,
    'brief',(select v.brief from public.studio_production_versions v where v.document_user_id=d.user_id and v.org_id=d.org_id and v.document_key=d.key and v.document_revision=d.revision and v.reason='submitted'));
end;
$function$
;

do $$begin if(select md5(prosrc) from pg_proc where oid='public.studio_presenter_execution_member(uuid,uuid)'::regprocedure)not in('5f44e608faebadd06fad84b0d3ae300a','eadd46cfce41b0307fc1f6fafdca7bc3')then raise exception 'Review changed function studio_presenter_execution_member(uuid,uuid)';end if;end$$;

CREATE OR REPLACE FUNCTION public.studio_presenter_execution_member(p_user uuid, p_org uuid)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
 select exists(select 1 from auth.users where id=p_user and is_anonymous is false)
  and not exists(select 1 from public.deletion_requests where user_id=p_user and status in ('pending','processing'))
  and public.library_content_access(p_user,p_org,false);
$function$
;

do $$begin if(select md5(prosrc) from pg_proc where oid='public.studio_presenter_member(uuid,uuid)'::regprocedure)not in('6fc0f1b6e81ce36138a7471e98327e93','20fa04bdec68652da2a3865629d4af82')then raise exception 'Review changed function studio_presenter_member(uuid,uuid)';end if;end$$;

CREATE OR REPLACE FUNCTION public.studio_presenter_member(p_user uuid, p_org_id uuid)
 RETURNS boolean
 LANGUAGE sql
 STABLE
 SET search_path TO ''
AS $function$
 select public.studio_review_named_account(p_user) and public.library_content_access(p_user,p_org_id,false);
$function$
;

do $$begin if(select md5(prosrc) from pg_proc where oid='public.studio_production_review_queue(uuid,uuid,uuid,integer)'::regprocedure)not in('91b89b738297c0ccd893fec421cc24b8','379d23fb5d1c763ce451d96d00ab3a7c')then raise exception 'Review changed function studio_production_review_queue(uuid,uuid,uuid,integer)';end if;end$$;

CREATE OR REPLACE FUNCTION public.studio_production_review_queue(p_actor uuid, p_org_id uuid, p_listing_id uuid DEFAULT NULL::uuid, p_offset integer DEFAULT 0)
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare v_role text; v_rows jsonb;
begin
  if p_offset is null or p_offset<0 or p_offset>10000 or p_offset%50<>0 then raise exception 'RP400: Invalid review queue page'; end if;
  if not public.studio_review_named_account(p_actor) then
    raise exception 'RP403: Your named account is unavailable';
  end if;
  v_role:=public.library_scope_role(p_actor,p_org_id,p_listing_id);
  if v_role is null then raise exception 'RP403: Workspace membership is required'; end if;
  if p_listing_id is not null and not exists(select 1 from public.listings where id=p_listing_id and org_id=p_org_id and deleted_at is null) then
    raise exception 'RP404: Property is unavailable';
  end if;
  select coalesce(jsonb_agg(x.value order by x.updated_at desc,x.author,x.key),'[]'::jsonb) into v_rows from (
    select jsonb_build_object('review',jsonb_build_object('document_user_id',r.document_user_id,'org_id',r.org_id,'key',r.document_key,'listing_id',r.listing_id,
      'revision',r.revision,'document_revision',d.revision,'status',r.status,'submitted_at',r.submitted_at,'updated_at',r.updated_at,
      'events','[]'::jsonb,'event_count',jsonb_array_length(r.events)),'source_revision',d.revision,
      'permissions',public.studio_review_permissions(p_actor,d.user_id,l.agent_id,v_role,r.status)) as value,
      r.updated_at,r.document_user_id as author,r.document_key as key
    from public.studio_production_reviews r
    join public.studio_documents d on d.user_id=r.document_user_id and d.org_id=r.org_id and d.key=r.document_key and d.listing_id=r.listing_id and d.kind='edit'
    join public.listings l on l.id=r.listing_id and l.org_id=r.org_id and l.deleted_at is null
    where(case when p_listing_id is null then public.listing_owner_library(r.listing_id)=p_org_id else r.org_id=p_org_id end)and public.listing_content_access(d.user_id,r.listing_id,false) and public.listing_content_access(p_actor,r.listing_id,false)and (p_listing_id is null or r.listing_id=p_listing_id)
      and (r.submitted_at is not null or r.document_user_id=p_actor)
      and public.studio_review_named_account(d.user_id)
    order by r.updated_at desc,r.document_user_id,r.document_key limit 51 offset p_offset
  ) x;
  if jsonb_array_length(v_rows)>50 and p_offset=10000 then raise exception 'RP422: Review queue is too large to load completely'; end if;
  return jsonb_build_object('reviews',(select coalesce(jsonb_agg(value),'[]'::jsonb) from jsonb_array_elements(v_rows) with ordinality x(value,n) where n<=50),
    'next_offset',case when jsonb_array_length(v_rows)>50 then p_offset+50 else null end);
end;
$function$
;

do $$begin if(select md5(prosrc) from pg_proc where oid='public.client_listing_access(uuid,uuid,uuid,boolean)'::regprocedure)not in('76fe574b3e96fbcf2398ea6c66270fd0','e50c85f50fb8533d223ce71b615db630')then raise exception 'Review changed function client_listing_access(uuid,uuid,uuid,boolean)';end if;end$$;

CREATE OR REPLACE FUNCTION public.client_listing_access(p_user uuid, p_org uuid, p_listing uuid, p_write boolean DEFAULT false)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_role text;
begin
 if current_setting('role',true)is distinct from 'service_role'then raise insufficient_privilege using message='service role required';end if;
 if not exists(select 1 from public.profiles where id=p_user)then raise exception 'RP401: session no longer exists';end if;
 if exists(select 1 from public.deletion_requests where user_id=p_user and status in('pending','processing'))then raise exception 'RP409: this account is being deleted';end if;
 v_role:=public.library_scope_role(p_user,p_org,p_listing);
 if v_role is null or not exists(select 1 from public.listings where id=p_listing and org_id=p_org and deleted_at is null)then raise exception 'RP404: listing not found in this workspace';end if;
 if p_write and v_role not in('owner','admin','agent')then raise exception 'RP403: your role does not permit editing client delivery';end if;
end$function$
;

do $$begin if(select md5(prosrc) from pg_proc where oid='public.media_delivery_admit(uuid,bigint,boolean)'::regprocedure)not in('2fb9ddf249bd3680538f91d19743abff','e1fde5a0b8b7942c07bb95eac48f0ae5')then raise exception 'Review changed function media_delivery_admit(uuid,bigint,boolean)';end if;end$$;

CREATE OR REPLACE FUNCTION public.media_delivery_admit(p_org uuid, p_bytes bigint, p_required boolean DEFAULT true)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare b public.media_delivery_budgets;
begin
 if current_setting('role',true)is distinct from 'service_role'then raise insufficient_privilege;end if;
 if p_org is null or p_bytes is null or p_bytes not between 0 and 268435456 or p_required is null then raise exception 'RP400: Invalid media admission';end if;
 perform 1 from public.orgs where id=p_org and deleted_at is null for update;
 if not found then raise exception 'RP404: Workspace unavailable';end if;
 perform pg_advisory_xact_lock(hashtextextended('media-budget:'||public.library_billing_org(p_org),72453));
 select * into b from public.media_delivery_budgets where org_id=public.library_billing_org(p_org) and starts_at<=now()and ends_at>now()order by starts_at desc,id limit 1 for update;
 if not found then
  if not p_required and not exists(select 1 from public.serving_funding where org_id=public.library_billing_org(p_org))then return jsonb_build_object('admitted',true,'legacy_unbudgeted',true);end if;
  raise exception 'RP503: Bounded media service activation pending';end if;
 if b.funding_id is not null and not exists(select 1 from public.serving_funding where id=b.funding_id and org_id=public.library_billing_org(p_org) and revoked_at is null and retention_ends_at>now())then raise exception 'RP404: Media funding unavailable';end if;
 if b.used_requests>=b.request_limit or p_bytes>b.byte_limit-b.used_bytes then raise exception 'RP429: Media serving allowance exhausted';end if;
 update public.media_delivery_budgets set used_requests=used_requests+1,used_bytes=used_bytes+p_bytes where id=b.id;
 return jsonb_build_object('admitted',true,'legacy_unbudgeted',false);
end$function$
;

do $$begin if(select md5(prosrc) from pg_proc where oid='public.media_storage_reserve(uuid,text,text,bigint)'::regprocedure)not in('c8a38d4af6b9a1388f314bcf8d2a1d61','99757d02a8f834d6685f35ddea308ebd')then raise exception 'Review changed function media_storage_reserve(uuid,text,text,bigint)';end if;end$$;

CREATE OR REPLACE FUNCTION public.media_storage_reserve(p_org uuid, p_bucket text, p_key text, p_bytes bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare prior public.media_storage_receipts;b public.media_delivery_budgets;used numeric;k text;listing uuid;billing uuid;
begin
 if current_setting('role',true)is distinct from 'service_role'and pg_trigger_depth()=0 then raise insufficient_privilege;end if;
 if p_org is null or p_bucket is null or p_bucket not in('uploads','renders')or p_key is null or length(p_key)not between 1 and 4096
  or p_key~'[[:cntrl:]\\%?#]'or p_key~'(^|/)\.\.?(/|$)'or p_bytes is null or p_bytes not between 1 and 12884901888 then raise exception 'RP400: Invalid stored media receipt';end if;
 perform 1 from public.orgs where id=p_org and deleted_at is null for update;
 if not found then raise exception 'RP403: Current storage workspace required';end if;
 billing:=coalesce((select billing_org_id from public.media_storage_receipts where bucket=p_bucket and object_key=p_key),public.library_storage_billing_org(p_org,p_bucket,p_key));
 perform pg_advisory_xact_lock(hashtextextended('media-budget:'||billing,72453));
 k:=case when p_key like '_staging/%' then substr(p_key,10)else p_key end;
 if not ((p_bucket='uploads'and(split_part(k,'/',1)in('uploads','studio-project','ai-voice','presenter-private'))or
  p_bucket='renders'and split_part(k,'/',1)in('renders','ai-router','presenter-private','video-reflections'))and split_part(k,'/',2)=p_org::text)then
  -- Published Python renders retain their existing renders/<listing>/<render>
  -- namespace. Resolve the complete listing owner; do not rewrite tester URLs.
  if p_bucket<>'renders'or split_part(k,'/',1)<>'renders'or split_part(k,'/',2)!~'^[a-f0-9]{8}(-[a-f0-9]{4}){3}-[a-f0-9]{12}$'then raise exception 'RP403: Exact owned storage namespace required';end if;
  listing:=split_part(k,'/',2)::uuid;
  perform 1 from public.listings where id=listing and org_id=p_org and deleted_at is null for share;
  if not found then raise exception 'RP403: Exact owned render listing required';end if;
 end if;
 select * into b from public.media_delivery_budgets where org_id=billing and starts_at<=now()and ends_at>now()order by starts_at desc,id limit 1 for update;
 if not found then
  if exists(select 1 from public.serving_funding where org_id=billing)then raise exception 'RP503: Bounded media storage activation pending';end if;
 elsif b.funding_id is not null and not exists(select 1 from public.serving_funding where id=b.funding_id and org_id=billing and revoked_at is null and retention_ends_at>now())then raise exception 'RP403: Current media storage funding required';end if;
 -- Each reserve, including replay, spends one request before a possible PUT.
 -- No missing response or repeated exact key restores the write allowance.
 if b.id is not null then
  if b.used_requests>=b.request_limit then raise exception 'RP429: Media write request allowance exhausted';end if;
  update public.media_delivery_budgets set used_requests=used_requests+1 where id=b.id;
 end if;
 select * into prior from public.media_storage_receipts where bucket=p_bucket and object_key=p_key;
 if found then
  if row(prior.org_id,prior.bytes)is distinct from row(p_org,p_bytes)or prior.deleted_at is not null then raise exception 'RP409: Stored media receipt is immutable';end if;
  return jsonb_build_object('reserved',true,'replay',true);end if;
 if b.funding_id is not null and not exists(select 1 from public.serving_funding where id=b.funding_id and org_id=billing and revoked_at is null and ends_at>now())then raise exception 'RP403: Current media write funding required';end if;
 -- Physical liability survives budget rollover and metadata/account deletion.
 select coalesce(sum(bytes),0)into used from public.media_storage_receipts where billing_org_id=billing and deleted_at is null;
 if b.id is not null and p_bytes>b.storage_limit-used then raise exception 'RP429: Stored media allowance exhausted';end if;
 insert into public.media_storage_receipts(org_id,billing_org_id,bucket,object_key,bytes)values(p_org,billing,p_bucket,p_key,p_bytes);
 return jsonb_build_object('reserved',true,'replay',false,'legacy_unbudgeted',b.id is null);
end$function$
;

do $$begin if(select md5(prosrc) from pg_proc where oid='public.upload_new_admission(uuid,uuid,bigint)'::regprocedure)not in('c47f47d8973ac3379a0a998e461c0582','1279cf160371121c27281b69224f4fba')then raise exception 'Review changed function upload_new_admission(uuid,uuid,bigint)';end if;end$$;

CREATE OR REPLACE FUNCTION public.upload_new_admission(p_actor uuid, p_org uuid, p_hold bigint)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare anonymous boolean;raw_source text;selected_plan text;e public.plan_entitlements;cap bigint;used numeric;
begin
 if current_setting('role',true)is distinct from 'service_role'then raise insufficient_privilege using message='service role required';end if;
 if p_hold is null or p_hold<1 or p_hold>12884901888 then raise exception 'RP400: invalid upload reservation';end if;
 select u.is_anonymous into anonymous from auth.users u where u.id=p_actor;
 if not found or anonymous is null then raise exception 'RP403: Sign in with Apple to upload and publish';end if;
 -- This org lock serializes monthly admissions across listings and UTC days.
 -- Existing reservations replay before this helper and keep their held bytes.
 select o.plan_source into raw_source from public.orgs o where o.id=public.library_actor_billing_org(p_actor,p_org)and o.deleted_at is null for update;
 if not found then raise exception 'RP403: upload workspace is not writable';end if;
 selected_plan:=public.effective_plan(public.library_actor_billing_org(p_actor,p_org));
 if anonymous then
  if raw_source is distinct from 'apple' or selected_plan not in('starter','pro','team')or not exists(
   select 1 from public.apple_subscriptions s where s.org_id=p_org and s.user_id=p_actor and s.plan=selected_plan
    and s.environment='Production'and s.status in('active','grace')and s.expires_at>=clock_timestamp()-interval '16 days'
  )then raise exception 'RP403: Sign in with Apple to upload and publish (Settings → Account), or restore your active subscription';end if;
 end if;
 e:=public.org_entitlement(public.library_actor_billing_org(p_actor,p_org));
 if public.org_has_internal_testing_grant(public.library_actor_billing_org(p_actor,p_org))or public.org_has_private_internal_testing(public.library_actor_billing_org(p_actor,p_org))then
  -- Preserve the named internal tester's existing physical daily boundary;
  -- an explicit grant is never inferred from a retail plan or user metadata.
  cap:=214748364800::bigint*31;
 else
  cap:=e.renders_per_month::bigint*12884901888::bigint+e.photo_edits_per_month::bigint*104857600::bigint;
 end if;
 if cap is null or cap<0 then raise exception 'RP503: upload admission is unavailable';end if;
 select coalesce(sum(r.held_bytes::numeric+r.spent_bytes::numeric),0)into used from public.upload_reservations r
  where r.billing_org_id=public.library_actor_billing_org(p_actor,p_org)and r.day>=date_trunc('month',clock_timestamp()at time zone 'UTC')::date
   and r.day<(date_trunc('month',clock_timestamp()at time zone 'UTC')+interval '1 month')::date;
 if used+p_hold>cap then raise exception 'RP429: monthly technical upload reservation ceiling exhausted';end if;
end$function$
;


do $$begin if(select md5(prosrc)from pg_proc where oid='public.video_erase_authorize(uuid,uuid,uuid)'::regprocedure)not in('456af5376084ef4e05f1690530aafe74','639adad8f4b7427652910a587eea831b')then raise exception 'Review changed function video_erase_authorize(uuid,uuid,uuid)';end if;end$$;
CREATE OR REPLACE FUNCTION public.video_erase_authorize(p_org uuid, p_user uuid, p_listing uuid DEFAULT NULL::uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  if not (case when p_listing is null then public.library_content_access(p_user,p_org,true)else public.listing_content_access(p_user,p_listing,true)end) then
    raise exception 'RP403: Your role does not permit video reflection removal';
  end if;
  if p_listing is not null and not exists(select 1 from listings where id=p_listing and org_id=p_org and deleted_at is null) then
    raise exception 'RP404: Listing not found in this workspace';
  end if;
end $function$
;

do $$begin if(select md5(prosrc)from pg_proc where oid='public.subscription_serving_activation(uuid,uuid)'::regprocedure)not in('974a4391d1ef0e4699b1423b2a845bd6','aee63b1d38ede81cccc01bd947efe11e')then raise exception 'Review changed function subscription_serving_activation(uuid,uuid)';end if;end$$;
CREATE OR REPLACE FUNCTION public.subscription_serving_activation(p_actor uuid, p_org uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare o public.orgs;
begin
 if current_setting('role',true)is distinct from 'service_role'then raise insufficient_privilege;end if;
 select * into o from public.orgs where id=public.library_billing_org(p_org)and deleted_at is null;
 if o.id is null or not public.library_content_access(p_actor,p_org,false)then raise exception 'RP403: Current service workspace access is required';end if;
 if exists(select 1 from auth.users where id=p_actor and is_anonymous is true)then
  if public.org_has_verified_retail_guest(p_actor,p_org)then return jsonb_build_object('org_id',p_org,'available',true,'funded',true,'authority','verified_retail');end if;
  return jsonb_build_object('org_id',p_org,'available',false,'funded',false,'authority','subscription_activation_unavailable');
 end if;
 if public.org_has_internal_testing_grant(p_org)or public.org_has_private_internal_testing(p_org)then return jsonb_build_object('org_id',p_org,'available',true,'funded',false,'authority','private_sponsorship');end if;
 if public.org_has_app_review_funding(p_org)then return jsonb_build_object('org_id',p_org,'available',true,'funded',true,'authority','app_review');end if;
 if exists(select 1 from public.brokerage_contracts c where c.org_id=p_org and c.status='active'and c.starts_at<=now()and(c.ends_at is null or c.ends_at>now()))then return jsonb_build_object('org_id',p_org,'available',true,'funded',false,'authority','brokerage');end if;
 if public.serving_mode()='ceiling'then return jsonb_build_object('org_id',p_org,'available',true,'funded',false,'authority','existing_non_apple');end if;
 if o.plan_source is distinct from 'apple'then return jsonb_build_object('org_id',p_org,'available',true,'funded',false,'authority','existing_non_apple');end if;
 if exists(select 1 from public.serving_funding f join public.apple_subscriptions s on s.org_id=f.org_id and s.original_transaction_id=f.apple_original_transaction_id
  where f.org_id=public.library_billing_org(p_org)and f.source='retail'and f.revoked_at is null and f.starts_at<=now()and f.ends_at>now()
   and s.environment='Production'and s.status='active'and s.expires_at>now())then
  return jsonb_build_object('org_id',p_org,'available',true,'funded',true,'authority','verified_retail');
 end if;
 if exists(select 1 from public.serving_funding f where f.org_id=p_org and f.source='trial'and f.actor_id=p_actor
  and f.revoked_at is null and f.starts_at<=now()and f.ends_at>now()
  and exists(select 1 from auth.users u where u.id=p_actor and u.is_anonymous is false)
  and not exists(select 1 from public.deletion_requests d where d.user_id=p_actor and d.status in('pending','processing'))
  and((public.subscription_trial_active(p_org,p_actor)).id is not null or f.created_at<(select created_at from public.subscription_trial_config where singleton)))then
  return jsonb_build_object('org_id',p_org,'available',true,'funded',true,'authority','funded_trial');
 end if;
 return jsonb_build_object('org_id',p_org,'available',false,'funded',false,'authority','subscription_activation_unavailable');
end$function$
;

do $$begin if(select md5(prosrc)from pg_proc where oid='public.studio_presenter_execution_worker(uuid,text,jsonb)'::regprocedure)not in('6123ed7bb64b4c77b1b515b3049ad08e','21a5b3395a24ab32523a01783f5065d8')then raise exception 'Review changed function studio_presenter_execution_worker(uuid,text,jsonb)';end if;end$$;
CREATE OR REPLACE FUNCTION public.studio_presenter_execution_worker(p_job_id uuid, p_action text, p_payload jsonb DEFAULT '{}'::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare j public.studio_presenter_jobs%rowtype; r public.studio_presenter_runtime%rowtype; a public.capture_assets%rowtype;
 org uuid; token uuid; now_at timestamptz:=clock_timestamp(); next_state text; amount integer;
begin
 if current_setting('role',true) is distinct from 'service_role' then raise insufficient_privilege using message='service role required'; end if;
 if jsonb_typeof(p_payload) is distinct from 'object' or octet_length(p_payload::text)>32768 then raise exception 'RP400: Invalid worker payload'; end if;
 if p_action in ('drain','sweep') then
  return public.studio_presenter_execution_due(50);
 end if;
 select org_id into org from public.studio_presenter_jobs where id=p_job_id;
 if org is null then raise exception 'RP404: Presenter job is unavailable'; end if;
 perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('studio-presenter:'||org::text,0));
 select * into j from public.studio_presenter_jobs where id=p_job_id for update;
 now_at:=clock_timestamp();
 if not public.studio_presenter_job_valid(j) and j.invalidated_at is null and not (j.cleanup_state='done' and j.state in ('failed','cancelled','rejected')) then
  perform public.studio_presenter_invalidate_job(j.id);
  select * into j from public.studio_presenter_jobs where id=p_job_id;
 end if;
 if p_action in ('get','read','dispatch_prepare') then
  return jsonb_build_object('job',to_jsonb(j),'allowed',j.state='reserved' and j.invalidated_at is null and j.dispatch_started_at is null and (public.studio_presenter_execution_runtime(j.org_id)->>'available')::boolean,'snapshot',j.snapshot,'probe',j.probe,'execution_spec',j.execution_spec,'source_asset',j.snapshot->'source_asset','reference_assets',j.snapshot->'reference_assets','runtime',public.studio_presenter_execution_runtime(j.org_id));
 elsif p_action='dispatch_claim' then
  -- This is an irreversible *permission to POST once*. Expiration, crashes and
  -- HTTP ambiguity never return a request to reserved or issue a second claim.
  if j.state<>'reserved' or j.dispatch_started_at is not null or j.invalidated_at is not null then return jsonb_build_object('claimed',false,'job',to_jsonb(j)); end if;
  select * into r from public.studio_presenter_runtime where org_id=j.org_id for update;
  if not coalesce((public.studio_presenter_execution_runtime(j.org_id)->>'available')::boolean,false) or r.revision<>j.runtime_revision or r.price_version<>j.price_version
   or not public.listing_content_access(j.actor_id,j.listing_id,true) then
   update public.studio_presenter_jobs set state='failed',held_cents=0,charged_cents=0,billing_reference='not_dispatched',revision=revision+1,updated_at=now_at where id=j.id returning * into j;
   return jsonb_build_object('claimed',false,'job',to_jsonb(j));
  end if;
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('studio-presenter:higgsfield-capacity',0));
  if (select count(*) from public.studio_presenter_jobs where dispatch_started_at is not null and provider_terminal_at is null)>=3 then return jsonb_build_object('claimed',false,'capacity_limited',true,'job',to_jsonb(j)); end if;
  token:=gen_random_uuid();
  update public.studio_presenter_jobs set state='dispatching',dispatch_started_at=now_at,dispatch_token=token,revision=revision+1,updated_at=now_at where id=j.id returning * into j;
  return jsonb_build_object('claimed',true,'dispatch_token',token,'snapshot',j.snapshot,'probe',j.probe,'output_key',j.output_key,'job',to_jsonb(j));
 elsif p_action in ('dispatch_result','ambiguous') then
  if j.dispatch_started_at is null or j.dispatch_token is distinct from (p_payload->>'dispatch_token')::uuid then raise exception 'RP409: This worker did not claim dispatch'; end if;
  if p_action='ambiguous' then
   if j.state='dispatching' then update public.studio_presenter_jobs set state='uncertain',revision=revision+1,updated_at=now_at where id=j.id returning * into j; end if;
  else
   if coalesce(length(p_payload->>'request_id'),0) not between 1 and 200 or coalesce(length(p_payload->>'status_url'),0) not between 10 and 2000 or p_payload->>'status_url' !~ '^https://' or (p_payload->>'response_url' is not null and p_payload->>'response_url' !~ '^https://') or (p_payload->>'cancel_url' is not null and p_payload->>'cancel_url' !~ '^https://') then raise exception 'RP400: Confirmed provider references are required'; end if;
   if j.request_id is not null and (j.request_id is distinct from p_payload->>'request_id' or j.status_url is distinct from p_payload->>'status_url' or j.cancel_url is distinct from p_payload->>'cancel_url' or j.response_url is distinct from p_payload->>'response_url') then raise exception 'RP409: A different provider request is already recorded'; end if;
   if j.request_id is null then
    update public.studio_presenter_jobs set request_id=p_payload->>'request_id',status_url=p_payload->>'status_url',response_url=p_payload->>'response_url',cancel_url=p_payload->>'cancel_url',
     state=case when state in ('dispatching','uncertain') then 'queued' else state end,revision=revision+1,updated_at=now_at where id=j.id returning * into j;
   end if;
  end if;
 elsif p_action='status' then
  next_state:=p_payload->>'state';
  if next_state is null or next_state not in ('queued','processing') or j.request_id is null then raise exception 'RP400: Confirm a known provider job state'; end if;
  if j.state in ('queued','processing') and not (j.state='processing' and next_state='queued') then
   update public.studio_presenter_jobs set state=next_state,revision=revision+case when state=next_state then 0 else 1 end,updated_at=now_at where id=j.id returning * into j;
  end if;
 elsif p_action='completed' then
  if j.request_id is null then raise exception 'RP409: Confirm a known provider request before recording completion'; end if;
  update public.studio_presenter_jobs set provider_terminal_at=coalesce(provider_terminal_at,now_at),
   state=case when state='cancel_requested' then 'cancelled' else state end,
   cleanup_state=case when state in ('cancel_requested','cancelled','invalidated','rejected') then 'pending' else cleanup_state end,
   revision=revision+case when provider_terminal_at is null then 1 else 0 end,updated_at=now_at where id=j.id returning * into j;
 elsif p_action='output_claim' then
  if j.state not in ('queued','processing') or j.request_id is null or j.invalidated_at is not null or j.cancel_requested_at is not null then return jsonb_build_object('claimed',false,'job',to_jsonb(j)); end if;
  if j.output_write_deadline>now_at then return jsonb_build_object('claimed',false,'job',to_jsonb(j)); end if;
  token:=gen_random_uuid();
  update public.studio_presenter_jobs set output_lease_token=token,output_write_deadline=now_at+interval '5 minutes',updated_at=now_at where id=j.id returning * into j;
  return jsonb_build_object('claimed',true,'lease_token',token,'write_deadline',j.output_write_deadline,'output_key',j.output_key,'job',to_jsonb(j));
 elsif p_action='output_ready' then
  if j.output_lease_token is distinct from (p_payload->>'lease_token')::uuid or j.output_write_deadline<=now_at then raise exception 'RP409: Private output write lease expired'; end if;
  if j.state not in ('queued','processing','review') or j.invalidated_at is not null or j.cancel_requested_at is not null then raise exception 'RP409: This job no longer accepts generated output'; end if;
  if coalesce(p_payload->>'sha256','') !~ '^[0-9a-f]{64}$' or coalesce((p_payload->>'bytes')::bigint,0) not between 1 and 50331648 or coalesce((p_payload->>'duration_s')::numeric,0) not between 1 and 31 then raise exception 'RP422: Store a measured bounded MP4 output'; end if;
  if j.output_sha256 is not null and (j.output_sha256 is distinct from p_payload->>'sha256' or j.output_bytes is distinct from (p_payload->>'bytes')::bigint or j.output_duration_s is distinct from (p_payload->>'duration_s')::numeric) then raise exception 'RP409: Generated output bytes are immutable'; end if;
  if j.output_sha256 is null then
   update public.studio_presenter_jobs set output_sha256=p_payload->>'sha256',output_bytes=(p_payload->>'bytes')::bigint,output_duration_s=(p_payload->>'duration_s')::numeric,provider_terminal_at=now_at,state='review',revision=revision+1,updated_at=now_at where id=j.id returning * into j;
  end if;
 elsif p_action in ('settle','failed','cancelled') then
  if p_action<>'settle' and j.state not in ('dispatching','uncertain','queued','processing','cancel_requested','invalidated',p_action) then raise exception 'RP409: This terminal state cannot replace the saved output'; end if;
  if p_payload->'billing_final'='true'::jsonb then
   amount:=(p_payload->>'charged_cents')::integer;
   if amount is null or amount<0 or coalesce(length(btrim(p_payload->>'billing_reference')),0) not between 1 and 200 then raise exception 'RP400: Confirmed final billing evidence is required'; end if;
   if j.charged_cents is not null and (j.charged_cents<>amount or j.billing_reference is distinct from p_payload->>'billing_reference') then raise exception 'RP409: Final billing evidence is immutable'; end if;
   update public.studio_presenter_jobs set charged_cents=amount,held_cents=0,billing_reference=p_payload->>'billing_reference',updated_at=now_at where id=j.id returning * into j;
   if amount>j.hold_cents then update public.studio_presenter_runtime set enabled=false,revision=revision+1 where org_id=j.org_id and enabled; end if;
  elsif p_action='settle' then raise exception 'RP400: Unconfirmed costs remain held'; end if;
  if p_action<>'settle' then
   update public.studio_presenter_jobs set provider_terminal_at=coalesce(provider_terminal_at,now_at) where id=j.id returning * into j;
  end if;
  if p_action<>'settle' and j.state<>'invalidated' then
   update public.studio_presenter_jobs set state=p_action,cleanup_state='pending',revision=revision+1,updated_at=now_at where id=j.id returning * into j;
  end if;
 elsif p_action='import_bind' then
  if j.state<>'importing' or j.accepted_sha256 is distinct from j.output_sha256 or j.invalidated_at is not null then raise exception 'RP409: The output is not approved for import'; end if;
  if j.import_asset_id is not null then
   if j.import_asset_id::text is distinct from p_payload->>'asset_id' then raise exception 'RP409: Resume the existing output import'; end if;
  else
   select * into a from public.capture_assets where id=(p_payload->>'asset_id')::uuid and listing_id=j.listing_id for update;
   if not found or a.uploaded or a.upload_aborted or a.kind<>'video' or a.bucket<>'renders' or a.bytes<>j.output_bytes or a.content_type<>'video/mp4' or a.presenter_job_id is not null
    or not exists(select 1 from public.upload_reservations u where u.asset_id=a.id and u.org_id=j.org_id and u.state='open' and u.expires_at>now_at) then raise exception 'RP409: Reserve the exact output through the existing upload quota flow'; end if;
   update public.studio_presenter_jobs set import_asset_id=a.id,import_storage_key=a.storage_key,revision=revision+1,updated_at=now_at where id=j.id returning * into j;
   update public.capture_assets set presenter_job_id=j.id,sha256=j.output_sha256 where id=a.id;
  end if;
 elsif p_action='import_commit' then
  if j.state not in ('importing','imported') or not public.studio_presenter_asset_access(j.import_asset_id) then raise exception 'RP409: Approved output import is unavailable'; end if;
  select * into a from public.capture_assets where id=j.import_asset_id;
  if not a.uploaded or j.provenance_id is null or not exists(select 1 from public.media_provenance where id=j.provenance_id and altered_key=a.storage_key) then raise exception 'RP409: Confirm exact output upload and disclosure before importing'; end if;
  if j.state='importing' then update public.studio_presenter_jobs set state='imported',revision=revision+1,updated_at=now_at where id=j.id returning * into j; end if;
 elsif p_action in ('cleanup','cleanup_claim') then
  if j.cleanup_state<>'pending' or j.cleanup_deadline>now_at or coalesce(j.output_write_deadline,now_at-interval '2 minutes')+interval '1 minute'>now_at then return jsonb_build_object('claimed',false,'job',to_jsonb(j)); end if;
  token:=gen_random_uuid();
  update public.studio_presenter_jobs set cleanup_token=token,cleanup_deadline=now_at+interval '5 minutes' where id=j.id returning * into j;
  return jsonb_build_object('claimed',true,'cleanup_token',token,'targets',jsonb_build_array(jsonb_build_object('bucket','uploads','key',j.output_key))||case when j.import_storage_key is null then '[]'::jsonb else jsonb_build_array(jsonb_build_object('bucket','renders','key',j.import_storage_key)) end,'request_id',j.request_id,'cancel_url',j.cancel_url,'job',to_jsonb(j));
 elsif p_action in ('cleanup_complete','cleanup_done') then
  if j.cleanup_state<>'pending' or j.cleanup_token is distinct from (p_payload->>'cleanup_token')::uuid or j.cleanup_deadline<=now_at or coalesce(j.output_write_deadline,now_at-interval '2 minutes')+interval '1 minute'>now_at or p_payload->'objects_deleted' is distinct from 'true'::jsonb then raise exception 'RP409: Cleanup must wait for all private writes and confirm object deletion'; end if;
  update public.studio_presenter_jobs set cleanup_state='done',snapshot=null,probe=null,updated_at=now_at where id=j.id returning * into j;
 else raise exception 'RP400: Unsupported presenter worker action'; end if;
 return jsonb_build_object('job',to_jsonb(j));
exception when invalid_text_representation or numeric_value_out_of_range then raise exception 'RP400: Invalid presenter worker identity or number';
end;
$function$
;

do $$begin if(select md5(prosrc)from pg_proc where oid='public.studio_presenter_key_access(uuid,text)'::regprocedure)not in('073daf1423a67b4ad9334d4b07f8b5f1','85daf8021f869b1eb6c3cc0368f734e6')then raise exception 'Review changed function studio_presenter_key_access(uuid,text)';end if;end$$;
CREATE OR REPLACE FUNCTION public.studio_presenter_key_access(p_listing uuid, p_key text)
 RETURNS boolean
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare org uuid; item record;
begin
 select l.org_id into org from public.listings l join public.orgs o on o.id=l.org_id where l.id=p_listing and l.deleted_at is null and o.deleted_at is null;
 if org is null or p_key is null or length(p_key)>1024 then return false; end if;
 -- Historical media/provenance can predate canonical org/property keys. The
 -- exact existing property record establishes audit identity for those keys;
 -- an unknown legacy key or a foreign canonical scope is never authorized.
 -- URL-producing handlers retain their independent bucket/key scope checks.
 if not (p_key like 'uploads/'||org::text||'/'||p_listing::text||'/%' or p_key like 'renders/'||org::text||'/'||p_listing::text||'/%') then
  if p_key !~ '^(uploads|renders)/' or p_key ~* '^(uploads|renders)/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/'
   or not (exists(select 1 from public.capture_assets where listing_id=p_listing and storage_key=p_key)
    or exists(select 1 from public.renders where listing_id=p_listing and video_key=p_key)
    or exists(select 1 from public.media_provenance where listing_id=p_listing and (original_key=p_key or altered_key=p_key))) then return false; end if;
 end if;
 if current_setting('role',true)='authenticated' and not public.listing_content_access(auth.uid(),p_listing,false) then return false; end if;
 for item in select id from public.capture_assets where listing_id=p_listing and storage_key=p_key loop
  if not public.studio_presenter_media_access_inner(item.id) then return false; end if;
 end loop;
 -- Retained financial identity also guards a Presenter asset deleted from the
 -- property; cleanup may not yet have removed its public imported object.
 if exists(select 1 from public.studio_presenter_jobs j where j.listing_id=p_listing and j.import_storage_key=p_key and
   (j.state not in ('accepted','importing','imported') or not public.studio_presenter_job_valid(j))) then return false; end if;
 for item in select distinct asset_id from public.studio_presenter_media_sources where listing_id=p_listing and storage_key=p_key loop
  if not public.studio_presenter_media_access_inner(item.asset_id) then return false; end if;
 end loop;
 for item in select id from public.renders where listing_id=p_listing and video_key=p_key loop
  if not public.studio_presenter_render_access(item.id) then return false; end if;
 end loop;
 for item in select j.asset_id from public.video_erase_jobs j join public.video_erase_batches b on b.id=j.batch_id where b.listing_id=p_listing and j.output_key=p_key loop
  if not public.studio_presenter_media_access_inner(item.asset_id) then return false; end if;
 end loop;
 return true;
end;
$function$
;

do $$begin if(select md5(prosrc)from pg_proc where oid='public.studio_presenter_media_access(uuid)'::regprocedure)not in('c1449619960e3827b7f1d5f079d3f78b','7b8514cd27692ef9ade201fd33553a05')then raise exception 'Review changed function studio_presenter_media_access(uuid)';end if;end$$;
CREATE OR REPLACE FUNCTION public.studio_presenter_media_access(p_asset uuid)
 RETURNS boolean
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare org uuid;
begin
 select l.org_id into org from public.capture_assets a join public.listings l on l.id=a.listing_id join public.orgs o on o.id=l.org_id
  where a.id=p_asset and l.deleted_at is null and o.deleted_at is null;
 if org is null then return false; end if;
 if current_setting('role',true)='authenticated' and not public.listing_content_access(auth.uid(),(select listing_id from public.capture_assets where id=p_asset),false) then return false; end if;
 return public.studio_presenter_media_access_inner(p_asset);
end;
$function$
;

do $$begin if(select md5(prosrc)from pg_proc where oid='public.studio_presenter_render_access(uuid)'::regprocedure)not in('31d145be5e6e1dce7da3bbcd47a5fbd2','3a77c36362ed4a82f2e2d4ac50f56ede')then raise exception 'Review changed function studio_presenter_render_access(uuid)';end if;end$$;
CREATE OR REPLACE FUNCTION public.studio_presenter_render_access(p_render uuid)
 RETURNS boolean
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare asset uuid; org uuid;
begin
 select j.capture_asset_id,l.org_id into asset,org from public.renders r join public.render_jobs j on j.id=r.job_id
  join public.listings l on l.id=r.listing_id join public.orgs o on o.id=l.org_id where r.id=p_render and l.deleted_at is null and o.deleted_at is null;
 if org is null then return false; end if;
 if current_setting('role',true)='authenticated' and not public.listing_content_access(auth.uid(),(select listing_id from public.renders where id=p_render),false) then return false; end if;
 return asset is null or public.studio_presenter_media_access_inner(asset);
end;
$function$
;

do $$begin if(select md5(prosrc)from pg_proc where oid='public.studio_presenter_media_visibility(uuid,uuid[],uuid[],text[])'::regprocedure)not in('0bc4037e75eeeffa529d6ccc1bc087de','1e71ee81dc34215e7698e939725d5dc9')then raise exception 'Review changed function studio_presenter_media_visibility(uuid,uuid[],uuid[],text[])';end if;end$$;
CREATE OR REPLACE FUNCTION public.studio_presenter_media_visibility(p_listing uuid, p_assets uuid[] DEFAULT '{}'::uuid[], p_renders uuid[] DEFAULT '{}'::uuid[], p_keys text[] DEFAULT '{}'::text[])
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare assets jsonb:='{}'; renders jsonb:='{}'; keys jsonb:='{}'; item uuid; k text; org uuid;
begin
 if current_setting('role',true) not in ('service_role','authenticated') then raise insufficient_privilege using message='authenticated media scope required'; end if;
 if p_assets is null or p_renders is null or p_keys is null or cardinality(p_assets)+cardinality(p_renders)+cardinality(p_keys)>200 or array_position(p_assets,null) is not null or array_position(p_renders,null) is not null or array_position(p_keys,null) is not null then raise exception 'RP400: Choose a bounded media visibility batch'; end if;
 select l.org_id into org from public.listings l join public.orgs o on o.id=l.org_id where l.id=p_listing and l.deleted_at is null and o.deleted_at is null;
 if org is null or current_setting('role',true)='authenticated' and not public.listing_content_access(auth.uid(),p_listing,false) then raise exception 'RP404: Media property is unavailable'; end if;
 foreach item in array p_assets loop assets:=assets||jsonb_build_object(item::text,exists(select 1 from public.capture_assets where id=item and listing_id=p_listing) and public.studio_presenter_media_access_inner(item)); end loop;
 foreach item in array p_renders loop renders:=renders||jsonb_build_object(item::text,exists(select 1 from public.renders where id=item and listing_id=p_listing) and public.studio_presenter_render_access(item)); end loop;
 foreach k in array p_keys loop keys:=keys||jsonb_build_object(k,public.studio_presenter_key_access(p_listing,k)); end loop;
 return jsonb_build_object('assets',assets,'renders',renders,'keys',keys);
end;
$function$
;


create or replace function public.library_media_delivery_admit(p_actor uuid,p_org uuid,p_bytes bigint,p_required boolean default true)returns jsonb
language plpgsql security definer set search_path='' as $$declare b uuid;begin
 if current_setting('role',true)is distinct from 'service_role'then raise insufficient_privilege;end if;
 b:=public.library_actor_billing_org(p_actor,p_org);
 if b is null or not public.library_financial_actor(p_actor,p_org)then raise exception 'RP403: Current listing access required';end if;
 return public.media_delivery_admit(b,p_bytes,p_required);
end$$;
revoke all on function public.library_media_delivery_admit(uuid,uuid,bigint,boolean)from public,anon,authenticated;
grant execute on function public.library_media_delivery_admit(uuid,uuid,bigint,boolean)to service_role,postgres;


create or replace function public.stamp_render_financial_liability()returns trigger language plpgsql security definer set search_path='' as $$declare b uuid;begin
 if tg_op='UPDATE'and old.billing_org_id is not null then
  if new.billing_org_id is distinct from old.billing_org_id then raise exception 'RP409: Render billing identity is immutable';end if;return new;
 end if;
 b:=public.library_billing_org(public.listing_owner_library(new.listing_id));
 if b is null then raise exception 'RP403: Current render listing required';end if;
 if new.billing_org_id is not null and new.billing_org_id<>b then raise exception 'RP403: Render billing identity is server-owned';end if;
 new.billing_org_id:=b;return new;
end$$;
revoke all on function public.stamp_render_financial_liability()from public,anon,authenticated;
drop trigger if exists z_team_render_liability on public.render_jobs;
create trigger z_team_render_liability before insert or update on public.render_jobs for each row execute function public.stamp_render_financial_liability();
create or replace function public.library_storage_billing_org(p_org uuid,p_bucket text,p_key text)returns uuid
language plpgsql stable security definer set search_path='' as $$declare k text;q uuid;b uuid;begin
 k:=case when p_key like '_staging/%'then substr(p_key,10)else p_key end;
 -- Only an exact, live listing in the original physical namespace can project
 -- storage funding. A UUID-looking foreign key never changes ownership.
 if split_part(k,'/',2)=p_org::text and split_part(k,'/',3)~'^[a-f0-9]{8}(-[a-f0-9]{4}){3}-[a-f0-9]{12}$'then q:=split_part(k,'/',3)::uuid;
 elsif p_bucket='renders'and split_part(k,'/',1)='renders'and split_part(k,'/',2)~'^[a-f0-9]{8}(-[a-f0-9]{4}){3}-[a-f0-9]{12}$'then q:=split_part(k,'/',2)::uuid;end if;
 if q is not null and exists(select 1 from public.listings l where l.id=q and l.org_id=p_org and l.deleted_at is null)then
  b:=public.library_billing_org(public.listing_owner_library(q));end if;
 return coalesce(b,public.library_billing_org(p_org));
end$$;
revoke all on function public.library_storage_billing_org(uuid,text,text)from public,anon,authenticated;
grant execute on function public.library_storage_billing_org(uuid,text,text)to service_role,postgres;


create or replace function public.library_usage_summary(p_actor uuid,p_org uuid,p_since timestamptz)returns jsonb
language plpgsql stable security definer set search_path='' as $$declare a jsonb;b uuid;ids uuid[];begin
 a:=public.library_access(p_actor,p_org);b:=(a->>'billing_org_id')::uuid;ids:=public.library_listing_ids(p_actor,p_org);
 return jsonb_build_object('actor_id',p_actor,'org_id',p_org,'billing_org_id',b,
 'listings',(select count(*)from public.listings where id=any(ids)),
 'leads',(select count(*)from public.leads where listing_id=any(ids)),
 'leads_new',(select count(*)from public.leads where listing_id=any(ids)and status='new'),
 'render_count',(select count(*)from public.render_jobs where billing_org_id=b and source='worker'and(p_since is null or created_at>=p_since)),
 'cost_cents',public.serving_ceiling_spent_cents(b,p_since,null));
end$$;
revoke all on function public.library_usage_summary(uuid,uuid,timestamptz)from public,anon,authenticated;
grant execute on function public.library_usage_summary(uuid,uuid,timestamptz)to service_role,postgres;

CREATE OR REPLACE FUNCTION public.library_media_storage_reserve(p_actor uuid, p_org uuid, p_bucket text, p_key text, p_bytes bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare prior public.media_storage_receipts;b public.media_delivery_budgets;used numeric;k text;listing uuid;billing uuid;
begin
 if current_setting('role',true)is distinct from 'service_role'and pg_trigger_depth()=0 then raise insufficient_privilege;end if;
 if not public.library_financial_actor(p_actor,p_org)then raise exception 'RP403: Current content access required';end if;
 if p_org is null or p_bucket is null or p_bucket not in('uploads','renders')or p_key is null or length(p_key)not between 1 and 4096
  or p_key~'[[:cntrl:]\\%?#]'or p_key~'(^|/)\.\.?(/|$)'or p_bytes is null or p_bytes not between 1 and 12884901888 then raise exception 'RP400: Invalid stored media receipt';end if;
 perform 1 from public.orgs where id=p_org and deleted_at is null for update;
 if not found then raise exception 'RP403: Current storage workspace required';end if;
 billing:=coalesce((select billing_org_id from public.media_storage_receipts where bucket=p_bucket and object_key=p_key),public.library_actor_billing_org(p_actor,p_org));
 perform pg_advisory_xact_lock(hashtextextended('media-budget:'||billing,72453));
 k:=case when p_key like '_staging/%' then substr(p_key,10)else p_key end;
 if not ((p_bucket='uploads'and(split_part(k,'/',1)in('uploads','studio-project','ai-voice','presenter-private'))or
  p_bucket='renders'and split_part(k,'/',1)in('renders','ai-router','presenter-private','video-reflections'))and split_part(k,'/',2)=p_org::text)then
  -- Published Python renders retain their existing renders/<listing>/<render>
  -- namespace. Resolve the complete listing owner; do not rewrite tester URLs.
  if p_bucket<>'renders'or split_part(k,'/',1)<>'renders'or split_part(k,'/',2)!~'^[a-f0-9]{8}(-[a-f0-9]{4}){3}-[a-f0-9]{12}$'then raise exception 'RP403: Exact owned storage namespace required';end if;
  listing:=split_part(k,'/',2)::uuid;
  perform 1 from public.listings where id=listing and org_id=p_org and deleted_at is null for share;
  if not found then raise exception 'RP403: Exact owned render listing required';end if;
 end if;
 select * into b from public.media_delivery_budgets where org_id=billing and starts_at<=now()and ends_at>now()order by starts_at desc,id limit 1 for update;
 if not found then
  if exists(select 1 from public.serving_funding where org_id=billing)then raise exception 'RP503: Bounded media storage activation pending';end if;
 elsif b.funding_id is not null and not exists(select 1 from public.serving_funding where id=b.funding_id and org_id=billing and revoked_at is null and retention_ends_at>now())then raise exception 'RP403: Current media storage funding required';end if;
 -- Each reserve, including replay, spends one request before a possible PUT.
 -- No missing response or repeated exact key restores the write allowance.
 if b.id is not null then
  if b.used_requests>=b.request_limit then raise exception 'RP429: Media write request allowance exhausted';end if;
  update public.media_delivery_budgets set used_requests=used_requests+1 where id=b.id;
 end if;
 select * into prior from public.media_storage_receipts where bucket=p_bucket and object_key=p_key;
 if found then
  if row(prior.org_id,prior.bytes)is distinct from row(p_org,p_bytes)or prior.deleted_at is not null then raise exception 'RP409: Stored media receipt is immutable';end if;
  return jsonb_build_object('reserved',true,'replay',true);end if;
 if b.funding_id is not null and not exists(select 1 from public.serving_funding where id=b.funding_id and org_id=billing and revoked_at is null and ends_at>now())then raise exception 'RP403: Current media write funding required';end if;
 -- Physical liability survives budget rollover and metadata/account deletion.
 select coalesce(sum(bytes),0)into used from public.media_storage_receipts where billing_org_id=billing and deleted_at is null;
 if b.id is not null and p_bytes>b.storage_limit-used then raise exception 'RP429: Stored media allowance exhausted';end if;
 insert into public.media_storage_receipts(org_id,billing_org_id,actor_id,bucket,object_key,bytes)values(p_org,billing,p_actor,p_bucket,p_key,p_bytes);
 return jsonb_build_object('reserved',true,'replay',false,'legacy_unbudgeted',b.id is null);
end$function$
;
revoke all on function public.library_media_storage_reserve(uuid,uuid,text,text,bigint)from public,anon,authenticated;
grant execute on function public.library_media_storage_reserve(uuid,uuid,text,text,bigint)to service_role,postgres;

create or replace function public.current_new_listing_access(p_org uuid,p_agent uuid)returns boolean language sql stable security definer set search_path='' as $$
 select public.library_content_access(auth.uid(),p_org,true)and (p_agent=auth.uid()or public.library_team_owner(p_org)=auth.uid()and exists(select 1 from public.memberships where org_id=p_org and user_id=p_agent and role='owner'));$$;
revoke all on function public.current_new_listing_access(uuid,uuid)from public,anon;
grant execute on function public.current_new_listing_access(uuid,uuid)to authenticated,service_role;
create or replace function public.is_org_member(target uuid)returns boolean language sql stable security definer set search_path='' as $$
 select exists(select 1 from public.memberships m where m.org_id=target and m.user_id=auth.uid())and public.library_content_access(auth.uid(),target,false);$$;
create or replace function public.org_role(target uuid)returns text language sql stable security definer set search_path='' as $$
 select case when public.library_team_owner(target)=auth.uid()then 'agent'else m.role end from public.memberships m
 where m.org_id=target and m.user_id=auth.uid()and public.library_content_access(auth.uid(),target,false)
 union all select 'agent'where public.library_team_owner(target)=auth.uid()and not exists(select 1 from public.memberships where org_id=target and user_id=auth.uid())limit 1;$$;
create or replace function public.current_listing_access(p_listing uuid,p_write boolean default false)returns boolean language sql stable security definer set search_path='' as $$
 select public.listing_content_access(auth.uid(),p_listing,p_write);$$;
create or replace function public.org_month_spend_cents(p_org uuid)returns numeric language plpgsql stable security definer set search_path='' as $$
begin
 if not(current_setting('role',true)in('service_role','postgres','supabase_admin')or(session_user=current_user and current_setting('role',true)='none')or public.library_content_access(auth.uid(),p_org,false))then return 0;end if;
 -- Every finance path uses the same immutable parent liability. Booked
 -- expenses are month-bound; unresolved provider holds carry through rollover.
 return public.serving_ceiling_spent_cents(public.library_billing_org(p_org),date_trunc('month',now()),date_trunc('month',now())+interval '1 month');
end$$;

do $$declare r record;begin for r in select policyname from pg_policies where schemaname='public'and tablename='listings'loop execute format('drop policy %I on public.listings',r.policyname);end loop;end$$;

do $$declare r record;begin for r in select policyname from pg_policies where schemaname='public'and tablename='capture_assets'loop execute format('drop policy %I on public.capture_assets',r.policyname);end loop;end$$;

do $$declare r record;begin for r in select policyname from pg_policies where schemaname='public'and tablename='capture_chapters'loop execute format('drop policy %I on public.capture_chapters',r.policyname);end loop;end$$;

do $$declare r record;begin for r in select policyname from pg_policies where schemaname='public'and tablename='photos'loop execute format('drop policy %I on public.photos',r.policyname);end loop;end$$;

do $$declare r record;begin for r in select policyname from pg_policies where schemaname='public'and tablename='render_jobs'loop execute format('drop policy %I on public.render_jobs',r.policyname);end loop;end$$;

do $$declare r record;begin for r in select policyname from pg_policies where schemaname='public'and tablename='renders'loop execute format('drop policy %I on public.renders',r.policyname);end loop;end$$;

do $$declare r record;begin for r in select policyname from pg_policies where schemaname='public'and tablename='leads'loop execute format('drop policy %I on public.leads',r.policyname);end loop;end$$;

do $$declare r record;begin for r in select policyname from pg_policies where schemaname='public'and tablename='media_provenance'loop execute format('drop policy %I on public.media_provenance',r.policyname);end loop;end$$;


create policy "private listings read"on public.listings for select to authenticated using(public.current_listing_access(id,false));
create policy "private listings insert"on public.listings for insert to authenticated with check(public.current_new_listing_access(org_id,agent_id));
create policy "private listings update"on public.listings for update to authenticated using(public.current_listing_access(id,true))with check(public.current_listing_access(id,true));

create policy "private capture_assets read"on public.capture_assets for select to authenticated using(public.current_listing_access(listing_id,false));

create policy "private photos read"on public.photos for select to authenticated using(public.current_listing_access(listing_id,false));

create policy "private render_jobs read"on public.render_jobs for select to authenticated using(public.current_listing_access(listing_id,false));

create policy "private renders read"on public.renders for select to authenticated using(public.current_listing_access(listing_id,false));

create policy "private leads read"on public.leads for select to authenticated using(public.current_listing_access(listing_id,false));

create policy "private photos insert"on public.photos for insert to authenticated with check(public.current_listing_access(listing_id,true));

create policy "private photos update"on public.photos for update to authenticated using(public.current_listing_access(listing_id,true))with check(public.current_listing_access(listing_id,true));

create policy "private photos delete"on public.photos for delete to authenticated using(public.current_listing_access(listing_id,true));

create policy "private chapters read"on public.capture_chapters for select to authenticated using(exists(select 1 from public.capture_assets a where a.id=asset_id and public.current_listing_access(a.listing_id,false)));

create policy "private provenance read"on public.media_provenance for select to authenticated using((listing_id is null and public.is_org_member(org_id))or public.current_listing_access(listing_id,false));

revoke all on function public.team_library_owner(uuid) from public,anon,authenticated;
grant execute on function public.team_library_owner(uuid) to service_role,postgres;

revoke all on function public.team_library_binding_valid(uuid) from public,anon,authenticated;
grant execute on function public.team_library_binding_valid(uuid) to service_role,postgres;

revoke all on function public.library_billing_org(uuid) from public,anon,authenticated;
grant execute on function public.library_billing_org(uuid) to service_role,postgres;

revoke all on function public.library_team_owner(uuid) from public,anon,authenticated;
grant execute on function public.library_team_owner(uuid) to service_role,postgres;

revoke all on function public.library_team_org(uuid) from public,anon,authenticated;
grant execute on function public.library_team_org(uuid) to service_role,postgres;

revoke all on function public.library_content_access(uuid,uuid,boolean) from public,anon,authenticated;
grant execute on function public.library_content_access(uuid,uuid,boolean) to service_role,postgres;

revoke all on function public.library_access(uuid,uuid) from public,anon,authenticated;
grant execute on function public.library_access(uuid,uuid) to service_role,postgres;

revoke all on function public.listing_content_access(uuid,uuid,boolean) from public,anon,authenticated;
grant execute on function public.listing_content_access(uuid,uuid,boolean) to service_role,postgres;

revoke all on function public.agent_private_library(uuid) from public,anon,authenticated;
grant execute on function public.agent_private_library(uuid) to service_role,postgres;

revoke all on function public.listing_library_scope(uuid,uuid) from public,anon,authenticated;
grant execute on function public.listing_library_scope(uuid,uuid) to service_role,postgres;

revoke all on function public.list_library_listings(uuid,uuid,integer,integer) from public,anon,authenticated;
grant execute on function public.list_library_listings(uuid,uuid,integer,integer) to service_role,postgres;

revoke all on function public.bind_team_private_library(uuid,uuid,uuid,uuid) from public,anon,authenticated;
grant execute on function public.bind_team_private_library(uuid,uuid,uuid,uuid) to service_role,postgres;

revoke all on function public.library_scope_role(uuid,uuid,uuid) from public,anon,authenticated;
grant execute on function public.library_scope_role(uuid,uuid,uuid) to service_role,postgres;

revoke all on function public.library_financial_actor(uuid,uuid) from public,anon,authenticated;
grant execute on function public.library_financial_actor(uuid,uuid) to service_role,postgres;

revoke all on function public.library_actor_billing_org(uuid,uuid) from public,anon,authenticated;
grant execute on function public.library_actor_billing_org(uuid,uuid) to service_role,postgres;

revoke all on function public.stamp_library_financial_liability() from public,anon,authenticated,service_role;
revoke all on function public.current_listing_access(uuid,boolean) from public,anon;
grant execute on function public.current_listing_access(uuid,boolean) to authenticated,service_role;

-- Reflection quota receipts use the shared admitted liability, including
-- cancellation and definite no-charge rejection. No provider or price changes.
do $$begin if(select md5(prosrc)from pg_proc where oid='public.video_erase_reserve(uuid,uuid,uuid,uuid,uuid,uuid,text,numeric)'::regprocedure)not in('6cde2e03bdfeb309125d77490f588899','bc287832ef01a09b4452b61d1715ec22')then raise exception 'Review changed function video_erase_reserve(uuid,uuid,uuid,uuid,uuid,uuid,text,numeric)';end if;end$$;
CREATE OR REPLACE FUNCTION public.video_erase_reserve(p_org uuid, p_user uuid, p_listing uuid, p_batch uuid, p_asset uuid, p_idem uuid, p_hash text, p_seconds numeric DEFAULT NULL::numeric)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare e plan_entitlements; a capture_assets; b video_erase_batches; j video_erase_jobs;
  cost numeric; batch_cost numeric; mw timestamptz; bw timestamptz; billing uuid;
begin
  perform video_erase_authorize(p_org,p_user,p_listing);
  if not public.studio_presenter_media_access(p_asset) then raise exception 'RP409: Presenter source approval is no longer available'; end if;
  billing:=public.library_actor_billing_org(p_user,p_org);
  perform pg_advisory_xact_lock(hashtextextended('org_month_spend:'||billing::text,42));
  perform 1 from public.orgs where id=billing and deleted_at is null for update;
  if not found then raise exception 'RP403: Current serving library is required';end if;
  perform video_erase_authorize(p_org,p_user,p_listing);
  if public.library_actor_billing_org(p_user,p_org)is distinct from billing then raise exception 'RP403: Serving library changed';end if;
  -- Parent lock serializes shared finite reservations; content identities stay original.
  perform video_erase_expire(p_org);
  select * into j from video_erase_jobs where org_id=p_org and user_id=p_user and idempotency_key=p_idem;
  if found then
    if j.request_hash<>p_hash or j.batch_id<>p_batch or j.asset_id<>p_asset then raise exception 'RP409: Idempotency key was used for a different request'; end if;
    return jsonb_build_object('dispatch',false,'job',to_jsonb(j));
  end if;
  if p_batch is null or p_asset is null or p_idem is null or p_hash is null or p_hash !~ '^[a-f0-9]{64}$' then raise exception 'RP400: Invalid reflection request'; end if;
  select * into a from capture_assets where id=p_asset and listing_id=p_listing for share;
  if not found or not a.uploaded or a.bucket<>'renders' or a.kind<>'video' then raise exception 'RP400: A completed public video upload from this listing is required'; end if;
  if a.duration_s is null then raise exception 'RP409: Upload must have a probed duration'; end if;
  if not (a.duration_s>0 and a.duration_s<5) then raise exception 'RP400: Reflection clips must have positive finite duration under five seconds'; end if;
  if p_seconds is null then p_seconds:=a.duration_s; end if;
  if not(p_seconds>0 and p_seconds<5) or abs(p_seconds-a.duration_s)>0.15 then raise exception 'RP400: Probed clip duration does not match upload'; end if;
  cost:=p_seconds*14;
  select * into b from video_erase_batches where id=p_batch for update;
  if found then
    if b.org_id<>p_org or b.user_id<>p_user then raise exception 'RP404: Batch not found'; end if;
    if b.state<>'open' then raise exception 'RP409: This reflection batch is closed'; end if;
    if b.listing_id<>p_listing then raise exception 'RP404: Batch not found'; end if;
  else
    insert into video_erase_batches(id,org_id,user_id,listing_id) values(p_batch,p_org,p_user,p_listing);
  end if;
  if exists(select 1 from video_erase_jobs where batch_id=p_batch and asset_id=p_asset) then raise exception 'RP409: This clip already has a reflection job; reuse its idempotency key'; end if;
  select coalesce(sum(cost_cents),0) into batch_cost from video_erase_jobs where batch_id=p_batch;
  if batch_cost+cost>240 then raise exception 'RP402: Reflection batch exceeds its processing budget'; end if;
  e:=org_entitlement(billing);
  if e.reels_per_month<=0 then raise exception 'RP402: Your plan does not include AI clips'; end if;
  if org_month_spend_cents(billing)+cost>e.cogs_ceiling_cents then raise exception 'RP402: Workspace processing budget reached'; end if;
  if public.serving_mode()='ceiling' then perform public.library_serving_envelope_admit(p_org,billing,cost,p_idem::text); end if;
  if not bump_rate('aivideo:'||billing,300,12,1) then raise exception 'RP429: Too many video jobs; try again later'; end if;
  select window_start into bw from rate_limits where key='aivideo:'||billing;
  if not bump_rate('reelmo:'||billing,2592000,e.reels_per_month,1) then raise exception 'RP402: Monthly AI clip allowance reached'; end if;
  select window_start into mw from rate_limits where key='reelmo:'||billing;
  -- The claim commits BEFORE the network boundary. No caller can claim it again,
  -- even after a crash or an ambiguous provider response. A new paid retry is never automatic.
  insert into video_erase_jobs(org_id,user_id,batch_id,asset_id,idempotency_key,request_hash,duration_s,cost_cents,state,monthly_window,burst_window)
    values(p_org,p_user,p_batch,p_asset,p_idem,p_hash,p_seconds,cost,'dispatching',mw,bw) returning * into j;
  return jsonb_build_object('dispatch',true,'job',to_jsonb(j));
end $function$
;
do $$begin if(select md5(prosrc)from pg_proc where oid='public.video_erase_reserve_direct(uuid,uuid,uuid,uuid,uuid,uuid,text,numeric,jsonb,text)'::regprocedure)not in('e92ecad94fec42578bf3087d8fce00e0','52a1af44d414cc17f501dab7ea2081bc')then raise exception 'Review changed function video_erase_reserve_direct(uuid,uuid,uuid,uuid,uuid,uuid,text,numeric,jsonb,text)';end if;end$$;
CREATE OR REPLACE FUNCTION public.video_erase_reserve_direct(p_org uuid, p_user uuid, p_listing uuid, p_batch uuid, p_asset uuid, p_idem uuid, p_hash text, p_seconds numeric, p_config jsonb, p_consent text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare e plan_entitlements; a capture_assets; b video_erase_batches; j video_erase_jobs;
  cost numeric; mask_rate numeric; erase_rate numeric; config jsonb; batch_cost numeric; mw timestamptz; bw timestamptz; billing uuid;
begin
  perform video_erase_authorize(p_org,p_user,p_listing);
  -- Preserve the existing Presenter gate before idempotent replay and paid
  -- admission, including reflected/browser-edited descendants of that source.
  if not public.studio_presenter_media_access(p_asset) then raise exception 'RP409: Presenter source approval is no longer available'; end if;
  billing:=public.library_actor_billing_org(p_user,p_org);
  perform pg_advisory_xact_lock(hashtextextended('org_month_spend:'||billing::text,42));
  perform 1 from public.orgs where id=billing and deleted_at is null for update;
  if not found then raise exception 'RP403: Current serving library is required';end if;
  perform video_erase_authorize(p_org,p_user,p_listing);
  if public.library_actor_billing_org(p_user,p_org)is distinct from billing then raise exception 'RP403: Serving library changed';end if;
  -- Parent lock serializes shared finite reservations; content identities stay original.
  perform video_erase_expire(p_org);
  select * into j from video_erase_jobs where org_id=p_org and user_id=p_user and idempotency_key=p_idem;
  if found then
    if j.request_hash<>p_hash or j.batch_id<>p_batch or j.asset_id<>p_asset then raise exception 'RP409: Idempotency key was used for a different request'; end if;
    return jsonb_build_object('dispatch',false,'job',video_erase_job_json(j.id));
  end if;
  if p_batch is null or p_asset is null or p_idem is null or p_hash is null or p_hash !~ '^[a-f0-9]{64}$' then raise exception 'RP400: Invalid reflection request'; end if;
  select * into a from capture_assets where id=p_asset and listing_id=p_listing for share;
  if not found or not a.uploaded or a.bucket<>'renders' or a.kind<>'video' then raise exception 'RP400: A completed public video upload from this listing is required'; end if;
  if a.duration_s is null then raise exception 'RP409: Upload must have a probed duration'; end if;
  if not (a.duration_s>0 and a.duration_s<5) then raise exception 'RP400: Reflection clips must have positive finite duration under five seconds'; end if;
  if p_seconds is null then p_seconds:=a.duration_s; end if;
  if not(p_seconds>0 and p_seconds<5) or abs(p_seconds-a.duration_s)>0.15 then raise exception 'RP400: Probed clip duration does not match upload'; end if;
  if p_consent is distinct from 'bria-video-v1' then raise exception 'RP403: Direct Bria processing consent is required'; end if;
  if p_config is null or jsonb_typeof(p_config->'mask_unit_cost_cents') is distinct from 'number'
    or jsonb_typeof(p_config->'erase_unit_cost_cents') is distinct from 'number'
    or coalesce(p_config->>'price_version','') !~ '^[A-Za-z0-9_.:-]{1,120}$'
    or jsonb_typeof(p_config->'output_hosts') is distinct from 'array'
    or jsonb_array_length(p_config->'output_hosts') not between 1 and 16
    or exists(select 1 from jsonb_array_elements_text(p_config->'output_hosts') h where h !~ '^[a-z0-9][a-z0-9.-]*[a-z0-9]$' or h like '%..%') then
    raise exception 'RP400: Confirmed account-specific Bria pricing and output hosts are required';
  end if;
  mask_rate:=(p_config->>'mask_unit_cost_cents')::numeric; erase_rate:=(p_config->>'erase_unit_cost_cents')::numeric;
  if not(mask_rate>0 and mask_rate<=240 and erase_rate>0 and erase_rate<=240)
    or round(mask_rate,6)<>mask_rate or round(erase_rate,6)<>erase_rate then raise exception 'RP400: Invalid Bria price'; end if;
  config:=jsonb_build_object('mask_model','/v2/video/segment/mask_by_prompt','erase_model','/v2/video/edit/erase',
    'mask_unit_cost_cents',mask_rate,'erase_unit_cost_cents',erase_rate,
    'price_version',p_config->>'price_version','output_hosts',p_config->'output_hosts','consent_version',p_consent);
  cost:=round(p_seconds*mask_rate,6)+round(p_seconds*erase_rate,6);
  select * into b from video_erase_batches where id=p_batch for update;
  if found then
    if b.org_id<>p_org or b.user_id<>p_user then raise exception 'RP404: Batch not found'; end if;
    if b.state<>'open' then raise exception 'RP409: This reflection batch is closed'; end if;
    if b.listing_id<>p_listing then raise exception 'RP404: Batch not found'; end if;
  else
    insert into video_erase_batches(id,org_id,user_id,listing_id) values(p_batch,p_org,p_user,p_listing);
  end if;
  if exists(select 1 from video_erase_jobs where batch_id=p_batch and asset_id=p_asset) then raise exception 'RP409: This clip already has a reflection job; reuse its idempotency key'; end if;
  select coalesce(sum(cost_cents),0) into batch_cost from video_erase_jobs where batch_id=p_batch;
  if batch_cost+cost>240 then raise exception 'RP402: Reflection batch exceeds its processing budget'; end if;
  e:=org_entitlement(billing);
  if e.reels_per_month<=0 then raise exception 'RP402: Your plan does not include AI clips'; end if;
  if org_month_spend_cents(billing)+cost>e.cogs_ceiling_cents then raise exception 'RP402: Workspace processing budget reached'; end if;
  if public.serving_mode()='ceiling' then perform public.library_serving_envelope_admit(p_org,billing,cost,p_idem::text); end if;
  if not bump_rate('aivideo:'||billing,300,12,1) then raise exception 'RP429: Too many video jobs; try again later'; end if;
  select window_start into bw from rate_limits where key='aivideo:'||billing;
  if not bump_rate('reelmo:'||billing,2592000,e.reels_per_month,1) then raise exception 'RP402: Monthly AI clip allowance reached'; end if;
  select window_start into mw from rate_limits where key='reelmo:'||billing;
  -- The claim commits BEFORE the network boundary. No caller can claim it again,
  -- even after a crash or an ambiguous provider response. A new paid retry is never automatic.
  insert into video_erase_jobs(org_id,user_id,batch_id,asset_id,idempotency_key,request_hash,duration_s,cost_cents,state,monthly_window,burst_window,provider,provider_config)
    values(p_org,p_user,p_batch,p_asset,p_idem,p_hash,p_seconds,cost,'dispatching',mw,bw,'bria',config) returning * into j;
  insert into video_erase_stages(job_id,stage,state,cost_cents,unit_cost_cents,admitted_at) values
    (j.id,'mask','dispatching',p_seconds*mask_rate,mask_rate,now()),
    (j.id,'erase','pending',p_seconds*erase_rate,erase_rate,null);
  return jsonb_build_object('dispatch',true,'job',video_erase_job_json(j.id));
end $function$
;
do $$begin if(select md5(prosrc)from pg_proc where oid='public.video_erase_finish(uuid,text,jsonb,text,text,text,boolean)'::regprocedure)not in('69a6e447ed822ce736ef5eda16af4474','2ca13f6ef363419b03f02a134443a530')then raise exception 'Review changed function video_erase_finish(uuid,text,jsonb,text,text,text,boolean)';end if;end$$;
CREATE OR REPLACE FUNCTION public.video_erase_finish(p_job uuid, p_state text, p_ref jsonb DEFAULT NULL::jsonb, p_url text DEFAULT NULL::text, p_key text DEFAULT NULL::text, p_error text DEFAULT NULL::text, p_no_charge boolean DEFAULT false)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare j video_erase_jobs; ledger uuid; oid uuid;
begin
  select billing_org_id into oid from video_erase_jobs where id=p_job;
  if oid is null then raise exception 'RP404: Reflection job not found'; end if;
  perform pg_advisory_xact_lock(hashtextextended('org_month_spend:'||oid::text,42));
  perform 1 from orgs where id=oid for update;
  select * into j from video_erase_jobs where id=p_job for update;
  if p_state not in ('processing','completed','failed','uncertain','cancelled') then raise exception 'RP400: Invalid reflection job state'; end if;
  if p_state='completed' and (p_url is null or p_key is null or (j.provider='fal' and p_ref is null)) then raise exception 'RP400: Completed output must be persisted'; end if;
  -- A confirmed provider receipt records real published-rate COGS once, even if
  -- the user cancelled. No provider receipt => hold remains for reconciliation.
  if j.provider='bria' and p_ref is not null then raise exception 'RP400: Direct provider receipts belong to a stage'; end if;
  if j.provider='bria' and p_state='completed' and (p_key<>'video-reflections/'||j.org_id||'/'||j.id||'.mp4' or (select count(*) from video_erase_stages where job_id=j.id and state='completed')<>2) then raise exception 'RP400: Direct output requires completed stages and its scoped storage key'; end if;
  if j.provider='fal' and p_ref is not null and j.cost_ledger_id is null then
    insert into cost_ledger(org_id,feature,provider,model,units,unit_cost_cents,total_cents,meta)
    values(j.org_id,'video_declutter','fal','bria/video/erase/prompt',j.duration_s,14,j.cost_cents,
      jsonb_build_object('erase_job_id',j.id,'batch_id',j.batch_id,'request_key',j.idempotency_key::text,'stage','reflection.fal','request_id',p_ref->>'request_id',
        'price_estimated',false,'price_basis','authenticated fal pricing API input-second rate','price_verified_at','2026-09-19',
        'price_source','https://api.fal.ai/v1/models/pricing?endpoint_id=bria%2Fvideo%2Ferase%2Fprompt','billing_reconciled',false)) returning id into ledger;
    j.cost_ledger_id:=ledger;
  end if;
  if j.state not in ('completed','failed','uncertain','cancelled') then j.state:=p_state; end if;
  -- Exact-window refund: a late failure/cancel cannot mint quota in a new window.
  if j.state in ('failed','uncertain','cancelled') and j.allowance_refunded_at is null then
    update rate_limits set count=greatest(0,count-1) where key='reelmo:'||j.billing_org_id
      and window_start=j.monthly_window and window_seconds=2592000 and window_start>=now()-interval '30 days';
    update rate_limits set count=greatest(0,count-1) where key='aivideo:'||j.billing_org_id
      and window_start=j.burst_window and window_seconds=300 and window_start>=now()-interval '300 seconds';
    j.allowance_refunded_at:=now();
  end if;
  if p_no_charge and p_state='failed' and j.provider_ref is null and p_ref is null and j.cost_ledger_id is null then
    j.cost_hold_released_at:=coalesce(j.cost_hold_released_at,now());
  end if;
  update video_erase_jobs set state=j.state,provider_ref=coalesce(provider_ref,p_ref),
    output_url=case when j.state='completed' then coalesce(output_url,p_url) else output_url end,
    output_key=case when j.state='completed' then coalesce(output_key,p_key) else output_key end,
    error=coalesce(error,left(p_error,300)),cost_ledger_id=j.cost_ledger_id,
    allowance_refunded_at=j.allowance_refunded_at,cost_hold_released_at=j.cost_hold_released_at,updated_at=now() where id=p_job returning * into j;
  if j.provider='bria' and j.state in ('failed','uncertain','cancelled') then
    update video_erase_stages set state='cancelled',cost_hold_released_at=coalesce(cost_hold_released_at,now()),updated_at=now() where job_id=j.id and state='pending';
  end if;
  if not public.studio_presenter_media_access(j.asset_id) then
    return video_erase_job_json(j.id)||jsonb_build_object('state','cancelled','output_url',null,
      'output_key',null,'error','Presenter source approval is no longer available');
  end if;
  return video_erase_job_json(j.id);
end $function$
;
do $$begin if(select md5(prosrc)from pg_proc where oid='public.video_erase_finish_stage(uuid,text,text,jsonb,text,boolean)'::regprocedure)not in('3e76ee132e3cc9e64d8b7bab34296500','16de9576cfcf2e718378ba0d6cc37251')then raise exception 'Review changed function video_erase_finish_stage(uuid,text,text,jsonb,text,boolean)';end if;end$$;
CREATE OR REPLACE FUNCTION public.video_erase_finish_stage(p_job uuid, p_stage text, p_state text, p_ref jsonb DEFAULT NULL::jsonb, p_output text DEFAULT NULL::text, p_no_charge boolean DEFAULT false)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare j video_erase_jobs; s video_erase_stages; oid uuid; ledger uuid;
begin
  select billing_org_id into oid from video_erase_jobs where id=p_job;
  if oid is null then raise exception 'RP404: Reflection job not found'; end if;
  perform pg_advisory_xact_lock(hashtextextended('org_month_spend:'||oid::text,42));
  perform 1 from orgs where id=oid for update;
  select * into j from video_erase_jobs where id=p_job for update;
  select * into s from video_erase_stages where job_id=p_job and stage=p_stage for update;
  if j.provider<>'bria' or s.job_id is null or p_state not in ('processing','completed','failed','uncertain') then raise exception 'RP400: Invalid direct stage transition'; end if;
  if s.admitted_at is null then raise exception 'RP409: The paid stage must be admitted before its receipt'; end if;
  if s.provider_ref is not null and p_ref is not null and s.provider_ref<>p_ref then raise exception 'RP409: Provider stage receipt is immutable'; end if;
  if s.output_url is not null and p_output is not null and s.output_url<>p_output then raise exception 'RP409: Provider stage output is immutable'; end if;
  if p_state='completed' and (coalesce(s.provider_ref,p_ref) is null or p_output is null) then raise exception 'RP400: Completed stage requires a provider reference and output'; end if;
  -- A receipt is charged exactly once even if cancellation raced the response.
  if p_ref is not null and s.cost_ledger_id is null then
    insert into cost_ledger(org_id,feature,provider,model,units,unit_cost_cents,total_cents,meta)
    values(j.org_id,'video_declutter','bria',case when p_stage='mask' then '/v2/video/segment/mask_by_prompt' else '/v2/video/edit/erase' end,
      j.duration_s,s.unit_cost_cents,s.cost_cents,jsonb_build_object('erase_job_id',j.id,'batch_id',j.batch_id,'request_key',j.id::text,'stage','reflection.'||p_stage,
      'request_id',p_ref->>'request_id','price_estimated',false,'price_basis','confirmed account-specific input-second rate',
      'price_version',j.provider_config->>'price_version','billing_reconciled',false)) returning id into ledger;
    s.cost_ledger_id:=ledger;
  end if;
  if s.state not in ('completed','failed','uncertain','cancelled') then s.state:=p_state; end if;
  if p_no_charge and p_state='failed' and s.provider_ref is null and p_ref is null and s.cost_ledger_id is null then
    s.cost_hold_released_at:=coalesce(s.cost_hold_released_at,now());
  end if;
  update video_erase_stages set state=s.state,provider_ref=coalesce(provider_ref,p_ref),
    output_url=coalesce(output_url,p_output),cost_ledger_id=s.cost_ledger_id,cost_hold_released_at=s.cost_hold_released_at,updated_at=now()
    where job_id=p_job and stage=p_stage;
  if j.state not in ('completed','failed','uncertain','cancelled') then
    if s.state in ('failed','uncertain') then
      perform video_erase_finish(j.id,s.state,null,null,null,
        'Reflection provider processing could not be completed. Your AI clip allowance was returned; no automatic retry was made.');
    else update video_erase_jobs set state='processing',updated_at=now() where id=j.id; end if;
  end if;
  -- No unpaid later stage may survive a terminal job. Already dispatched spend
  -- keeps its ledger/hold until reconciliation, as with legacy fal jobs.
  if (select state from video_erase_jobs where id=j.id) in ('failed','uncertain','cancelled') then
    update video_erase_stages set state='cancelled',cost_hold_released_at=coalesce(cost_hold_released_at,now()),updated_at=now()
      where job_id=j.id and state='pending';
  end if;
  return video_erase_job_json(j.id);
end $function$
;
do $$begin if(select md5(prosrc)from pg_proc where oid='public.video_erase_cancel(uuid,uuid,uuid,uuid)'::regprocedure)not in('2bbc6851148f3f751ee1f08bcc1d7f29','455f51693f167b32c9813779f5ec7c09')then raise exception 'Review changed function video_erase_cancel(uuid,uuid,uuid,uuid)';end if;end$$;
CREATE OR REPLACE FUNCTION public.video_erase_cancel(p_org uuid, p_user uuid, p_job uuid DEFAULT NULL::uuid, p_batch uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare bid uuid; b video_erase_batches; j video_erase_jobs; count_jobs integer:=0;
begin
  perform video_erase_authorize(p_org,p_user);
  perform pg_advisory_xact_lock(hashtextextended('org_month_spend:'||public.library_actor_billing_org(p_user,p_org)::text,42));
  perform 1 from orgs where id=public.library_actor_billing_org(p_user,p_org) for update;
  if (p_job is null)=(p_batch is null) then raise exception 'RP400: Supply one request_id or batch_id'; end if;
  if p_job is not null then
    select batch_id into bid from video_erase_jobs where id=p_job and org_id=p_org and user_id=p_user;
    if not found then raise exception 'RP404: Reflection job not found'; end if;
  else bid:=p_batch; end if;
  select * into b from video_erase_batches where id=bid and org_id=p_org and user_id=p_user for update;
  if not found then
    if p_batch is null then raise exception 'RP404: Reflection batch not found'; end if;
    -- Cancellation can beat the first upload/POST. Reserve sees this durable
    -- tombstone and refuses a late request without consuming quota or dispatch.
    insert into video_erase_batches(id,org_id,user_id,state)
      values(p_batch,p_org,p_user,'cancelled') on conflict(id) do nothing;
    select * into b from video_erase_batches where id=bid and org_id=p_org and user_id=p_user for update;
    if not found then raise exception 'RP404: Reflection batch not found'; end if;
  end if;
  if b.state='applied' then raise exception 'RP409: Accepted reflection batch cannot be cancelled'; end if;
  update video_erase_batches set state='cancelled' where id=bid;
  for j in select * from video_erase_jobs where batch_id=bid order by id for update loop
    -- Discarding a completed edit refunds its allowance too; COGS stays recorded.
    if j.allowance_refunded_at is null then
      update rate_limits set count=greatest(0,count-1) where key='reelmo:'||j.billing_org_id and window_start=j.monthly_window and window_seconds=2592000 and window_start>=now()-interval '30 days';
      update rate_limits set count=greatest(0,count-1) where key='aivideo:'||j.billing_org_id and window_start=j.burst_window and window_seconds=300 and window_start>=now()-interval '300 seconds';
    end if;
    update video_erase_stages set state='cancelled',cost_hold_released_at=coalesce(cost_hold_released_at,now()),updated_at=now() where job_id=j.id and state='pending';
    update video_erase_jobs set state='cancelled',allowance_refunded_at=coalesce(allowance_refunded_at,now()),updated_at=now() where id=j.id;
    count_jobs:=count_jobs+1;
  end loop;
  return jsonb_build_object('status','cancelled','batch_id',bid,'cancelled_clips',count_jobs);
end $function$
;
do $$begin if(select md5(prosrc)from pg_proc where oid='public.video_erase_expire(uuid)'::regprocedure)not in('e226131e633742b6d824e04d984ccd73','15561372c43b0bd06a4956e70531299a')then raise exception 'Review changed function video_erase_expire(uuid)';end if;end$$;
CREATE OR REPLACE FUNCTION public.video_erase_expire(p_org uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare j video_erase_jobs;
begin
  perform pg_advisory_xact_lock(hashtextextended('org_month_spend:'||public.library_billing_org(p_org)::text,42));
  perform 1 from orgs where id=public.library_billing_org(p_org) for update;
  for j in select * from video_erase_jobs where org_id=p_org and state in ('dispatching','processing')
    and ((provider='fal' and ((state='dispatching' and created_at<now()-interval '2 minutes') or (state='processing' and created_at<now()-interval '30 minutes')))
      or (provider='bria' and (created_at<now()-interval '30 minutes' or exists(select 1 from video_erase_stages s where s.job_id=video_erase_jobs.id and s.state='dispatching' and s.admitted_at<now()-interval '2 minutes'))))
    order by id for update loop
    perform video_erase_finish(j.id,case when j.provider='bria' or j.provider_ref is null then 'uncertain' else 'failed' end,
      j.provider_ref,null,null,'Reflection processing expired. Your AI clip allowance was returned; no automatic retry was made.');
    update video_erase_stages set state='cancelled',cost_hold_released_at=coalesce(cost_hold_released_at,now()),updated_at=now() where job_id=j.id and state='pending';
  end loop;
end $function$
;
do $$begin if(select md5(prosrc)from pg_proc where oid='public.video_erase_admit_stage(uuid,uuid,uuid,text)'::regprocedure)not in('cd1b19d2b3015e1046f9e81ff0e8dc04','1a94f3f7f271770729cda7d807963212')then raise exception 'Review changed function video_erase_admit_stage(uuid,uuid,uuid,text)';end if;end$$;
CREATE OR REPLACE FUNCTION public.video_erase_admit_stage(p_org uuid, p_user uuid, p_job uuid, p_consent text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare j video_erase_jobs; s video_erase_stages; b video_erase_batches;
begin
  perform video_erase_authorize(p_org,p_user);
  perform pg_advisory_xact_lock(hashtextextended('org_month_spend:'||public.library_actor_billing_org(p_user,p_org)::text,42));
  perform 1 from orgs where id=public.library_actor_billing_org(p_user,p_org) for update;
  select * into j from video_erase_jobs where id=p_job and org_id=p_org and user_id=p_user for update;
  if not found or j.provider<>'bria' then raise exception 'RP404: Direct reflection job not found'; end if;
  if p_consent is distinct from j.provider_config->>'consent_version' then raise exception 'RP403: Direct Bria processing consent is required'; end if;
  select * into b from video_erase_batches where id=j.batch_id for update;
  perform video_erase_authorize(p_org,p_user,b.listing_id);
  if not public.studio_presenter_media_access(j.asset_id) then raise exception 'RP409: Presenter source approval is no longer available'; end if;
  select * into s from video_erase_stages where job_id=j.id and stage='erase' for update;
  if j.state in ('completed','failed','uncertain','cancelled') or b.state<>'open' or s.state<>'pending' then
    return jsonb_build_object('dispatch',false,'job',video_erase_job_json(j.id));
  end if;
  if j.created_at<now()-interval '30 minutes' then raise exception 'RP409: Reflection job expired'; end if;
  if not exists(select 1 from video_erase_stages where job_id=j.id and stage='mask' and state='completed' and provider_ref is not null and output_url is not null) then
    raise exception 'RP409: The mask must complete before erase admission';
  end if;
  update video_erase_stages set state='dispatching',admitted_at=now(),updated_at=now() where job_id=j.id and stage='erase';
  update video_erase_jobs set state='processing',updated_at=now() where id=j.id;
  return jsonb_build_object('dispatch',true,'job',video_erase_job_json(j.id));
end $function$
;
do $$begin if(select md5(prosrc)from pg_proc where oid='public.remove_org_member(uuid,uuid,uuid)'::regprocedure)not in('c47fa82a73573309b71f1ee617928ec7','3dd6d63d3fc2d14d7d0a596a9970cb35')then raise exception 'Review changed function remove_org_member(uuid,uuid,uuid)';end if;end$$;
CREATE OR REPLACE FUNCTION public.remove_org_member(p_org uuid, p_actor uuid, p_user uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_actor_role  text;
  v_target_role text;
begin
  if p_org is null or p_actor is null or p_user is null then
    raise exception 'RP400: workspace, caller and member are required';
  end if;
  if auth.uid() is not null and auth.uid() <> p_actor then
    raise exception 'RP403: the caller does not match the session';
  end if;
  if p_actor = p_user then
    raise exception 'RP400: you can''t remove yourself from your own team';
  end if;

  perform 1 from public.orgs where id = p_org and deleted_at is null for update;
  if not found then raise exception 'RP404: workspace not found'; end if;

  select role into v_actor_role from public.memberships
   where org_id = p_org and user_id = p_actor;
  if public.effective_plan_before_team(p_org)='team' and public.team_library_owner(p_org)is distinct from p_actor then
    raise exception 'RP403: Only the current Team owner can remove an agent';
  end if;
  if v_actor_role is null or v_actor_role not in ('owner', 'admin') then
    raise exception 'RP403: only the owner or an admin can change who is on the team';
  end if;

  select role into v_target_role from public.memberships
   where org_id = p_org and user_id = p_user for update;
  if v_target_role is null then
    raise exception 'RP404: that person isn''t on this team';
  end if;
  if v_target_role = 'owner' then
    raise exception 'RP403: the owner can''t be removed from their own team';
  end if;
  -- An admin may not remove another admin — only the owner may.
  if v_target_role = 'admin' and v_actor_role <> 'owner' then
    raise exception 'RP403: only the owner can remove an admin';
  end if;

  -- Transaction-local, read by the ledger trigger and cleared straight after so
  -- no later statement in the same transaction inherits an actor.
  perform set_config('rendprop.seat_actor', p_actor::text, true);
  delete from public.memberships where org_id = p_org and user_id = p_user;
  perform set_config('rendprop.seat_actor', '', true);

  -- Original content identities stay unchanged. The seat-removal trigger revokes
  -- delegated authority; exact listing ownership preserves the agent's library.
  return jsonb_build_object(
    'ok', true, 'org_id', p_org, 'user_id', p_user, 'role', v_target_role,
    'seats', jsonb_build_object(
      'used', public.org_seats_used(p_org),
      'allowed', public.org_seats_allowed(p_org)));
end;
$function$
;
do $$begin if(select md5(prosrc)from pg_proc where oid='public.video_erase_quote(uuid,uuid,uuid)'::regprocedure)not in('d6faf41647515dc24c6e7c3fc6727f5d','24eeb86b9e5fb792f8aaa351d3933ee9')then raise exception 'Review changed function video_erase_quote(uuid,uuid,uuid)';end if;end$$;
CREATE OR REPLACE FUNCTION public.video_erase_quote(p_org uuid, p_user uuid, p_listing uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare e plan_entitlements; used integer; spent numeric; billing uuid;
begin
  perform video_erase_authorize(p_org,p_user,p_listing);
  perform video_erase_expire(p_org);
  billing:=public.library_actor_billing_org(p_user,p_org);
  e:=org_entitlement(billing);
  select coalesce(count,0) into used from rate_limits where key='reelmo:'||billing
    and window_start>=now()-interval '30 days';
  spent:=org_month_spend_cents(billing);
  return jsonb_build_object('available',e.reels_per_month>coalesce(used,0) and spent<e.cogs_ceiling_cents,
    'remaining_clips',greatest(0,e.reels_per_month-coalesce(used,0)),
    'max_clip_seconds',4.8,'max_batch_cents',least(240,greatest(0,e.cogs_ceiling_cents-spent)),'unit_cost_cents',14,
    'remaining_cost_cents',greatest(0,e.cogs_ceiling_cents-spent));
end $function$
;

-- Authenticated legacy mutations are exact-listing capabilities, not broad
-- authority from the old physical Team container.
do $$begin if(select md5(prosrc)from pg_proc where oid='public.fail_render_job(uuid,text)'::regprocedure)not in('e492897a5b6dd721223fba5458273f60','3d3595cde70d6fd12a6825440ca260ed')then raise exception 'Review changed function fail_render_job(uuid,text)';end if;end$$;
CREATE OR REPLACE FUNCTION public.fail_render_job(p_job uuid, p_error text DEFAULT NULL::text)
 RETURNS render_jobs
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_job render_jobs;
  v_org uuid;
  v_role text;
begin
  select rj.* into v_job from render_jobs rj where rj.id = p_job;
  if not found then raise exception 'RP404: render job not found'; end if;

  select l.org_id into v_org from listings l where l.id = v_job.listing_id;
  if v_org is null then raise exception 'RP404: listing not found'; end if;

  perform 1 from public.orgs where id=public.library_billing_org(public.listing_owner_library(v_job.listing_id))for share;
  v_role := public.library_scope_role(auth.uid(),v_org,v_job.listing_id);
  if v_role is null then raise exception 'RP403: not a member of this workspace'; end if;
  if v_role not in ('owner','admin','agent') then
    raise exception 'RP403: your role does not permit updating renders';
  end if;

  select rj.* into v_job from render_jobs rj where rj.id=p_job for update;
  if not found then raise exception 'RP404: render job not found';end if;
  if v_job.status = 'failed' then return v_job; end if;
  if v_job.status = 'ready' or exists (select 1 from renders r where r.job_id = p_job) then
    raise exception 'RP409: this job already published a tour and cannot be marked failed';
  end if;

  update render_jobs
     set status = 'failed',
         finished_at = now(),
         error = coalesce(error, '{}'::jsonb)
                 || jsonb_build_object(
                      'message', left(coalesce(nullif(trim(p_error), ''), 'publish failed'), 500),
                      'at', now(),
                      'by', 'fail_render_job')
   where id = p_job
   returning * into v_job;
  return v_job;
end;
$function$
;
do $$begin if(select md5(prosrc)from pg_proc where oid='public.set_render_chapters(uuid,jsonb)'::regprocedure)not in('1b1eee14746b7c655fbe33f133d9a72f','49d181e7b47e23fec3e0e9ffaba7b02d')then raise exception 'Review changed function set_render_chapters(uuid,jsonb)';end if;end$$;
CREATE OR REPLACE FUNCTION public.set_render_chapters(p_render uuid, p_chapters jsonb)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_render renders;
  v_job render_jobs;
  v_org uuid;
  v_role text;
begin
  select r.* into v_render from renders r where r.id = p_render;
  if not found then raise exception 'RP404: render not found'; end if;
  select l.org_id into v_org from listings l where l.id = v_render.listing_id and l.deleted_at is null;
  if v_org is null then raise exception 'RP404: listing not found'; end if;

  perform 1 from public.orgs where id=public.library_billing_org(public.listing_owner_library(v_render.listing_id))for share;
  v_role := public.library_scope_role(auth.uid(),v_org,v_render.listing_id);
  if v_role is null then raise exception 'RP404: render not found'; end if;  -- don't reveal existence
  if v_role not in ('owner','admin','agent') then
    raise exception 'RP403: your role does not permit editing chapters';
  end if;

  select rj.* into v_job from render_jobs rj where rj.id = v_render.job_id;
  if not found or v_job.capture_asset_id is null then
    raise exception 'RP409: this render has no capture asset to attach chapters to';
  end if;

  return replace_asset_chapters(v_job.capture_asset_id, p_chapters);
end;
$function$
;
do $$begin if(select md5(prosrc)from pg_proc where oid='public.record_provenance(uuid,text,text,text,text,text,text,uuid,uuid,uuid)'::regprocedure)not in('891a7b8390b3c25967bd082059de9628','f835f7a4bb83e6322bdbc1002f6cb506')then raise exception 'Review changed function record_provenance(uuid,text,text,text,text,text,text,uuid,uuid,uuid)';end if;end$$;
CREATE OR REPLACE FUNCTION public.record_provenance(p_listing uuid, p_kind text, p_label text DEFAULT NULL::text, p_model_id text DEFAULT NULL::text, p_edit text DEFAULT NULL::text, p_style text DEFAULT NULL::text, p_prompt_summary text DEFAULT NULL::text, p_original_asset uuid DEFAULT NULL::uuid, p_altered_asset uuid DEFAULT NULL::uuid, p_render uuid DEFAULT NULL::uuid)
 RETURNS media_provenance
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_org uuid;
  v_role text;
  v_kind text := lower(trim(coalesce(p_kind, '')));
  v_label text := nullif(left(regexp_replace(coalesce(p_label, ''), '[\r\n\t]+', ' ', 'g'), 80), '');
  v_edit text := nullif(lower(left(trim(coalesce(p_edit, '')), 40)), '');
  v_style text := nullif(lower(left(trim(coalesce(p_style, '')), 40)), '');
  v_model text := nullif(left(trim(coalesce(p_model_id, '')), 120), '');
  v_summary text := nullif(left(regexp_replace(coalesce(p_prompt_summary, ''), '[\r\n\t]+', ' ', 'g'), 300), '');
  v_original text;
  v_altered text;
  v_render uuid := null;
  v_count integer;
  v_row media_provenance;
begin
  if v_kind not in ('photo_edit','virtual_stage','declutter','aerial','reel','other') then
    raise exception 'RP400: kind must be photo_edit, virtual_stage, declutter, aerial, reel, or other';
  end if;

  select l.org_id into v_org from listings l where l.id = p_listing and l.deleted_at is null;
  if v_org is null then raise exception 'RP404: listing not found'; end if;

  perform 1 from public.orgs where id=public.library_billing_org(public.listing_owner_library(p_listing))for share;
  v_role := public.library_scope_role(auth.uid(),v_org,p_listing);
  if v_role is null then raise exception 'RP403: not a member of this workspace'; end if;
  if v_role not in ('owner','admin','agent') then
    raise exception 'RP403: your role does not permit recording AI provenance';
  end if;

  -- Server-derived keys (see header). Either may be null at record time: the
  -- altered result is usually uploaded afterwards → set_provenance_media().
  v_original := provenance_asset_key(p_original_asset, p_listing);
  v_altered  := provenance_asset_key(p_altered_asset, p_listing);

  if p_render is not null then
    select r.id into v_render from renders r where r.id = p_render and r.listing_id = p_listing;
    if v_render is null then raise exception 'RP400: render_id does not belong to this listing'; end if;
  end if;

  -- A double-tapped edit must not print the same disclosure line twice on the
  -- public tour. An identical row recorded in the last minute is returned as-is.
  select mp.* into v_row from media_provenance mp
   where mp.listing_id = p_listing
     and mp.kind = v_kind
     and mp.created_at > now() - interval '60 seconds'
     and coalesce(mp.edit, '') = coalesce(v_edit, '')
     and coalesce(mp.label, '') = coalesce(v_label, '')
     and coalesce(mp.original_key, '') = coalesce(v_original, '')
   order by mp.created_at desc
   limit 1;
  if found then return v_row; end if;

  -- Bounded: a runaway client loop must not grow one listing's audit log
  -- without limit (the tour caps its disclosure list at 40 anyway).
  select count(*) into v_count from media_provenance mp where mp.listing_id = p_listing;
  if v_count >= 500 then
    raise exception 'RP429: this listing already has % provenance records — delete the listing or contact support', v_count;
  end if;

  insert into media_provenance (
    org_id, listing_id, render_id, kind, label, model_id, edit, style,
    prompt_summary, original_key, altered_key, disclosure)
  values (
    v_org, p_listing, v_render, v_kind, v_label, v_model, v_edit, v_style,
    v_summary, v_original, v_altered, provenance_disclosure(v_kind, v_edit))
  returning * into v_row;
  return v_row;
end;
$function$
;
do $$begin if(select md5(prosrc)from pg_proc where oid='public.set_provenance_media(uuid,uuid,uuid,text)'::regprocedure)not in('a4f295df0a8dd5d0760cf7761b34450d','03fac045fa0d408ac6390f70b8af023e')then raise exception 'Review changed function set_provenance_media(uuid,uuid,uuid,text)';end if;end$$;
CREATE OR REPLACE FUNCTION public.set_provenance_media(p_id uuid, p_original_asset uuid DEFAULT NULL::uuid, p_altered_asset uuid DEFAULT NULL::uuid, p_label text DEFAULT NULL::text)
 RETURNS media_provenance
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_row media_provenance;
  v_role text;
  v_label text := nullif(left(regexp_replace(coalesce(p_label, ''), '[\r\n\t]+', ' ', 'g'), 80), '');
begin
  select mp.* into v_row from media_provenance mp where mp.id = p_id;
  if not found then raise exception 'RP404: provenance record not found'; end if;

  perform 1 from public.orgs where id=public.library_billing_org(public.listing_owner_library(v_row.listing_id))for share;
  v_role := public.library_scope_role(auth.uid(),v_row.org_id,v_row.listing_id);
  if v_role is null then raise exception 'RP404: provenance record not found'; end if;  -- don't reveal existence
  if v_role not in ('owner','admin','agent') then
    raise exception 'RP403: your role does not permit editing AI provenance';
  end if;
  if v_row.listing_id is null then
    raise exception 'RP409: this provenance record has no listing to attach media to';
  end if;

  update media_provenance
     set original_key = coalesce(provenance_asset_key(p_original_asset, v_row.listing_id), original_key),
         altered_key  = coalesce(provenance_asset_key(p_altered_asset, v_row.listing_id), altered_key),
         label        = coalesce(v_label, label)
   where id = p_id
   returning * into v_row;
  if v_row.original_key is not null and not public.studio_presenter_key_access(v_row.listing_id,v_row.original_key) then v_row.original_key:=null; end if;
  if v_row.altered_key is not null and not public.studio_presenter_key_access(v_row.listing_id,v_row.altered_key) then v_row.altered_key:=null; end if;
  return v_row;
end;
$function$
;
commit;
