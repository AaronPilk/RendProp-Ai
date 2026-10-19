-- Preserve guest-adopted content and conservative financial liability.
-- All predecessor bodies are explicitly pinned; an unknown implementation
-- refuses application. The exact new bodies permit an unchanged replay.
begin;

create or replace function public.resolve_actor_owned_library(p_actor uuid,p_private_only boolean default false)returns uuid
language sql stable security definer set search_path='' as $resolve$
 select o.id from public.orgs o join public.memberships m on m.org_id=o.id and m.user_id=p_actor and m.role='owner'
 where o.deleted_at is null and(select count(*)from public.memberships x where x.org_id=o.id and x.role='owner')=1
 and(not p_private_only or((select count(*)from public.memberships x where x.org_id=o.id)=1
  and not exists(select 1 from public.private_internal_testing_sponsorships s where s.private_org_id=o.id and s.revoked_at is null)
  and not exists(select 1 from public.brokerage_contracts c where c.org_id=o.id and c.status='active')))
 order by exists(select 1 from public.user_workspace_state w where w.user_id=p_actor and w.active_org_id=o.id)desc,
  exists(select 1 from public.listings l where l.org_id=o.id and l.agent_id=p_actor)desc,o.created_at,o.id limit 1;
$resolve$;
revoke all on function public.resolve_actor_owned_library(uuid,boolean)from public,anon,authenticated;
grant execute on function public.resolve_actor_owned_library(uuid,boolean)to service_role,postgres;

do $pin$begin if(select md5(prosrc)from pg_proc where oid='public.agent_private_library(uuid)'::regprocedure)not in('ffee6ef5cac54ed62e15c627b196caec','0330b7136e128a92fa0d1754886f16d3')then raise exception 'Review changed function agent_private_library(uuid)';end if;end$pin$;
CREATE OR REPLACE FUNCTION public.agent_private_library(p_actor uuid)
 RETURNS uuid
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
 select coalesce((select b.private_org_id from public.team_private_libraries b where b.agent_user_id=p_actor
 and exists(select 1 from public.memberships m join public.orgs o on o.id=m.org_id and o.deleted_at is null where m.org_id=b.private_org_id and m.user_id=p_actor and m.role='owner')order by (b.revoked_at is null)desc,b.starts_at desc,b.id limit 1),
 (select s.private_org_id from public.private_internal_testing_sponsorships s where s.beneficiary_user_id=p_actor and s.revoked_at is null limit 1),
 public.resolve_actor_owned_library(p_actor,false));
$function$
;

do $pin$begin if(select md5(prosrc)from pg_proc where oid='public.bind_team_private_library(uuid,uuid,uuid,uuid)'::regprocedure)not in('c813d868039a596fc3cea1ddb117e60f','c1de651e1a23553174fecf928c8f3f56')then raise exception 'Review changed function bind_team_private_library';end if;end$pin$;
CREATE OR REPLACE FUNCTION public.bind_team_private_library(p_actor uuid, p_team uuid, p_agent uuid, p_invite uuid)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare private_id uuid;owner_id uuid;
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
 -- A retained, valid relationship wins a replay; otherwise prefer the
 -- actor's validated active private library, then existing owned content.
 select b.private_org_id into private_id from public.team_private_libraries b
 where b.agent_user_id=p_agent and b.team_org_id=p_team and b.revoked_at is null
 and exists(select 1 from public.orgs o join public.memberships m on m.org_id=o.id and m.user_id=p_agent and m.role='owner'
  where o.id=b.private_org_id and o.deleted_at is null and(select count(*)from public.memberships x where x.org_id=o.id)=1);
 private_id:=coalesce(private_id,public.resolve_actor_owned_library(p_agent,true));
 if private_id is null or private_id=p_team then raise exception 'RP409: A private listing library is required before joining this Team';end if;
 perform 1 from public.orgs where id=private_id for update;
 if not exists(select 1 from public.orgs o join public.memberships m on m.org_id=o.id and m.user_id=p_agent and m.role='owner'
  where o.id=private_id and o.deleted_at is null and(select count(*)from public.memberships x where x.org_id=o.id)=1)
  or exists(select 1 from public.private_internal_testing_sponsorships s where s.private_org_id=private_id and s.revoked_at is null)
  or exists(select 1 from public.brokerage_contracts c where c.org_id=private_id and c.status='active')
 then raise exception 'RP409: This private listing library is no longer available';end if;
 if exists(select 1 from public.team_private_libraries b where b.agent_user_id=p_agent and b.revoked_at is null and(b.team_org_id<>p_team or b.private_org_id<>private_id))then raise exception 'RP409: An existing Team seat must be removed first';end if;
 insert into public.team_private_libraries(team_org_id,team_owner_user_id,agent_user_id,private_org_id,accepted_invite_id)
 values(p_team,owner_id,p_agent,private_id,p_invite)on conflict(agent_user_id)where revoked_at is null do nothing;
 return private_id;
end$function$
;

