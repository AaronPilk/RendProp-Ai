-- Serialize accepted-invite replay with the actor's current selection.
-- Preserve the prior workspace-existence guard; read its active value only
-- after the original Auth/profile locks. Unknown function bodies fail closed.
begin;
do $pin$declare h text;begin
 select md5(prosrc)into h from pg_catalog.pg_proc where oid='public.accept_org_invite(uuid,text)'::regprocedure;
 if h not in('20b63407d2740c1c0fa4cdf045905608','6fcf6612285aa6bc4ddfcff4f2dbc0b4')then raise exception 'Review changed function accept_org_invite';end if;
end$pin$;
CREATE OR REPLACE FUNCTION public.accept_org_invite(p_user uuid, p_token_hash text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare r jsonb;i public.org_invites;private_id uuid;was_accepted boolean;current_owner uuid;lock_users uuid[];prior_active uuid;begin
 select *into i from public.org_invites where token_hash=p_token_hash;
 was_accepted:=i.accepted_at is not null;
 if exists(select 1 from public.user_workspace_state where user_id=p_user)and(public.effective_plan_before_team(i.org_id)='team'or i.private_testing)then
  current_owner:=public.team_library_owner(i.org_id);
  lock_users:=array[p_user,i.invited_by,current_owner];
  -- Acquire every participant in deterministic Auth/profile order before the
  -- original accepted-seat org lock. Never weaken the binding FK or allow an
  -- invite to revive a participant whose deletion already won this race.
  perform 1 from auth.users where id=any(lock_users)order by id for key share;
  perform 1 from public.profiles where id=any(lock_users)order by id for update;
  if exists(select 1 from public.deletion_requests where user_id=any(lock_users)and status in('pending','processing'))then raise exception 'RP409: An account is being deleted';end if;
 end if;
 select active_org_id into prior_active from public.user_workspace_state where user_id=p_user;
 r:=public.accept_org_invite_before_team(p_user,p_token_hash);
 if coalesce((r->>'private_testing')::boolean,false)then return r;end if;
 select *into i from public.org_invites where token_hash=p_token_hash;
 if public.team_library_owner(i.org_id)is not null then
  private_id:=public.bind_team_private_library(i.invited_by,i.org_id,p_user,i.id);
  if not coalesce(was_accepted,false)then insert into public.user_workspace_state(user_id,active_org_id)values(p_user,private_id)on conflict(user_id)do update set active_org_id=excluded.active_org_id,updated_at=now();end if;
  if was_accepted and prior_active is not null and public.library_content_access(p_user,prior_active,false)then
   update public.user_workspace_state set active_org_id=prior_active,updated_at=now()where user_id=p_user;
  end if;
  return r||jsonb_build_object('org_id',private_id,'org_name',(select name from public.orgs where id=private_id),'private_org_id',private_id,'team_org_id',i.org_id,'role','owner','access_mode','own','private_team',true);
 end if;
 return r;
end$function$
;
commit;
