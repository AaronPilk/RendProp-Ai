-- Build 57: a Team owner's library switch must lock libraries in the same
-- order as account deletion. select_workspace locked the Team parent before
-- the selected private library; prepare_account_deletion locks a member's
-- orgs sorted by id after Auth and profile. When the agent's private library
-- id sorts before the Team id (half of all pairs) the owner's switch and the
-- agent's concurrent deletion preflight deadlocked (proved two-session in
-- tools/audit/run_build57_db_controls.py). No data backfill; no ACL change.
begin;

do $pin$declare h text;begin select md5(prosrc)into h from pg_catalog.pg_proc where oid='public.select_workspace(uuid,uuid)'::regprocedure; if h not in('922f967fa624cc026dbe6f60ad922a0e','ab14c1f6454c971bef4f62a1d98c995d')then raise exception 'Review changed function select_workspace';end if;end$pin$;
CREATE OR REPLACE FUNCTION public.select_workspace(p_user uuid, p_org uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare a jsonb;
begin
 if current_setting('role',true)<>'service_role'then raise insufficient_privilege using message='service role required';end if;
 perform 1 from public.profiles where id=p_user for update;
 -- Account deletion locks a member's orgs by id after its profile. Take the
 -- Team parent and the selected library in that same order so an owner's
 -- switch cannot deadlock an agent's concurrent deletion preflight.
 perform 1 from public.orgs where id in(p_org,public.library_team_org(p_org))and deleted_at is null order by id for update;
 if exists(select 1 from public.deletion_requests where user_id=p_user and status in('pending','processing'))then raise exception 'RP409: This account is being deleted';end if;
 if not exists(select 1 from public.orgs where id=p_org and deleted_at is null)then raise exception 'RP403: This listing library is unavailable';end if;
 perform public.workspace_directory(p_user,p_org);
 a:=public.library_access(p_user,p_org);
 insert into public.user_workspace_state(user_id,active_org_id)values(p_user,p_org)on conflict(user_id)do update set active_org_id=excluded.active_org_id,updated_at=now();
 return jsonb_build_object('ok',true,'actor_id',p_user,'org_id',p_org,'role',a->>'role','active_org_id',p_org,'org_name',(select name from public.orgs where id=p_org));
end$function$;

revoke all on function public.select_workspace(uuid,uuid)from public,anon,authenticated;
grant execute on function public.select_workspace(uuid,uuid)to service_role,postgres;

commit;