do $pin$begin if(select md5(prosrc)from pg_proc where oid='public.create_org_invite(uuid,uuid,text,text,text)'::regprocedure)not in('db4429f87877313f1fabcee3228cd396','03fa6ccbe137f2262714e333d11b6ced')then raise exception 'Review changed function create_org_invite(uuid,uuid,text,text,text)';end if;end$pin$;
CREATE OR REPLACE FUNCTION public.create_org_invite(p_user uuid, p_org uuid, p_email text, p_role text, p_token_hash text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_role text;
  v_allowed integer;
  v_row public.org_invites%rowtype;
begin
  perform 1 from public.profiles where id = p_user for update;
  if not found then raise exception 'RP401: session no longer exists'; end if;
  if exists (select 1 from public.deletion_requests
             where user_id = p_user and status in ('processing','pending')) then
    raise exception 'RP409: this account is being deleted';
  end if;

  perform 1 from public.orgs where id = p_org and deleted_at is null for update;
  if not found then raise exception 'RP404: workspace not found'; end if;

  select role into v_role from public.memberships where org_id = p_org and user_id = p_user;
  if v_role is null or v_role not in ('owner','admin')
    or(public.effective_plan_before_team(p_org)='team'and public.team_library_owner(p_org)is distinct from p_user)
    or exists(select 1 from public.team_private_libraries b where b.private_org_id=p_org and b.revoked_at is null)
    or exists(select 1 from public.private_internal_testing_sponsorships s where s.private_org_id=p_org and s.revoked_at is null)then
    raise exception 'RP403: Only the current Team owner can invite agents';
  end if;
  if p_role is null or p_role not in ('admin', 'agent', 'marketing') then
    raise exception 'RP400: role must be admin, agent or marketing';
  end if;
  if p_token_hash is null or p_token_hash !~ '^[a-f0-9]{64}$' then
    raise exception 'RP400: invalid invite';
  end if;

  v_allowed := public.org_seats_allowed(p_org);
  if v_allowed is null or v_allowed < 1 then
    raise exception 'RP503: this plan is unavailable right now';
  end if;
  if public.org_seats_used(p_org) >= v_allowed then
    raise exception 'RP402: every seat on your plan is taken';
  end if;

  -- Retire invites that have already expired, so the one-live-invite-per-email
  -- index does not block re-inviting somebody whose code ran out. No live
  -- invite is touched.
  update public.org_invites set revoked_at = now()
    where org_id = p_org and accepted_at is null and revoked_at is null and expires_at <= now();

  insert into public.org_invites(org_id, email, role, token_hash, invited_by)
    values (p_org, nullif(lower(btrim(p_email)), ''), p_role, p_token_hash, p_user)
    returning * into v_row;

  return jsonb_build_object('id', v_row.id, 'email', v_row.email, 'role', v_row.role,
                            'created_at', v_row.created_at, 'expires_at', v_row.expires_at);
end;
$function$
;

do $pin$begin if(select md5(prosrc)from pg_proc where oid='public.create_org_invites_bulk(uuid,uuid,text[],text)'::regprocedure)not in('1cd5e859aa3b076ee6394fa506471c8e','cdff5a5a27d6064903c39daa24e008fc')then raise exception 'Review changed function create_org_invites_bulk(uuid,uuid,text[],text)';end if;end$pin$;
CREATE OR REPLACE FUNCTION public.create_org_invites_bulk(p_org uuid, p_actor uuid, p_emails text[], p_role text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  c_max_emails constant integer := 200;
  v_role       text;
  v_allowed    integer;
  v_used       integer;
  v_pending    integer;
  v_count      integer;
  v_issuable   integer := 0;
  v_issued     integer := 0;
  v_emails     text[]  := '{}';
  v_outcomes   text[]  := '{}';
  v_details    jsonb[] := '{}';
  v_seen       text[]  := '{}';
  v_results    jsonb   := '[]'::jsonb;
  v_email      text;
  v_code       text;
  v_row        public.org_invites%rowtype;
  v_member     uuid;
  v_invite     uuid;
  i            integer;
begin
  if p_org is null or p_actor is null then
    raise exception 'RP400: workspace and caller are required';
  end if;
  -- Belt and braces: this function is granted to service_role only and the edge
  -- resolves p_actor from the verified JWT, but if it is ever handed to
  -- `authenticated` a caller must not be able to act as somebody else. Under
  -- the service role auth.uid() is null and this is a no-op.
  if auth.uid() is not null and auth.uid() <> p_actor then
    raise exception 'RP403: the caller does not match the session';
  end if;
  if p_emails is null or cardinality(p_emails) = 0 then
    raise exception 'RP400: send at least one email address';
  end if;
  v_count := cardinality(p_emails);
  if v_count > c_max_emails then
    raise exception 'RP400: at most % addresses in one bulk invite', c_max_emails;
  end if;
  if p_role is null or p_role not in ('admin', 'agent', 'marketing') then
    raise exception 'RP400: role must be admin, agent or marketing';
  end if;

  -- The same two preconditions create_org_invite() takes, in the same order.
  perform 1 from public.profiles where id = p_actor for update;
  if not found then raise exception 'RP401: session no longer exists'; end if;
  if exists (select 1 from public.deletion_requests
             where user_id = p_actor and status in ('processing', 'pending')) then
    raise exception 'RP409: this account is being deleted';
  end if;

  -- THE lock — the same org row every seat mutation takes before it reads any
  -- count (0033). It is what makes "every invite or none" true against two
  -- managers pasting overlapping lists at the same moment.
  perform 1 from public.orgs where id = p_org and deleted_at is null for update;
  if not found then raise exception 'RP404: workspace not found'; end if;

  select role into v_role from public.memberships
   where org_id = p_org and user_id = p_actor;
  if v_role is null or v_role not in ('owner','admin')
    or(public.effective_plan_before_team(p_org)='team'and public.team_library_owner(p_org)is distinct from p_actor)
    or exists(select 1 from public.team_private_libraries b where b.private_org_id=p_org and b.revoked_at is null)
    or exists(select 1 from public.private_internal_testing_sponsorships s where s.private_org_id=p_org and s.revoked_at is null)then
    raise exception 'RP403: Only the current Team owner can invite agents';
  end if;

  -- Retire already-expired invites first, exactly as create_org_invite() does:
  -- org_seats_used() already ignores them, but the one-live-invite-per-e-mail
  -- index (0032) does not, and it would block re-inviting somebody whose code
  -- ran out. No live invite is touched.
  update public.org_invites set revoked_at = now()
   where org_id = p_org and accepted_at is null and revoked_at is null
     and expires_at <= now();

  -- PASS 1 — classify every address before issuing anything, because the seat
  -- test needs to know how many will actually be issued.
  for i in 1 .. v_count loop
    v_email := nullif(lower(btrim(coalesce(p_emails[i], ''))), '');
    v_emails[i] := coalesce(v_email, btrim(coalesce(p_emails[i], '')));
    v_details[i] := '{}'::jsonb;

    if v_email is null or length(v_email) > 254
       or v_email !~ '^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]{2,}$' then
      v_outcomes[i] := 'invalid';
      v_details[i]  := jsonb_build_object('reason', 'not an email address');
    elsif v_email = any (v_seen) then
      v_outcomes[i] := 'already_invited';
      v_details[i]  := jsonb_build_object('reason', 'listed more than once in this request');
    else
      v_seen := v_seen || v_email;
      v_member := null;
      select m.user_id into v_member
        from public.memberships m
        join public.profiles p on p.id = m.user_id
       where m.org_id = p_org and lower(p.email) = v_email
       limit 1;
      if v_member is not null then
        v_outcomes[i] := 'already_a_member';
        v_details[i]  := jsonb_build_object('user_id', v_member);
      else
        v_invite := null;
        select i2.id into v_invite from public.org_invites i2
         where i2.org_id = p_org and lower(i2.email) = v_email
           and i2.accepted_at is null and i2.revoked_at is null
           and i2.expires_at > now()
         limit 1;
        if v_invite is not null then
          v_outcomes[i] := 'already_invited';
          v_details[i]  := jsonb_build_object('invite_id', v_invite);
        else
          v_outcomes[i] := 'issue';
          v_issuable := v_issuable + 1;
        end if;
      end if;
    end if;
  end loop;

  v_allowed := public.org_seats_allowed(p_org);
  if v_allowed is null or v_allowed < 1 then
    raise exception 'RP503: this plan is unavailable right now';
  end if;
  v_used := public.org_seats_used(p_org);
  -- A list of people who are ALL already on the team needs no seats and must
  -- not be refused just because the org is already full.
  if v_issuable > 0 and v_used + v_issuable > v_allowed then
    raise exception
      'RP402: % of these need a seat and only % of your % are free — nobody was invited',
      v_issuable, greatest(v_allowed - v_used, 0), v_allowed;
  end if;

  -- PASS 2 — issue. Any failure here (including the astronomically unlikely
  -- token_hash collision) aborts the transaction, which is the contract.
  for i in 1 .. v_count loop
    if v_outcomes[i] = 'issue' then
      v_code := public.mint_org_invite_code();
      insert into public.org_invites (org_id, email, role, token_hash, invited_by)
        values (p_org, v_emails[i], p_role,
                encode(sha256(convert_to(replace(v_code, '-', ''), 'UTF8')), 'hex'),
                p_actor)
        returning * into v_row;
      v_outcomes[i] := 'issued';
      v_issued := v_issued + 1;
      -- The plaintext code leaves the database HERE and nowhere else, ever.
      v_details[i] := jsonb_build_object(
        'id', v_row.id, 'code', v_code,
        'created_at', v_row.created_at, 'expires_at', v_row.expires_at);
    end if;
  end loop;

  for i in 1 .. v_count loop
    v_results := v_results || jsonb_build_array(
      jsonb_build_object('email', v_emails[i], 'outcome', v_outcomes[i]) || v_details[i]);
  end loop;

  select count(*) into v_pending from public.org_invites i3
   where i3.org_id = p_org and i3.accepted_at is null and i3.revoked_at is null
     and i3.expires_at > now();

  return jsonb_build_object(
    'ok', true,
    'org_id', p_org,
    'role', p_role,
    'requested', v_count,
    'issued', v_issued,
    'results', v_results,
    'seats', jsonb_build_object(
      'used', public.org_seats_used(p_org),
      'allowed', v_allowed,
      'pending', v_pending));
end;
$function$
;

do $pin$begin if(select md5(prosrc)from pg_proc where oid='public.serving_photo_partition_guard()'::regprocedure)not in('8326b1d495a42766f0a47af94dff5cc8','747daf1c2a182ab57fc8fef0cae44424')then raise exception 'Review changed function serving_photo_partition_guard()';end if;end$pin$;
CREATE OR REPLACE FUNCTION public.serving_photo_partition_guard()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare p public.serving_photo_partitions;a public.serving_photo_admissions;task text;spent numeric;
begin
 if new.sponsored_unlimited then return new;end if;
 -- Ceiling holds have no funded photo partition. Taking a child lock here
 -- would invert the parent-budget/child-operation lock order for no purpose.
 if new.funding_id is null then return new;end if;
 perform pg_advisory_xact_lock(hashtextextended('serving:'||new.org_id,72452));
 if exists(select 1 from public.serving_photo_partitions package join public.serving_funding f on f.id=package.funding_id
  where package.org_id=new.org_id and package.starts_at<=now()and package.ends_at>now()and f.revoked_at is null)
  and(select count(*)from public.serving_funding where org_id=new.org_id and revoked_at is null and starts_at<=now()and ends_at>now())<>1
 then raise exception 'RP409: The configured package funding interval is ambiguous';end if;
 if exists(select 1 from public.serving_photo_partitions where funding_id=new.funding_id and starts_at<=now()and ends_at>now())
  and(select count(*)from public.serving_funding_slices where funding_id=new.funding_id and starts_at<=now()and ends_at>now())<>1
 then raise exception 'RP409: The configured package service slice is ambiguous';end if;
 select * into p from public.serving_photo_partitions where funding_id=new.funding_id and slice_index=new.slice_index;
 if not found then return new;end if;
 if new.org_id<>p.org_id or p.starts_at>now()or p.ends_at<=now()then raise exception 'RP403: The package belongs to another or expired funding interval';end if;
 if new.stage~'^photo\.(twilight|sky|lawn|declutter|stage|custom):[01]$'then
  task:=split_part(new.stage,':',1);
  if new.tariff_version<>p.tariff_version
   or(right(new.stage,2)=':0'and(new.provider<>'gemini'or new.model<>'gemini-3.1-flash-image'or new.hold_cents<>31.1296))
   or(right(new.stage,2)=':1'and(new.provider<>'fal'or new.model not in('flux-pro/kontext','fal-ai/flux-pro/kontext')or new.hold_cents<>4))
  then raise exception 'RP403: This photo attempt does not match the immutable bounded tariff';end if;
  select * into a from public.serving_photo_admissions where funding_id=p.funding_id and slice_index=p.slice_index and actor_id=new.actor_id and request_key=new.request_key;
  if right(new.stage,2)=':0'then
   if a.funding_id is not null then raise exception 'RP409: This photo admission is already retained';end if;
   if(select count(*)from public.serving_photo_admissions where funding_id=p.funding_id and slice_index=p.slice_index)>=p.photo_cap
   then raise exception 'RP402: The included photo admissions are exhausted';end if;
   insert into public.serving_photo_admissions(funding_id,slice_index,org_id,actor_id,request_key,task,input_sha256)
   values(p.funding_id,p.slice_index,p.org_id,new.actor_id,new.request_key,task,new.input_sha256);
  elsif a.funding_id is null or a.task<>task or a.input_sha256<>new.input_sha256 then
   raise exception 'RP409: A fallback requires its exact retained primary photo admission';
  end if;
  -- Cash is reserved for every included two-attempt operation even when a
  -- proven predispatch rejection releases the provider's particular hold.
  return new;
 end if;
 if new.stage~'^photo\.'and new.stage not in('photo.suggest','photo.improve_prompt')then
  raise exception 'RP403: This photo stage is outside the bounded package';end if;
 select coalesce(sum(hold_cents),0)into spent from public.serving_cost_reservations
  where funding_id=p.funding_id and slice_index=p.slice_index and state<>'rejected'
   and stage!~'^photo\.(twilight|sky|lawn|declutter|stage|custom):[01]$';
 if spent+new.hold_cents>p.other_ai_cents then raise exception 'RP402: The separate helper and other AI wallet is exhausted';end if;
 return new;
end$function$
;

do $pin$begin if(select md5(prosrc)from pg_proc where oid='public.accept_org_invite(uuid,text)'::regprocedure)not in('a9275ad39080118f8bd530c3bc090e5f','20b63407d2740c1c0fa4cdf045905608')then raise exception 'Review changed function accept_org_invite';end if;end$pin$;
CREATE OR REPLACE FUNCTION public.accept_org_invite(p_user uuid, p_token_hash text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare r jsonb;i public.org_invites;private_id uuid;was_accepted boolean;current_owner uuid;lock_users uuid[];prior_active uuid;begin
 select *into i from public.org_invites where token_hash=p_token_hash;
 was_accepted:=i.accepted_at is not null;
 select active_org_id into prior_active from public.user_workspace_state where user_id=p_user;
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
  if was_accepted and prior_active is not null and public.library_content_access(p_user,prior_active,false)then
   update public.user_workspace_state set active_org_id=prior_active,updated_at=now()where user_id=p_user;
  end if;
  return r||jsonb_build_object('org_id',private_id,'org_name',(select name from public.orgs where id=private_id),'private_org_id',private_id,'team_org_id',i.org_id,'role','owner','access_mode','own','private_team',true);
 end if;
 return r;
end$function$
;

do $pin$begin if(select md5(prosrc)from pg_proc where oid='public.prepare_account_deletion(uuid,text,text)'::regprocedure)not in('3c5d9df842732f8ee1f0d92cd588906b','40bcc50faa163a664b1f0e6efcc42ef8')then raise exception 'Review changed function prepare_account_deletion(uuid,text,text)';end if;end$pin$;
CREATE OR REPLACE FUNCTION public.prepare_account_deletion(p_user uuid, p_upload_bucket text, p_render_bucket text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  all_orgs uuid[]; solo uuid[]; shared uuid[]; listing_ids uuid[]; asset_ids uuid[]; job_ids uuid[]; render_ids uuid[];
  org uuid; heir uuid; request_id uuid; old_request uuid; payload jsonb; scope jsonb; email_value text; apple_token text;
  object_targets jsonb; spatial_ids uuid[]:='{}'; spatial_keys jsonb:='[]'; provider_targets jsonb:='[]';
  multipart_targets jsonb:='[]'; unresolved_targets jsonb:='[]'; storage_after timestamptz;
begin
  if current_setting('role',true) is distinct from 'service_role' then raise insufficient_privilege using message='service role required'; end if;
  if p_user is null or coalesce(length(p_upload_bucket),0) not between 3 and 63
     or coalesce(length(p_render_bucket),0) not between 3 and 63 or p_upload_bucket=p_render_bucket then
    raise exception 'RP400: invalid deletion binding';
  end if;
  -- Same mutation order as0038: Auth -> profiles -> sorted orgs. Reading
  -- memberships BEFORE these locks recreates the destructive adoption race.
  perform 1 from auth.users where id=p_user for update;
  if not found then raise exception 'RP401: account no longer exists'; end if;
  perform 1 from public.profiles where id=p_user for update;
  perform public.account_deletion_integrity_preflight(p_user);
  select id into old_request from public.deletion_requests
    where user_id=p_user and snapshot_version=2 and status in('pending','processing') and not manual_review_required
    order by requested_at limit 1;
  if old_request is not null then return public.claim_account_deletion(old_request); end if;
  select coalesce(array_agg(org_id order by org_id),'{}'::uuid[]) into all_orgs from public.memberships where user_id=p_user;
  perform 1 from public.orgs where id=any(all_orgs) order by id for update;
  -- The lock also serializes team joins. Recheck membership rather than
  -- trusting a list read before waiting for somebody else's org transaction.
  if exists(select 1 from unnest(all_orgs) x where not exists(select 1 from public.memberships where org_id=x and user_id=p_user)) then
    raise exception 'RP409: workspace ownership changed; retry deletion';
  end if;
  perform public.account_deletion_integrity_preflight(p_user);
  select coalesce(array_agg(o),'{}'::uuid[]) into solo from unnest(all_orgs) o
    where (select count(*) from public.memberships where org_id=o)=1;
  select coalesce(array_agg(o),'{}'::uuid[]) into shared from unnest(all_orgs) o where not(o=any(solo));
  -- FOR UPDATE prevents new FK children while their keys are inventoried. The
  -- upload and worker transactions also start at listing before asset/job.
  perform 1 from public.listings where org_id=any(all_orgs) order by id for update;
  select coalesce(array_agg(id),'{}'::uuid[]) into listing_ids from public.listings where org_id=any(solo);
  if cardinality(listing_ids)>10000 then raise exception 'RP413: account requires assisted deletion'; end if;
  perform 1 from public.capture_assets where listing_id=any(listing_ids) order by id for update;
  perform 1 from public.photos where listing_id=any(listing_ids) order by id for update;
  perform 1 from public.render_jobs where listing_id=any(listing_ids) order by id for update;
  perform 1 from public.renders where listing_id=any(listing_ids) order by id for update;
  select coalesce(array_agg(id),'{}'::uuid[]) into asset_ids from public.capture_assets where listing_id=any(listing_ids);
  select coalesce(array_agg(id),'{}'::uuid[]) into job_ids from public.render_jobs where listing_id=any(listing_ids);
  select coalesce(array_agg(id),'{}'::uuid[]) into render_ids from public.renders where listing_id=any(listing_ids);
  -- 0039 precedes 0040 in a fresh install. No spatial schema means no spatial
  -- data can exist; a partially installed schema is NOT an empty inventory.
  if to_regclass('public.spatial_jobs') is not null then
    if to_regclass('public.spatial_inputs') is null or to_regclass('public.spatial_attempt_history') is null then
      raise exception 'RP503: spatial cleanup schema is incomplete; nothing was deleted';
    end if;
    perform 1 from public.spatial_jobs where org_id=any(solo) order by id for update;
    select coalesce(array_agg(id),'{}'::uuid[]) into spatial_ids from public.spatial_jobs where org_id=any(solo);
    if exists(select 1 from public.spatial_jobs where id=any(spatial_ids) and not(listing_id=any(listing_ids))) then
      raise exception 'RP409: orphaned spatial ownership requires assisted deletion; nothing was deleted';
    end if;
    perform 1 from public.spatial_inputs where job_id=any(spatial_ids) order by job_id,relative_path for update;
    perform 1 from public.spatial_attempt_history where job_id=any(spatial_ids) order by job_id,attempt_key for update;
    if exists(select 1 from public.spatial_attempt_history h join public.spatial_jobs j on j.id=h.job_id
      where j.id=any(spatial_ids) and (jsonb_typeof(h.snapshot) is distinct from 'object' or
        h.snapshot->>'id' is distinct from j.id::text or h.snapshot->>'org_id' is distinct from j.org_id::text or
        h.snapshot->>'listing_id' is distinct from j.listing_id::text or
        (h.snapshot->>'started_at' is not null and h.snapshot->>'lease_token' is null))) then
      raise exception 'RP409: invalid spatial attempt history; nothing was deleted';
    end if;
    with attempts as (
      select j.id,j.org_id,j.listing_id,to_jsonb(j) snapshot from public.spatial_jobs j where j.id=any(spatial_ids)
      union all select j.id,j.org_id,j.listing_id,h.snapshot from public.spatial_attempt_history h
        join public.spatial_jobs j on j.id=h.job_id where j.id=any(spatial_ids)
    ) select coalesce(jsonb_agg(jsonb_build_object('bucket',p_upload_bucket,'key',snapshot->>'output_key',
        'valid',snapshot->>'id'=id::text and snapshot->>'org_id'=org_id::text and
          snapshot->>'listing_id'=listing_id::text and snapshot->>'artifact_revision' ~
          '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' and
          snapshot->>'output_key'='spatial/'||org_id||'/'||listing_id||'/'||id||'/'||
            (snapshot->>'artifact_revision')||'/model.sog')),'[]'::jsonb)
      into spatial_keys from attempts where snapshot->>'output_key' is not null;
    with attempts as (
      select j.id,to_jsonb(j) snapshot from public.spatial_jobs j where j.id=any(spatial_ids)
      union all select h.job_id,h.snapshot from public.spatial_attempt_history h where h.job_id=any(spatial_ids)
    ) select coalesce(jsonb_agg(distinct jsonb_build_object('job_id',id,'lease_token',snapshot->>'lease_token')),'[]'),
        max((snapshot->>'deadline_at')::timestamptz)+interval '15 minutes'
      into provider_targets,storage_after from attempts where snapshot->>'lease_token' is not null;
    -- Inputs are validated server bindings, not a caller-selected list of URLs.
    select spatial_keys||coalesce(jsonb_agg(jsonb_build_object('bucket',p_upload_bucket,'key',i.storage_key,
      'valid',starts_with(i.storage_key,'uploads/'||j.org_id||'/'||j.listing_id||'/')
        and length(i.storage_key)<=4096 and i.storage_key !~ '(^|/)[.]{1,2}(/|$)')),'[]')
      into spatial_keys from public.spatial_inputs i join public.spatial_jobs j on j.id=i.job_id where j.id=any(spatial_ids);
  end if;
  -- Journaled operations outlive their asset rows. Preserve every destination
  -- and multipart identity before removing that journal; a previously claimed
  -- write may settle AFTER this transaction. Re-delete only after its window.
  perform 1 from public.upload_reservations where org_id=any(solo) order by asset_id for update;
  if exists(select 1 from public.upload_reservations r where r.org_id=any(solo) and not(r.listing_id=any(listing_ids)) and
    not exists(select 1 from public.org_brand_assets b where b.id=r.asset_id and b.org_id=r.org_id and b.actor_id=r.actor_id
      and r.listing_id=r.org_id and r.spec->>'role'='business_logo' and r.spec->>'sha256'=b.sha256)) then
    raise exception 'RP409: orphaned upload ownership requires assisted deletion; nothing was deleted';
  end if;
  perform 1 from public.upload_operations where asset_id in(select asset_id from public.upload_reservations where org_id=any(solo))
    order by id for update;
  if exists(select 1 from public.capture_assets where listing_id=any(listing_ids) and
    (bucket not in('uploads','renders') or not starts_with(storage_key,bucket||'/'))) or
    exists(select 1 from public.upload_operations o join public.upload_reservations r using(asset_id) where r.org_id=any(solo) and
      not(starts_with(o.object_key,o.bucket||'/') or starts_with(o.object_key,'_staging/'||o.bucket||'/'))) then
    raise exception 'RP409: storage bucket binding is invalid; nothing was deleted';
  end if;
  select greatest(storage_after,max(coalesce(o.write_deadline,o.expires_at))+interval '1 hour')
    into storage_after from public.upload_operations o join public.upload_reservations r using(asset_id) where r.org_id=any(solo);
  if exists(select 1 from public.capture_assets where listing_id=any(listing_ids) and transport_version=1) then
    storage_after:=greatest(storage_after,clock_timestamp()+interval '75 minutes');
  end if;
  with sessions as (
    select a.bucket,a.storage_key key,a.upload_id from public.capture_assets a where listing_id=any(listing_ids) and upload_id is not null
    union select o.bucket,o.object_key,o.upload_id from public.upload_operations o join public.upload_reservations r using(asset_id)
      where r.org_id=any(solo) and o.upload_id is not null
  ) select coalesce(jsonb_agg(jsonb_build_object('bucket',case bucket when 'uploads' then p_upload_bucket else p_render_bucket end,
    'key',key,'upload_id',upload_id)),'[]') into multipart_targets from sessions;
  select coalesce(jsonb_agg(jsonb_build_object('operation_id',o.id,'bucket',
    case o.bucket when 'uploads' then p_upload_bucket else p_render_bucket end,'key',o.object_key)),'[]')
    into unresolved_targets from public.upload_operations o join public.upload_reservations r using(asset_id)
    where r.org_id=any(solo) and o.kind='init' and o.upload_id is null and o.state in('dispatching','uncertain');
  if cardinality(asset_ids)+cardinality(job_ids)+cardinality(render_ids)>50000 then raise exception 'RP413: account requires assisted deletion'; end if;
  select email into email_value from auth.users where id=p_user;
  select apple_refresh_token into apple_token from public.profiles where id=p_user;
  -- A row's membership is not proof that an arbitrary string in a writable
  -- photo field is its object. Only canonical keys under THAT listing may
  -- authorize deletion; unknown legacy formats require assisted reconciliation
  -- before any destruction. Original enhanced stills live in renders, too.
  with keys as (
    select listing_id,storage_key key from public.capture_assets where listing_id=any(listing_ids)
    union select listing_id,original_key from public.photos where listing_id=any(listing_ids)
    union select listing_id,enhanced_key from public.photos where listing_id=any(listing_ids)
    union select listing_id,video_key from public.renders where listing_id=any(listing_ids)
    union select listing_id,poster_key from public.renders where listing_id=any(listing_ids)
    union select listing_id,hero_key from public.renders where listing_id=any(listing_ids)
    union select id,main_photo_key from public.listings where id=any(listing_ids)
    union select r.listing_id,o.object_key from public.upload_operations o join public.upload_reservations r using(asset_id) where r.org_id=any(solo)
    union select listing_id,'_staging/'||regexp_replace(storage_key,'-complete-[0-9a-f-]{36}([.][a-zA-Z0-9]+)$','\1')
      from public.capture_assets where listing_id=any(listing_ids) and transport_version=1 and parts_total is null
  ) select coalesce(jsonb_agg(jsonb_build_object('bucket',case when key like 'uploads/%' or key like '_staging/uploads/%' then p_upload_bucket else p_render_bucket end,
    'key',key,'valid',length(key) between 1 and 4096 and key !~ '(^|/)[.]{1,2}(/|$)' and
      (starts_with(key,'uploads/'||l.org_id||'/'||l.id||'/') or
       starts_with(key,'renders/'||l.org_id||'/'||l.id||'/') or starts_with(key,'renders/'||l.id||'/') or
       starts_with(key,'_staging/uploads/'||l.org_id||'/'||l.id||'/') or starts_with(key,'_staging/renders/'||l.org_id||'/'||l.id||'/') or exists(select 1 from public.private_ai_outputs own where own.org_id=l.org_id and own.listing_id=l.id and own.bucket='renders'and own.storage_key=key)))), '[]'::jsonb)
    into object_targets from keys join public.listings l on l.id=keys.listing_id where key is not null;
  -- Org logo destinations are private service-journaled identities, never
  -- inferred from a user-editable brand URL. Preserve retired/orphan attempts too.
  if exists(select 1 from public.org_brand_assets b where b.org_id=any(solo) and not exists(
    select 1 from public.upload_reservations r join public.upload_operations op on op.asset_id=r.asset_id
    where r.asset_id=b.id and r.org_id=b.org_id and r.actor_id=b.actor_id and r.listing_id=b.org_id
      and r.spec->>'role'='business_logo' and r.spec->>'sha256'=b.sha256 and op.kind='single' and op.bucket='renders' and op.object_key=b.object_key)) then
    raise exception 'RP409: logo ownership requires assisted deletion; nothing was deleted';
  end if;
  select object_targets||coalesce(jsonb_agg(jsonb_build_object('bucket',p_render_bucket,'key',b.object_key,'valid',
    b.object_key='renders/'||b.org_id||'/brand/'||b.id||case when b.content_type='image/png' then '.png' else '.jpg' end)), '[]')
    into object_targets from public.org_brand_assets b where b.org_id=any(solo);
  object_targets:=object_targets||spatial_keys||public.studio_voice_deletion_targets(solo,p_upload_bucket);
  object_targets:=object_targets||public.studio_project_deletion_targets(p_user,solo,p_upload_bucket);
  select greatest(storage_after,max(write_deadline)+interval '1 hour') into storage_after from public.studio_project_media where actor_id=p_user or org_id=any(solo);
  select greatest(storage_after,max(write_deadline)+interval '1 hour') into storage_after
    from public.voice_storage_reservations where org_id=any(solo);
  object_targets:=object_targets||public.account_private_output_targets(solo,p_upload_bucket,p_render_bucket);
  object_targets:=object_targets||public.account_deletion_reflection_targets(solo,p_render_bucket);
  select greatest(storage_after,clock_timestamp()+interval '1 hour',max(output_write_deadline)+interval '1 hour')into storage_after from public.studio_presenter_jobs where org_id=any(solo);
  select greatest(storage_after,max(not_before)+interval '1 hour')into storage_after from public.privacy_cleanup_jobs where org_id=any(solo)and state in('pending','processing');
  if exists(select 1 from jsonb_array_elements(object_targets) t where t->>'valid' is distinct from 'true') then
    raise exception 'RP409: unverified media ownership requires assisted deletion; nothing was deleted';
  end if;
  select jsonb_build_object(
    'r2',coalesce((select jsonb_agg(distinct t-'valid') from jsonb_array_elements(object_targets) t),'[]'::jsonb),
    'stream_uids',coalesce((select jsonb_agg(distinct uid)from(select stream_uid uid from public.renders where listing_id=any(listing_ids)and stream_uid is not null union select t.value#>>'{}'from public.privacy_cleanup_jobs j cross join lateral jsonb_array_elements(j.remaining->'stream_uids')t(value)where j.org_id=any(solo)and j.state in('pending','processing'))streams),'[]'::jsonb),
    'ghl_targets',coalesce((select jsonb_agg(jsonb_strip_nulls(jsonb_build_object('email',email,'phone',phone,'org_id',org_id))) from(
      select distinct nullif(lower(btrim(email)),'') email,nullif(btrim(phone),'') phone,org_id from public.leads where org_id=any(solo)
       and(synced_crm or created_at<=(select legacy_crm_cutoff from public.privacy_runtime where singleton))and(nullif(btrim(email),'')is not null or nullif(btrim(phone),'')is not null)
      union select nullif(t->>'email',''),nullif(t->>'phone',''),j.org_id from public.privacy_cleanup_jobs j cross join lateral jsonb_array_elements(j.remaining->'ghl_targets')t where j.org_id=any(solo)and j.state in('pending','processing')
    ) targets),'[]'::jsonb),
    'r2_prefixes',coalesce((select jsonb_agg(jsonb_build_object('bucket',bucket,'org_id',owned.org_id,'prefix',prefix,'removed_count',0))from unnest(solo)owned(org_id) cross join lateral(values(p_render_bucket,'ai-router/'||owned.org_id||'/'),(p_upload_bucket,'presenter-private/'||owned.org_id||'/'))p(bucket,prefix)),'[]'::jsonb),
    'apple_refresh_token',apple_token,'analytics_user_id',p_user,'profile_id',p_user,'auth_user_id',p_user
    ,'provider_leases',provider_targets,'multipart_uploads',multipart_targets,'unresolved_uploads',unresolved_targets,
    'storage_not_before',storage_after,'unresolved_render_jobs',coalesce((select jsonb_agg(id) from public.render_jobs
      where id=any(job_ids) and source='worker' and status='processing'),'[]'::jsonb)
  ) into payload;
  if exists(select 1 from jsonb_array_elements(provider_targets) t where
    t->>'lease_token' !~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$') then
    raise exception 'RP409: invalid provider identity; nothing was deleted';
  end if;
  if octet_length(payload::text)>8388608 or jsonb_array_length(payload->'r2')>25000 then raise exception 'RP413: account requires assisted deletion'; end if;
  scope:=jsonb_build_object('source_user_id',p_user,'solo_orgs',solo,'shared_orgs',shared,'db_purged',true);
  -- Intent precedes every destructive write. Any subsequent SQL failure rolls
  -- back BOTH the intent and all DB destruction; no Edge cleanup is authorized.
  insert into public.deletion_requests(user_id,email,status,payload,snapshot_version,ownership_scope)
    values(p_user,email_value,'pending',payload,2,scope) returning id into request_id;
  foreach org in array shared loop
    select user_id into heir from public.memberships where org_id=org and user_id<>p_user
      order by case role when'owner'then 0 when'admin'then 1 when'agent'then 2 else 3 end,user_id limit 1;
    if heir is null then raise exception 'RP409: shared workspace ownership changed'; end if;
    update public.listings set agent_id=heir where org_id=org and agent_id=p_user;
    delete from public.memberships where org_id=org and user_id=p_user;
  end loop;
  update public.renders set published_at=null where listing_id=any(listing_ids);
  if cardinality(spatial_ids)>0 then
    update public.spatial_jobs set published_at=null,approved=false,excluded=true,status='failed',failure_code='account_deleted',
      lease_expires_at=clock_timestamp(),updated_at=clock_timestamp() where id=any(spatial_ids);
    delete from public.spatial_inputs where job_id=any(spatial_ids);
    delete from public.spatial_attempt_history where job_id=any(spatial_ids);
    delete from public.spatial_jobs where id=any(spatial_ids);
  end if;
  delete from public.upload_operations where asset_id in(select asset_id from public.upload_reservations where org_id=any(solo));
  delete from public.upload_reservations where org_id=any(solo);
  delete from public.org_brand_assets where org_id=any(solo);
  delete from public.metering where org_id=any(solo) or render_id=any(render_ids);
  delete from public.leads where org_id=any(solo) or render_id=any(render_ids) or listing_id=any(listing_ids);
  -- Financial totals, immutable parent liability and exact hold links survive
  -- account removal; personal content/request references do not.
  update public.cost_ledger set org_id=null,job_id=null,meta='{}'::jsonb,idempotency_key=null
    where org_id=any(solo) or job_id=any(job_ids);
  delete from public.renders where listing_id=any(listing_ids);
  delete from public.render_jobs where listing_id=any(listing_ids);
  delete from public.capture_chapters where asset_id=any(asset_ids);
  delete from public.capture_assets where listing_id=any(listing_ids);
  delete from public.photos where listing_id=any(listing_ids);
  delete from public.listings where org_id=any(solo);
  delete from public.memberships where org_id=any(solo);
  delete from public.studio_project_media where actor_id=p_user;
  delete from public.orgs where id=any(solo);
  -- Preserve unproven old payloads, but do not let them run against a winner.
  update public.deletion_requests set status='pending',manual_review_required=true,
    last_error='Unverified legacy ownership snapshot: manual reconciliation required'
    where user_id=p_user and snapshot_version<>2 and status<>'completed';
  return public.claim_account_deletion(request_id);
end;
$function$
;

-- Match the capability correction already applied operationally. A Fill
-- endpoint accepts a supplied mask; it is not a free-text edit route.
update public.ai_routes set capabilities=array['mask']::text[]
 where provider='fal'and model in('flux-pro/v1/fill','fal-ai/flux-pro/v1/fill')
 and capabilities is distinct from array['mask']::text[];

-- Recover only relationships backed by an actual current accepted owner invite.
-- No memberships, subscriptions or historical content are reassigned.
do $backfill$declare r record;begin
 for r in select i.id,i.org_id,i.invited_by,i.accepted_by from public.org_invites i
  join public.memberships m on m.org_id=i.org_id and m.user_id=i.accepted_by
  where i.accepted_at is not null and i.revoked_at is null and not i.private_testing
   and i.invited_by=public.team_library_owner(i.org_id)and m.role in('agent','admin','marketing')
   and not exists(select 1 from public.team_private_libraries b where b.agent_user_id=i.accepted_by and b.revoked_at is null)
 loop
  begin perform public.bind_team_private_library(r.invited_by,r.org_id,r.accepted_by,r.id);
  exception when raise_exception then if sqlerrm not like 'RP409:%'and sqlerrm not like 'RP403:%'then raise;end if;end;
 end loop;
end$backfill$;

-- A device session is fenced independently of Auth session lifetime. Local
-- sign-out does not necessarily revoke its server JWT. Tombstones keep a late
-- old-session POST from rebinding a phone after its next account registers.
create table if not exists public.notification_device_session_tombstones(
 user_id uuid not null references public.profiles(id)on delete cascade,
 session_id uuid not null,token_sha256 text not null check(token_sha256~'^[0-9a-f]{64}$'),
 environment text not null check(environment in('sandbox','production')),
 created_at timestamptz not null default now(),primary key(user_id,session_id,token_sha256,environment));
alter table public.notification_devices add column if not exists registration_session_id uuid;
alter table public.notification_device_session_tombstones enable row level security;
revoke all on public.notification_device_session_tombstones from public,anon,authenticated,service_role;

create or replace function public.notification_unregister_device(p_user uuid,p_session uuid,p_token text,p_environment text)returns jsonb
language plpgsql security definer set search_path='' as $unregister$
declare v_token text:=lower(btrim(coalesce(p_token,'')));v_env text:=lower(btrim(coalesce(p_environment,'production')));digest text;removed integer;
begin
 if p_user is null or p_session is null then raise exception 'RP400: A device session is required';end if;
 if v_token=''or length(v_token)>400 or v_token!~'^[0-9a-fA-F]+$'then raise exception 'RP400: device_token must be a hexadecimal APNs token';end if;
 if v_env not in('sandbox','production')then raise exception 'RP400: environment must be sandbox or production';end if;
 digest:=pg_catalog.encode(pg_catalog.sha256(pg_catalog.convert_to(v_token,'UTF8')),'hex');
 perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('notification-device:'||digest,72453));
 perform 1 from public.profiles where id=p_user for key share;
 if not found then raise exception 'RP401: Sign in again';end if;
 insert into public.notification_device_session_tombstones(user_id,session_id,token_sha256,environment)
 values(p_user,p_session,digest,v_env)on conflict do nothing;
 delete from public.notification_devices where user_id=p_user and lower(device_token)=v_token and environment=v_env
  and(registration_session_id=p_session or registration_session_id is null);
 get diagnostics removed=row_count;
 return jsonb_build_object('ok',true,'unregistered',true,'removed',removed>0);
end$unregister$;
create or replace function public.notification_register_device_session(p_user uuid,p_session uuid,p_token text,p_bundle_id text default null,p_environment text default null,p_locale text default null,p_app_version text default null)returns public.notification_devices
language plpgsql security definer set search_path='' as $register$
declare v_token text:=lower(btrim(coalesce(p_token,'')));v_env text:=lower(btrim(coalesce(p_environment,'production')));digest text;v_row public.notification_devices;
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
 -- Retire pre-normalization spellings under the canonical token lock.
 -- A legitimate new registration rebinds that physical device, as before.
 delete from public.notification_devices where lower(device_token)=v_token and device_token<>v_token;
 v_row:=public.notification_register_device(p_user,v_token,p_bundle_id,v_env,p_locale,p_app_version);
 update public.notification_devices set registration_session_id=p_session where id=v_row.id returning *into v_row;
 return v_row;
end$register$;
revoke all on function public.notification_unregister_device(uuid,uuid,text,text),public.notification_register_device_session(uuid,uuid,text,text,text,text,text)from public,anon,authenticated;
grant execute on function public.notification_unregister_device(uuid,uuid,text,text),public.notification_register_device_session(uuid,uuid,text,text,text,text,text)to service_role,postgres;
commit;
