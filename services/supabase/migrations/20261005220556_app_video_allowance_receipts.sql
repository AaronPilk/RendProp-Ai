begin;
-- Exact original-window receipts. Existing nonvideo meters are unchanged.
create or replace function public.bump_rate_receipt(p_key text,p_window_seconds integer,p_max integer,p_cost integer default 1)
returns jsonb language plpgsql security definer set search_path='' as $$
declare accepted boolean;w timestamptz;
begin
 if current_setting('role',true)is distinct from 'service_role'then raise insufficient_privilege;end if;
 if p_key is null or length(p_key)not between 1 and 512 or p_window_seconds is null or p_window_seconds not between 1 and 2592000 or p_max is null or p_max<1 or p_cost is null or p_cost not between 1 and 1000000 then raise exception 'RP400: Invalid quota charge';end if;
 accepted:=public.bump_rate(p_key,p_window_seconds,p_max,p_cost);
 select window_start into w from public.rate_limits where key=p_key;
 if w is null then raise exception 'RP409: Quota window could not be confirmed';end if;
 return jsonb_build_object('accepted',accepted,'window_start',w);
end$$;
create or replace function public.refund_rate_receipt(p_key text,p_window_seconds integer,p_window_start timestamptz,p_cost integer default 1)
returns boolean language plpgsql security definer set search_path='' as $$
begin
 if current_setting('role',true)is distinct from 'service_role'then raise insufficient_privilege;end if;
 if p_cost is null or p_cost<1 or p_window_start is null then return false;end if;
 update public.rate_limits set count=greatest(0,count-p_cost)where key=p_key and window_seconds=p_window_seconds and window_start=p_window_start and count>0;
 return found;
end$$;
revoke all on function public.bump_rate_receipt(text,integer,integer,integer),public.refund_rate_receipt(text,integer,timestamptz,integer)from public,anon,authenticated;
grant execute on function public.bump_rate_receipt(text,integer,integer,integer),public.refund_rate_receipt(text,integer,timestamptz,integer)to service_role;

create table if not exists public.app_video_allowance_receipts(
 reservation_id uuid primary key references public.app_video_cost_reservations(id),
 listing_id uuid, -- immutable tombstone, deliberately no deletion-blocking FK
 monthly_key text not null,monthly_window_start timestamptz not null,
 burst_key text not null,burst_window_start timestamptz not null,
 drift_refunded_at timestamptz,created_at timestamptz not null default now());
alter table public.app_video_allowance_receipts enable row level security;
revoke all on public.app_video_allowance_receipts from public,anon,authenticated,service_role;
grant select,insert on public.app_video_allowance_receipts to service_role;
create or replace function public.app_video_allowance_pin()
returns trigger language plpgsql set search_path=''as $$begin
 if row(new.reservation_id,new.listing_id,new.monthly_key,new.monthly_window_start,new.burst_key,new.burst_window_start,new.created_at)is distinct from row(old.reservation_id,old.listing_id,old.monthly_key,old.monthly_window_start,old.burst_key,old.burst_window_start,old.created_at)
 or(old.drift_refunded_at is not null and new.drift_refunded_at is distinct from old.drift_refunded_at)then raise exception 'RP409: Video allowance receipt is immutable';end if;return new;end$$;
drop trigger if exists app_video_allowance_fixed on public.app_video_allowance_receipts;
create trigger app_video_allowance_fixed before update on public.app_video_allowance_receipts for each row execute function public.app_video_allowance_pin();
revoke all on function public.app_video_allowance_pin()from public,anon,authenticated,service_role;

create or replace function public.app_video_cost_reserve_v2(
 p_actor uuid,p_org uuid,p_key text,p_feature text,p_provider text,p_model text,p_input_sha256 text,
 p_hold_cents numeric,p_units numeric,p_unit_cost_cents numeric,p_meta jsonb,
 p_monthly_window_start timestamptz,p_burst_window_start timestamptz,p_listing uuid default null)
