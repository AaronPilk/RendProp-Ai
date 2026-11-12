-- C2: an agent can discard a saved video request that the server never
-- accepted, then change photos/options under a new operation. Abandonment,
-- admission, capacity refusal and lookup serialize on the same per-actor
-- operation lock. Accepted work always keeps its job and its normal
-- cancellation/recovery; a durable capacity refusal stays a refusal.
begin;
create table if not exists public.property_video_abandoned_operations(
 actor_id uuid not null references auth.users(id)on delete cascade,operation_id uuid not null,
 listing_id uuid not null references public.listings(id)on delete cascade,library_org_id uuid not null,
 created_at timestamptz not null default now(),primary key(actor_id,operation_id));
alter table public.property_video_abandoned_operations enable row level security;
-- Tombstones are written only by the definer RPC below and are never edited.
revoke all on public.property_video_abandoned_operations from public,anon,authenticated,service_role;
grant select on public.property_video_abandoned_operations to service_role;

-- Every job or refusal row for an operation passes this fence, whichever RPC
-- inserts it. The lock is re-entrant for admission/enqueue (which already hold
-- it) and makes a concurrent abandonment commit first or wait. Under READ
-- COMMITTED the check then sees a tombstone committed while this one waited;
-- an older snapshot could miss it, so other isolation levels fail closed.
create or replace function public.property_video_operation_open()returns trigger language plpgsql security definer set search_path=''as $$begin
 perform pg_advisory_xact_lock(hashtextextended('property-video-operation:'||new.actor_id||':'||new.operation_id,79));
 if current_setting('transaction_isolation')<>'read committed'then raise exception'RP503: Saved video operations require read-committed admission';end if;
 if exists(select 1 from public.property_video_abandoned_operations where actor_id=new.actor_id and operation_id=new.operation_id)then
  raise exception'RP409: This saved video request was discarded before the server accepted it. Start a new video instead.';end if;
 return new;end$$;
drop trigger if exists property_video_jobs_operation_open on public.property_video_jobs;
create trigger property_video_jobs_operation_open before insert or update of actor_id,operation_id on public.property_video_jobs for each row execute function public.property_video_operation_open();
drop trigger if exists property_video_refused_operation_open on public.property_video_refused_operations;
create trigger property_video_refused_operation_open before insert or update of actor_id,operation_id on public.property_video_refused_operations for each row execute function public.property_video_operation_open();

-- Discard resolves the exact saved operation first. An accepted job is
-- returned untouched; a refusal is reported; only an unseen operation gets a
-- permanent tombstone. Replays after a lost reply return the same outcome.
create or replace function public.property_video_operation_abandon(p_actor uuid,p_listing uuid,p_expected uuid,p_operation uuid)returns jsonb language plpgsql security definer set search_path=''as $$declare j public.property_video_jobs;r public.property_video_refused_operations;a public.property_video_abandoned_operations;org uuid;begin
 if current_setting('role',true)is distinct from'service_role'then raise insufficient_privilege;end if;
 if p_actor is null or p_listing is null or p_expected is null or p_operation is null then raise exception'RP400: Use the exact saved video operation';end if;
 if current_setting('transaction_isolation')<>'read committed'then raise exception'RP503: Saved video operations require read-committed admission';end if;
 if not exists(select 1 from auth.users where id=p_actor and is_anonymous=false)then raise exception'RP403: A named account is required';end if;
 org:=public.property_video_actor_org(p_actor,p_expected,p_listing);
 perform pg_advisory_xact_lock(hashtextextended('property-video-operation:'||p_actor||':'||p_operation,79));
 select * into j from public.property_video_jobs where actor_id=p_actor and operation_id=p_operation;
 select * into r from public.property_video_refused_operations where actor_id=p_actor and operation_id=p_operation;
 select * into a from public.property_video_abandoned_operations where actor_id=p_actor and operation_id=p_operation;
 if(j.id is not null and j.listing_id<>p_listing)or(r.operation_id is not null and r.listing_id<>p_listing)or(a.operation_id is not null and a.listing_id<>p_listing)then raise exception'RP409: This saved operation belongs to another property';end if;
 if j.id is null and r.operation_id is null and a.operation_id is null then
  insert into public.property_video_abandoned_operations(actor_id,operation_id,listing_id,library_org_id)values(p_actor,p_operation,p_listing,public.listing_owner_library(p_listing))returning * into a;
 end if;
 return jsonb_build_object('operation_id',p_operation,'listing_id',p_listing,'org_id',org,'selected_library_org_id',p_expected,'operation_closed',r.operation_id is not null or a.operation_id is not null,
  'closed_reason',case when r.operation_id is not null then'capacity_refused'when a.operation_id is not null then'abandoned'end,
  'message',coalesce(r.message,case when a.operation_id is not null then'You discarded this saved request before the server accepted it. No video was started from it.'end),'job_id',j.id);end$$;

-- Same contract as before, plus the abandoned closure and its reason.
create or replace function public.property_video_operation_lookup(p_actor uuid,p_listing uuid,p_expected uuid,p_operation uuid)returns jsonb language plpgsql security definer set search_path=''as $$declare j public.property_video_jobs;r public.property_video_refused_operations;a public.property_video_abandoned_operations;org uuid;begin
 org:=public.property_video_actor_org(p_actor,p_expected,p_listing);
 perform pg_advisory_xact_lock(hashtextextended('property-video-operation:'||p_actor||':'||p_operation,79));
 select * into j from public.property_video_jobs where actor_id=p_actor and operation_id=p_operation;
 select * into r from public.property_video_refused_operations where actor_id=p_actor and operation_id=p_operation;
 select * into a from public.property_video_abandoned_operations where actor_id=p_actor and operation_id=p_operation;
 if(j.id is not null and j.listing_id<>p_listing)or(r.operation_id is not null and r.listing_id<>p_listing)or(a.operation_id is not null and a.listing_id<>p_listing)then raise exception'RP409: This saved operation belongs to another property';end if;
 return jsonb_build_object('operation_id',p_operation,'listing_id',p_listing,'org_id',org,'selected_library_org_id',p_expected,'operation_closed',r.operation_id is not null or a.operation_id is not null,
  'closed_reason',case when r.operation_id is not null then'capacity_refused'when a.operation_id is not null then'abandoned'end,
  'message',coalesce(r.message,case when a.operation_id is not null then'You discarded this saved request before the server accepted it. No video was started from it.'end),'job_id',j.id);end$$;
revoke all on function public.property_video_operation_open(),public.property_video_operation_abandon(uuid,uuid,uuid,uuid),public.property_video_operation_lookup(uuid,uuid,uuid,uuid)from public,anon,authenticated;
grant execute on function public.property_video_operation_abandon(uuid,uuid,uuid,uuid),public.property_video_operation_lookup(uuid,uuid,uuid,uuid)to service_role;
commit;
