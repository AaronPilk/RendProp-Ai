-- A paid Team downgrade can leave more accepted people than its new seat
-- allowance. Keep every membership and saved private library, but project
-- current Team benefits to the owner and the earliest accepted seats only.
-- Pending invitations never displace an accepted member.
begin;

create or replace function public.team_seat_status(p_org uuid)
returns table(user_id uuid, seat_active boolean)
language sql stable security definer set search_path='' as $$
  with accepted as (
    select m.user_id,m.role,
      coalesce(
        (select i.accepted_at from public.team_private_libraries b
          join public.org_invites i on i.id=b.accepted_invite_id
          where b.team_org_id=p_org and b.agent_user_id=m.user_id
            and b.revoked_at is null and i.accepted_by=m.user_id
          limit 1),
        (select max(i.accepted_at) from public.org_invites i
          where i.org_id=p_org and i.accepted_by=m.user_id
            and i.accepted_at is not null),
        'infinity'::timestamptz) as accepted_at
      from public.memberships m where m.org_id=p_org
  ), ranked as (
    select a.user_id,
      row_number() over(order by a.accepted_at,a.user_id) as seat_rank
      from accepted a where a.role<>'owner'
  )
  select a.user_id,
    case when a.role='owner' then true
      else coalesce(r.seat_rank<=greatest(0,public.org_seats_allowed(p_org)-1),false)
    end as seat_active
    from accepted a left join ranked r on r.user_id=a.user_id;
$$;
revoke all on function public.team_seat_status(uuid) from public,anon,authenticated;
grant execute on function public.team_seat_status(uuid) to service_role,postgres;

create or replace function public.team_member_seat_active(p_actor uuid,p_org uuid)
returns boolean language sql stable security definer set search_path='' as $$
  select exists(select 1 from public.team_seat_status(p_org) s
    where s.user_id=p_actor and s.seat_active);
$$;
revoke all on function public.team_member_seat_active(uuid,uuid)
  from public,anon,authenticated;
grant execute on function public.team_member_seat_active(uuid,uuid)
  to service_role,postgres;

-- Structural binding validity still records who accepted a Team invitation.
-- Current funding and owner delegation are a separate, reversible projection;
-- accepted jobs retain their immutable billing-org receipt across a downgrade.
create or replace function public.library_billing_org(p_org uuid) returns uuid
language sql stable security definer set search_path='' as $$
 select coalesce((select b.team_org_id from public.team_private_libraries b where b.private_org_id=p_org
  and public.team_library_binding_valid(b.id)
  and public.team_member_seat_active(b.agent_user_id,b.team_org_id) limit 1),p_org);
$$;
create or replace function public.library_team_owner(p_org uuid) returns uuid
language sql stable security definer set search_path='' as $$
 select coalesce((select b.team_owner_user_id from public.team_private_libraries b where b.private_org_id=p_org
  and public.team_library_binding_valid(b.id)
  and public.team_member_seat_active(b.agent_user_id,b.team_org_id) limit 1),
 (select s.sponsor_owner_user_id from public.private_internal_testing_sponsorships s where s.private_org_id=p_org
  and public.private_team_content_binding_valid(s.id)
  and public.team_library_owner(s.sponsor_org_id)=s.sponsor_owner_user_id
  and s.revoked_at is null limit 1));
$$;
create or replace function public.library_team_org(p_org uuid) returns uuid
language sql stable security definer set search_path='' as $$
 select coalesce((select b.team_org_id from public.team_private_libraries b where b.private_org_id=p_org
  and public.team_library_binding_valid(b.id)
  and public.team_member_seat_active(b.agent_user_id,b.team_org_id) limit 1),
 (select s.sponsor_org_id from public.private_internal_testing_sponsorships s where s.private_org_id=p_org
  and public.private_team_content_binding_valid(s.id)and public.team_library_owner(s.sponsor_org_id)=s.sponsor_owner_user_id
  and s.revoked_at is null limit 1));
$$;

-- A paused member may still open Team status and see why their benefits
-- stopped; no Team content or manager mutation is exposed by this locator.
create or replace function public.paused_team_org(p_actor uuid) returns uuid
language sql stable security definer set search_path='' as $$
  select b.team_org_id from public.team_private_libraries b
    where b.agent_user_id=p_actor and b.revoked_at is null
      and public.team_library_binding_valid(b.id)
      and not public.team_member_seat_active(p_actor,b.team_org_id)
    limit 1;
$$;
revoke all on function public.paused_team_org(uuid) from public,anon,authenticated;
grant execute on function public.paused_team_org(uuid) to service_role,postgres;

commit;
