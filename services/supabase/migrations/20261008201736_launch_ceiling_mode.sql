-- Launch ceiling mode — 2026-10-08 (owner decision, see
-- docs/audits/LAUNCH-READINESS-VERDICT-2026-10-08.md and
-- docs/handoff/CLAUDE-LAUNCH-FIXES-20261008.md).
--
-- The funded-serving model (serving_funding / apple_serving_schedules /
-- sponsor pools / media budgets) has no operator tooling yet and refuses every
-- workspace while its tables are empty. Until it can be provisioned in one
-- step, the product runs on the pre-Oct-6 cost model: per-feature meters plus
-- log_job_cost()'s monthly COGS ceilings (1200/2400/6000¢). Everything the
-- funded model added stays in place and becomes active again the moment
-- app_config.serving_mode.mode = 'funded'.
--
-- Also in this file:
--   * one free published listing per workspace (lifetime, by distinct listing);
--   * guest refusals on upload are RP403 (build 42 signs the guest out on 401);
--   * Sandbox purchases grant a 7-day trial plan so App Review can buy;
--   * client recipient verification links are single-use.
-- Every rewrite anchors on the exact live body and fails loudly if it drifted.
begin;

insert into public.app_config(key,value)
values('serving_mode',jsonb_build_object('mode','ceiling','free_published_listings',1,
  'changed_by','claude','changed_at',now(),'reason','launch 2026-10-08: no provisioning tool for funded serving'))
on conflict(key) do update set value=excluded.value,updated_at=now();

create or replace function public.serving_mode()returns text
language sql stable security definer set search_path='' as $$
 select case when (select value->>'mode' from public.app_config where key='serving_mode')='funded' then 'funded' else 'ceiling' end;
$$;
revoke all on function public.serving_mode()from public,anon,authenticated;
grant execute on function public.serving_mode()to service_role;

create or replace function public.free_published_listings()returns integer
language sql stable security definer set search_path='' as $$
 select greatest(0,coalesce((select (value->>'free_published_listings')::integer from public.app_config where key='serving_mode'),1));
$$;
revoke all on function public.free_published_listings()from public,anon,authenticated;
grant execute on function public.free_published_listings()to service_role;

-- A workspace without paid authority may host `free_published_listings`
-- distinct listings for life (deleted listings still count, so deleting does
-- not mint another slot). Re-publishing an already hosted listing is free.
create or replace function public.free_publication_admitted(p_org uuid,p_listing uuid)returns boolean
language sql stable security definer set search_path='' as $$
 select public.serving_mode()='ceiling' and p_listing is not null and (
  exists(select 1 from public.renders r join public.listings l on l.id=r.listing_id where l.org_id=p_org and r.listing_id=p_listing)
  or (select count(distinct r.listing_id) from public.renders r join public.listings l on l.id=r.listing_id where l.org_id=p_org)
     < public.free_published_listings()
 );
$$;
revoke all on function public.free_publication_admitted(uuid,uuid)from public,anon,authenticated;
grant execute on function public.free_publication_admitted(uuid,uuid)to service_role;

-- Sandbox purchase in ceiling mode: a 7-day `trial` plan (3/60/4/2/1, 1200¢
-- ceiling) bound to the Sandbox receipt. Only Sandbox Apple IDs the owner
-- created and App Review can produce one. Never downgrades a paid workspace.
create or replace function public.grant_sandbox_trial(p_org uuid,p_actor uuid,p_original text,p_product text)returns jsonb
language plpgsql security definer set search_path='' as $$
declare o public.orgs;ends timestamptz;
begin
 if current_setting('role',true)is distinct from 'service_role'then raise insufficient_privilege;end if;
 if public.serving_mode()<>'ceiling'then raise exception 'RP403: Sandbox trials require ceiling serving mode';end if;
 select * into o from public.orgs where id=p_org and deleted_at is null for update;
 if o.id is null then raise exception 'RP403: A current workspace is required';end if;
 if not exists(select 1 from public.memberships where org_id=p_org and user_id=p_actor and role in('owner','admin'))then raise exception 'RP403: Only the workspace owner or an admin can add a subscription';end if;
 if public.effective_plan(p_org)in('starter','pro','team','brokerage')then
  return jsonb_build_object('plan',public.effective_plan(p_org),'source',o.plan_source,'expires_at',o.plan_expires_at,'granted',false);
 end if;
 ends:=now()+interval '7 days';
 if o.plan='trial'and o.trial_ends_at is not null and o.trial_ends_at>now()then ends:=o.trial_ends_at;end if;
 update public.orgs set plan='trial',plan_source='trial',trial_ends_at=ends where id=p_org;
 return jsonb_build_object('plan','trial','source','trial','expires_at',ends,'granted',true,'original_transaction_id',p_original,'product_id',p_product);
