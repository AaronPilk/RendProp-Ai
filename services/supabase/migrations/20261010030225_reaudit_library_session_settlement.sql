-- Final re-audit: consistent private-library selection, first-seat lock order,
-- exact deleted-video settlement and session takeover fencing. No data backfill.
begin;

do $pin$declare h text;begin select md5(prosrc)into h from pg_catalog.pg_proc where oid='public.workspace_directory(uuid,uuid)'::regprocedure; if h not in('c42c5848c6486cfc4670cd63a5ac7301','746cc680332190d8338147f67308ce22')then raise exception 'Review changed function workspace_directory';end if;end$pin$;
CREATE OR REPLACE FUNCTION public.workspace_directory(p_user uuid, p_preferred_org uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
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
 -- A private Team seat never acquires the owner's library switcher. Legacy
 -- hints may be stale; an explicit unsupported preference must not fall back.
 if not switch and active is distinct from own then
  if p_preferred_org is not null then raise exception 'RP403: Only the Team owner can switch listing libraries';end if;
  active:=own;
 end if;
 return jsonb_build_object('actor_id',p_user,'own_org_id',own,'billing_org_id',coalesce(public.library_team_org(own),public.library_billing_org(own)),'can_switch_agent_libraries',switch,'active_org_id',active,'workspaces',rows);
end$function$;

revoke all on function public.workspace_directory(uuid,uuid)from public,anon,authenticated;
grant execute on function public.workspace_directory(uuid,uuid)to service_role,postgres;

do $pin$declare h text;begin select md5(prosrc)into h from pg_catalog.pg_proc where oid='public.select_workspace(uuid,uuid)'::regprocedure; if h not in('1e543f1af72bbe7e93a32c169e88930d','922f967fa624cc026dbe6f60ad922a0e')then raise exception 'Review changed function select_workspace';end if;end$pin$;
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
 perform 1 from public.orgs where id=public.library_team_org(p_org)and deleted_at is null for update;
 if exists(select 1 from public.deletion_requests where user_id=p_user and status in('pending','processing'))then raise exception 'RP409: This account is being deleted';end if;
 perform 1 from public.orgs where id=p_org and deleted_at is null for update;
 if not found then raise exception 'RP403: This listing library is unavailable';end if;
 perform public.workspace_directory(p_user,p_org);
 a:=public.library_access(p_user,p_org);
 insert into public.user_workspace_state(user_id,active_org_id)values(p_user,p_org)on conflict(user_id)do update set active_org_id=excluded.active_org_id,updated_at=now();
 return jsonb_build_object('ok',true,'actor_id',p_user,'org_id',p_org,'role',a->>'role','active_org_id',p_org,'org_name',(select name from public.orgs where id=p_org));
end$function$;

revoke all on function public.select_workspace(uuid,uuid)from public,anon,authenticated;
grant execute on function public.select_workspace(uuid,uuid)to service_role,postgres;

do $pin$declare h text;begin select md5(prosrc)into h from pg_catalog.pg_proc where oid='public.adopt_anonymous_org(uuid,uuid,uuid,uuid)'::regprocedure; if h not in('9448ef33e0572cf524f3a381c6a4130a','f386a4f2a7d578ceb1cbbdbee8a69349')then raise exception 'Review changed function adopt_anonymous_org';end if;end$pin$;
CREATE OR REPLACE FUNCTION public.adopt_anonymous_org(p_user uuid, p_anon_user uuid, p_anon_org uuid, p_operation uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_receipt jsonb; v_count integer; v_personal_card_disposition text;
begin
  if current_setting('role', true) is distinct from 'service_role' then
    raise insufficient_privilege using message = 'service role required';
  end if;
  if p_user is null or p_anon_user is null or p_anon_org is null or p_operation is null or p_user=p_anon_user then
    raise exception 'RP400: invalid handoff binding';
  end if;
  -- Receipt-only replays do not change workspace selection or lock Auth rows.
  v_receipt := public.adoption_receipt(p_user,p_anon_user,p_operation);
  if v_receipt is not null then
    if (v_receipt->>'org_id')::uuid <> p_anon_org then raise exception 'RP403: workspace binding does not match'; end if;
    return v_receipt;
  end if;
  -- Auth -> profile -> org; sorted within each class. Auth can promote an
  -- anonymous identity while Edge waits for SQL. Its live row, not the earlier
  -- GET/JWT snapshot, must still authorize the transfer. Auth-first also agrees
  -- with auth.users deletion cascading into profiles. No HTTP inside the lock.
  perform 1 from auth.users where id in(p_user,p_anon_user) order by id for update;
  perform 1 from public.profiles where id in (p_user,p_anon_user) order by id for update;
  v_receipt := public.adoption_receipt(p_user,p_anon_user,p_operation);
  if v_receipt is not null then
    if (v_receipt->>'org_id')::uuid <> p_anon_org then raise exception 'RP403: workspace binding does not match'; end if;
    return v_receipt;
  end if;
  select count(*) into v_count from public.profiles where id in (p_user,p_anon_user);
  if v_count <> 2 then raise exception 'RP401: session no longer exists'; end if;
  if (select is_anonymous from auth.users where id=p_anon_user) is distinct from true
     or (select is_anonymous from auth.users where id=p_user) is distinct from false then
    raise exception 'RP403: current source and destination identity types do not permit transfer';
  end if;
  if exists(select 1 from public.deletion_requests where user_id in (p_user,p_anon_user)
            and status in ('pending','processing')) then raise exception 'RP409: an account is being deleted'; end if;
  perform 1 from public.orgs where id=p_anon_org and deleted_at is null for update;
  if not found then raise exception 'RP404: that workspace no longer exists'; end if;
  -- Recheck the boundary inside the transaction, not only at Edge preflight.
  if (select count(*) from public.memberships where user_id=p_anon_user) <> 1
     or not exists(select 1 from public.memberships where user_id=p_anon_user and org_id=p_anon_org and role='owner')
     or exists(select 1 from public.memberships where org_id=p_anon_org and user_id<>p_anon_user) then
    raise exception 'RP409: original workspace ownership changed';
  end if;
  -- Both profiles are locked and the anonymous source was verified above.
  -- A prior explicit named-account choice always wins. Receipt replay returns
  -- before this write and never re-applies a preference.
  update public.profiles target set real_estate_role=source.real_estate_role
    from public.profiles source where target.id=p_user and source.id=p_anon_user
      and target.real_estate_role is null and source.real_estate_role is not null;
  -- Both profiles and Auth identities are already locked and verified.
  -- Receipt-only replay returns above, before any personal-card mutation.
  v_personal_card_disposition := case
    when (select public_card from public.profiles where id=p_user) is not null then 'destination_preserved'
    when (select public_card from public.profiles where id=p_anon_user) is not null then 'source_copied'
    else 'no_source_card' end;
  update public.profiles target set public_card=source.public_card
    from public.profiles source where target.id=p_user and source.id=p_anon_user
      and target.public_card is null and source.public_card is not null;
  update public.memberships set user_id=p_user where user_id=p_anon_user and org_id=p_anon_org;
  update public.listings set agent_id=p_user where org_id=p_anon_org and agent_id=p_anon_user;
  -- Adoption retains the transferred content, but never changes an already
  -- accepted private Team library or its billing parent. No content is moved.
  insert into public.user_workspace_state(user_id,active_org_id) values(p_user,
    coalesce((select b.private_org_id from public.team_private_libraries b
      join public.orgs o on o.id=b.private_org_id and o.deleted_at is null
      join public.memberships m on m.org_id=b.private_org_id and m.user_id=p_user and m.role='owner'
      where b.agent_user_id=p_user and b.revoked_at is null limit 1),p_anon_org))
    on conflict(user_id) do update set active_org_id=excluded.active_org_id, updated_at=now();
  v_receipt := jsonb_build_object('ok',true,'adopted',true,'operation_id',p_operation,
    'source_user_id',p_anon_user,'destination_user_id',p_user,'org_id',p_anon_org,
    'source_cleanup_pending',true,'personal_card_disposition',v_personal_card_disposition);
  insert into public.anonymous_adoption_receipts(operation_id,source_user_id,destination_user_id,org_id,receipt)
    values(p_operation,p_anon_user,p_user,p_anon_org,v_receipt);
  return v_receipt;
end;
$function$;

revoke all on function public.adopt_anonymous_org(uuid,uuid,uuid,uuid)from public,anon,authenticated;
grant execute on function public.adopt_anonymous_org(uuid,uuid,uuid,uuid)to service_role,postgres;

do $pin$declare h text;begin select md5(prosrc)into h from pg_catalog.pg_proc where oid='public.accept_org_invite(uuid,text)'::regprocedure; if h not in('6fcf6612285aa6bc4ddfcff4f2dbc0b4','09979c64b6c436674113a1de271dfe6a')then raise exception 'Review changed function accept_org_invite';end if;end$pin$;
CREATE OR REPLACE FUNCTION public.accept_org_invite(p_user uuid, p_token_hash text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare r jsonb;i public.org_invites;private_id uuid;was_accepted boolean;current_owner uuid;lock_users uuid[];prior_active uuid;begin
 select *into i from public.org_invites where token_hash=p_token_hash;
 was_accepted:=i.accepted_at is not null;
 if i.id is not null and(public.effective_plan_before_team(i.org_id)='team'or i.private_testing)then
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
end$function$;

revoke all on function public.accept_org_invite(uuid,text)from public,anon,authenticated;
grant execute on function public.accept_org_invite(uuid,text)to service_role,postgres;

do $pin$declare h text;begin select md5(prosrc)into h from pg_catalog.pg_proc where oid='public.cost_ledger_settle_serving_hold()'::regprocedure; if h not in('0da71ee6aab764a95529b191b24b19cd','b02d5dc9f5a6196e9c658ab236c90475')then raise exception 'Review changed function cost_ledger_settle_serving_hold';end if;end$pin$;
CREATE OR REPLACE FUNCTION public.cost_ledger_settle_serving_hold()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare holds uuid[];key text;v_stage text;
begin
 key:=nullif(new.meta->>'request_key','');v_stage:=nullif(new.meta->>'stage','');
 if key is null or v_stage is null or new.provider is null or new.model is null then return new;end if;
 if new.org_id is null then
  -- A deleted library can settle only its exact durable video reservation.
  -- Metadata alone cannot choose a parent, actor, predecessor or provider.
  if coalesce(new.meta->>'app_video_reservation_id','')!~'^[a-f0-9]{8}(-[a-f0-9]{4}){3}-[a-f0-9]{12}$'then return new;end if;
  select array_agg(x.id)into holds from(
   select r.id from public.app_video_cost_reservations v
   join public.serving_cost_reservations r on r.org_id=v.org_id and r.actor_id=v.actor_id
    and r.request_key=v.idempotency_key and r.stage=v.feature
    and r.provider=v.provider and r.model=v.model and r.billing_org_id=v.billing_org_id
   where v.id=(new.meta->>'app_video_reservation_id')::uuid
    and not exists(select 1 from public.orgs o where o.id=v.org_id)
    and new.idempotency_key='app-video:'||v.id::text and new.billing_org_id=v.billing_org_id
    and new.feature=v.feature and new.units=v.units
    and new.unit_cost_cents=v.unit_cost_cents and new.total_cents=v.total_cents
    and v.idempotency_key=key and v.feature=v_stage and v.provider=new.provider and v.model=new.model
    and(new.meta->>'actor_id'is null or new.meta->>'actor_id'=v.actor_id::text)
    and v.released_at is null and r.budget_source='ceiling'and r.state<>'rejected'
   for update of r)x;
  if cardinality(holds)=1 then
   update public.serving_cost_reservations set ledger_id=new.id where id=holds[1]and state='succeeded'and ledger_id is null;
  end if;
  return new;
 end if;
 -- Actor is not recorded on the receipt. If different actors reuse this
 -- identity, retain every liability rather than choosing one implicitly.
 select array_agg(m.id) into holds from(
  select r.id from public.serving_cost_reservations r
   where r.org_id=new.org_id and r.request_key=key and r.stage=v_stage
    and r.provider=new.provider and r.model=new.model and r.budget_source='ceiling'
    and r.state<>'rejected' for update
 )m;
 if cardinality(holds)=1 then
  update public.serving_cost_reservations set ledger_id=new.id
   where id=holds[1] and state='succeeded' and ledger_id is null;
 end if;
 return new;
end$function$;

revoke all on function public.cost_ledger_settle_serving_hold()from public,anon,authenticated;
grant execute on function public.cost_ledger_settle_serving_hold()to service_role,postgres;

do $pin$declare h text;begin select md5(prosrc)into h from pg_catalog.pg_proc where oid='public.notification_register_device_session(uuid,uuid,text,text,text,text,text)'::regprocedure; if h not in('83fd3964c315036acef2dfea06c633a0','496ab4845be208fa8e59ed40100d3d70')then raise exception 'Review changed function notification_register_device_session';end if;end$pin$;
CREATE OR REPLACE FUNCTION public.notification_register_device_session(p_user uuid, p_session uuid, p_token text, p_bundle_id text DEFAULT NULL::text, p_environment text DEFAULT NULL::text, p_locale text DEFAULT NULL::text, p_app_version text DEFAULT NULL::text)
 RETURNS notification_devices
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_token text:=lower(btrim(coalesce(p_token,'')));v_env text:=lower(btrim(coalesce(p_environment,'production')));digest text;v_row public.notification_devices;prior public.notification_devices;
begin
 if p_user is null or p_session is null then raise exception 'RP400: A device session is required';end if;
 if v_token=''or length(v_token)>400 or v_token!~'^[0-9a-fA-F]+$'then raise exception 'RP400: device_token must be a hexadecimal APNs token';end if;
 if v_env not in('sandbox','production')then raise exception 'RP400: environment must be sandbox or production';end if;
 digest:=pg_catalog.encode(pg_catalog.sha256(pg_catalog.convert_to(v_token,'UTF8')),'hex');
 perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('notification-device:'||digest,72453));
 perform 1 from public.profiles where id=p_user for key share;
 if not found then raise exception 'RP401: Sign in again';end if;
 if exists(select 1 from public.deletion_requests where user_id=p_user and status in('pending','processing'))then raise exception 'RP409: This account is being deleted';end if;
 if exists(select 1 from public.notification_device_session_tombstones t where t.user_id=p_user and t.session_id=p_session and t.token_sha256=digest and t.environment=v_env)
 then raise exception 'RP409: This device session has signed out';end if;
 -- A failed/expired outgoing DELETE must not allow its late session POST to
 -- reclaim a token after a verified newer account/session has taken it over.
 -- Do not lock a device row before its old profile: account deletion starts
 -- at profiles and may cascade this row. NOWAIT refuses a concurrent profile
 -- purge without introducing an inverse wait; retry sees the purged row gone.
 for prior in select *from public.notification_devices
  where lower(device_token)=v_token and registration_session_id is not null
   and(user_id is distinct from p_user or registration_session_id is distinct from p_session)
  order by user_id,id
 loop
  begin
   perform 1 from public.profiles where id=prior.user_id for key share nowait;
  exception when lock_not_available then raise exception 'RP409: Device ownership is changing; retry registration';end;
  if found then
   insert into public.notification_device_session_tombstones(user_id,session_id,token_sha256,environment)
   values(prior.user_id,prior.registration_session_id,digest,prior.environment)on conflict do nothing;
  end if;
 end loop;
 -- Retire pre-normalization spellings under the canonical token lock.
 -- A legitimate new registration rebinds that physical device, as before.
 delete from public.notification_devices where lower(device_token)=v_token and device_token<>v_token;
 v_row:=public.notification_register_device(p_user,v_token,p_bundle_id,v_env,p_locale,p_app_version);
 update public.notification_devices set registration_session_id=p_session where id=v_row.id returning *into v_row;
 return v_row;
end$function$;

revoke all on function public.notification_register_device_session(uuid,uuid,text,text,text,text,text)from public,anon,authenticated;
grant execute on function public.notification_register_device_session(uuid,uuid,text,text,text,text,text)to service_role,postgres;

commit;