returns jsonb language plpgsql security definer set search_path='' as $$
declare r jsonb;monthly text;burst text;
begin
 if current_setting('role',true)is distinct from 'service_role'then raise insufficient_privilege;end if;
 -- The existing writer retains every priced admission, authority, immutable
 -- key, provider, monthly budget and uncertain-dispatch guard.
 r:=public.app_video_cost_reserve(p_actor,p_org,p_key,p_feature,p_provider,p_model,p_input_sha256,p_hold_cents,p_units,p_unit_cost_cents,p_meta);
 if p_listing is not null and not exists(select 1 from public.listings where id=p_listing and org_id=p_org and deleted_at is null)then raise exception 'RP403: Video property is unavailable in this workspace';end if;
 monthly:=(case p_feature when 'drone_render'then 'dronemo'when 'aerial'then 'aerialmo'else 'reelmo'end)||':'||p_org::text;burst:='aivideo:'||p_org::text;
 if p_monthly_window_start is null or p_burst_window_start is null or not exists(select 1 from public.rate_limits where key=monthly and window_start=p_monthly_window_start and window_seconds=2592000 and count>0)
  or not exists(select 1 from public.rate_limits where key=burst and window_start=p_burst_window_start and window_seconds=300 and count>0)then raise exception 'RP409: Original video quota charge could not be confirmed';end if;
 insert into public.app_video_allowance_receipts(reservation_id,listing_id,monthly_key,monthly_window_start,burst_key,burst_window_start)
 values((r->>'id')::uuid,p_listing,monthly,p_monthly_window_start,burst,p_burst_window_start);
 return r;
end$$;
revoke all on function public.app_video_cost_reserve_v2(uuid,uuid,text,text,text,text,text,numeric,numeric,numeric,jsonb,timestamptz,timestamptz,uuid)from public,anon,authenticated;
grant execute on function public.app_video_cost_reserve_v2(uuid,uuid,text,text,text,text,text,numeric,numeric,numeric,jsonb,timestamptz,timestamptz,uuid)to service_role;

create or replace function public.app_video_refund_drift(p_actor uuid,p_org uuid,p_request text,p_feature text)
returns jsonb language plpgsql security definer set search_path=''as $$
declare r public.app_video_cost_reservations;a public.app_video_allowance_receipts;refunded boolean;
begin
 if current_setting('role',true)is distinct from 'service_role'then raise insufficient_privilege;end if;
 perform 1 from public.orgs where id=p_org and deleted_at is null for update;
 if not found or not exists(select 1 from auth.users where id=p_actor and is_anonymous is false)
  or not exists(select 1 from public.memberships where user_id=p_actor and org_id=p_org and role in('owner','admin','agent'))
  or exists(select 1 from public.deletion_requests where user_id=p_actor and status in('pending','processing'))then raise exception 'RP403: Current video workspace authority is required';end if;
 select * into r from public.app_video_cost_reservations where org_id=p_org and actor_id=p_actor and provider_request_id=p_request and feature=p_feature and settled_at is not null and released_at is null order by created_at limit 1 for update;
 if not found then return jsonb_build_object('refunded',false,'reason','No owned charged clip receipt was found');end if;
 select * into a from public.app_video_allowance_receipts where reservation_id=r.id for update;
 if not found then return jsonb_build_object('refunded',false,'reason','This older clip has no original quota receipt');end if;
 if a.drift_refunded_at is not null then return jsonb_build_object('refunded',false,'reason','This clip was already refunded');end if;
 if not public.bump_rate('aidriftrefmo:'||p_org::text,2592000,20,1)then return jsonb_build_object('refunded',false,'reason','The monthly clip refund limit was reached');end if;
 refunded:=public.refund_rate_receipt(a.monthly_key,2592000,a.monthly_window_start,1);
 if refunded then perform public.refund_rate_receipt(a.burst_key,300,a.burst_window_start,1);end if;
 update public.app_video_allowance_receipts set drift_refunded_at=now()where reservation_id=r.id;
 return jsonb_build_object('refunded',refunded,'reason',case when refunded then 'The rejected clip allowance was restored'else 'The original allowance window has ended'end);
end$$;
revoke all on function public.app_video_refund_drift(uuid,uuid,text,text)from public,anon,authenticated;
grant execute on function public.app_video_refund_drift(uuid,uuid,text,text)to service_role;
commit;