end$$;
revoke all on function public.grant_sandbox_trial(uuid,uuid,text,text)from public,anon,authenticated;
grant execute on function public.grant_sandbox_trial(uuid,uuid,text,text)to service_role;

-- Exact-anchor rewrite helper (temporary; dropped with the session).
create function pg_temp.rp_patch(fn regprocedure,needle text,replacement text)returns void
language plpgsql as $$
declare def text;n integer;
begin
 def:=pg_get_functiondef(fn);
 n:=(length(def)-length(replace(def,needle,'')))/length(needle);
 if n<>1 then raise exception 'ceiling-mode migration: anchor for % found % times; refusing to patch',fn,n;end if;
 execute replace(def,needle,replacement);
end$$;

do $$
begin
 -- 1. Paid Apple workspaces are paid; funding rows are not required in ceiling mode.
 perform pg_temp.rp_patch('public.subscription_trial_paid_or_override(uuid)'::regprocedure,
  $n$  or(o.plan_source='apple'and exists(select 1 from public.serving_funding f join public.apple_subscriptions s$n$,
  $r$  or(o.plan_source='apple'and public.serving_mode()='ceiling'and public.effective_plan(p_org)in('starter','pro','team'))
  or(o.plan_source='apple'and exists(select 1 from public.serving_funding f join public.apple_subscriptions s$r$);

 -- 2. One free published listing per workspace (publication + render jobs).
 perform pg_temp.rp_patch('public.subscription_trial_render_guard()'::regprocedure,
  $n$ if public.subscription_trial_paid_or_override(org)then return new;end if;$n$,
  $r$ if public.subscription_trial_paid_or_override(org)then return new;end if;
 if public.free_publication_admitted(org,listing)then return new;end if;$r$);

 -- 3. Apple-plan uploads do not wait for funding in ceiling mode.
 perform pg_temp.rp_patch('public.subscription_trial_upload_guard()'::regprocedure,
  $n$  if exists(select 1 from public.orgs where id=new.org_id and plan_source='apple')and not exists($n$,
  $r$  if public.serving_mode()<>'ceiling'and exists(select 1 from public.orgs where id=new.org_id and plan_source='apple')and not exists($r$);

 -- 4. Guest refusals are 403, with the action the build-42 user can take.
 perform pg_temp.rp_patch('public.upload_new_admission(uuid,uuid,bigint)'::regprocedure,
  $n$raise exception 'RP401: Sign in to upload media';$n$,
  $r$raise exception 'RP403: Sign in with Apple to upload and publish';$r$);
 perform pg_temp.rp_patch('public.upload_new_admission(uuid,uuid,bigint)'::regprocedure,
  $n$raise exception 'RP401: Sign in to upload media, or restore your active subscription';$n$,
  $r$raise exception 'RP403: Sign in with Apple to upload and publish (Settings → Account), or restore your active subscription';$r$);

 -- 5. Saved-result journaling works without a money reservation in ceiling mode.
 perform pg_temp.rp_patch('public.serving_operation_complete(uuid,uuid,text,jsonb)'::regprocedure,
  $n$ if not exists(select 1 from public.serving_cost_reservations where org_id=p_org and actor_id=p_actor and request_key=p_key and state<>'rejected')then raise exception 'RP409: Generated result has no admitted provider attempt';end if;$n$,
  $r$ if public.serving_mode()<>'ceiling'and not exists(select 1 from public.serving_cost_reservations where org_id=p_org and actor_id=p_actor and request_key=p_key and state<>'rejected')then raise exception 'RP409: Generated result has no admitted provider attempt';end if;$r$);

 -- 6. Named accounts have usable service in ceiling mode (the client enum has
 --    no 'ceiling' authority; existing_non_apple is its "available, unfunded" shape).
 perform pg_temp.rp_patch('public.subscription_serving_activation(uuid,uuid)'::regprocedure,
  $n$ if o.plan_source is distinct from 'apple'then return jsonb_build_object('org_id',p_org,'available',true,'funded',false,'authority','existing_non_apple');end if;$n$,
  $r$ if public.serving_mode()='ceiling'then return jsonb_build_object('org_id',p_org,'available',true,'funded',false,'authority','existing_non_apple');end if;
 if o.plan_source is distinct from 'apple'then return jsonb_build_object('org_id',p_org,'available',true,'funded',false,'authority','existing_non_apple');end if;$r$);

 -- 7. A verification link confirms once.
 perform pg_temp.rp_patch('public.client_recipient_verification_consume(text)'::regprocedure,
  $n$ if not found or v.expires_at<=now()or not coalesce(c.enabled,false)$n$,
  $r$ if not found or v.consumed_at is not null or v.expires_at<=now()or not coalesce(c.enabled,false)$r$);
end$$;

commit;
