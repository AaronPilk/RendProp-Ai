-- Exact provider acceptance survives a lost HTTP202. A reservation/ledger
-- cannot reconstruct submitted_at: that original string binds the private
-- output identity. No existing receipt is inferred, backfilled or dispatched.
create table if not exists public.app_video_submission_receipts(
 reservation_id uuid primary key references public.app_video_cost_reservations(id)on delete cascade,
 actor_id uuid not null references public.profiles(id)on delete cascade,
 org_id uuid not null references public.orgs(id)on delete cascade,
 operation_id text not null check(operation_id~'^[!-~]{8,128}$'),
 listing_id uuid not null references public.listings(id)on delete cascade,
 receipt jsonb not null check(jsonb_typeof(receipt)='object'and octet_length(receipt::text)<=2048),
 created_at timestamptz not null default now(),unique(org_id,operation_id));
create unique index if not exists app_video_submission_provider_identity
 on public.app_video_submission_receipts((receipt->>'provider'),(receipt->>'id'));
alter table public.app_video_submission_receipts enable row level security;
revoke all on public.app_video_submission_receipts from public,anon,authenticated,service_role;
-- No direct service writes either. Canonical parent erasure may cascade DELETE;
-- a blanket DELETE trigger would break account/property deletion.
create or replace function public.app_video_submission_receipt_immutable()
returns trigger language plpgsql set search_path=''as $$begin
 if new is distinct from old then raise exception'RP409: The original video submission receipt is immutable';end if;
 return new;end$$;
drop trigger if exists app_video_submission_fixed on public.app_video_submission_receipts;
create trigger app_video_submission_fixed before update on public.app_video_submission_receipts
 for each row execute function public.app_video_submission_receipt_immutable();
revoke all on function public.app_video_submission_receipt_immutable()from public,anon,authenticated,service_role;

-- Mirrors paidRoutedReceiptMatches(false), including validated acceptance whose
-- serving hold succeeded but whose app settlement has not yet committed.
-- This only verifies authority; it never settles, releases or reserves money.
create or replace function public.app_video_submission_receipt_authority(
 p_actor uuid,p_org uuid,p_key text,p_listing uuid,p_receipt jsonb
)returns uuid language plpgsql stable security definer set search_path=''as $$
declare scope jsonb;r public.app_video_cost_reservations;h public.serving_cost_reservations;
 a public.app_video_allowance_receipts;l public.cost_ledger;endpoint text;root text;t timestamptz;
begin
 if current_setting('role',true)is distinct from'service_role'then raise insufficient_privilege using message='service role required';end if;
 if p_actor is null or p_org is null or p_listing is null or p_key is null or p_key!~'^[!-~]{8,128}$'
  or p_receipt is null or jsonb_typeof(p_receipt)is distinct from'object'or octet_length(p_receipt::text)>2048
  or not(p_receipt?&array['provider','model','id','poll_url','submitted_at'])
  or exists(select 1 from jsonb_each(p_receipt)x where x.key not in('provider','model','id','poll_url','submitted_at')or jsonb_typeof(x.value)is distinct from'string')
  or p_receipt->>'provider'is distinct from'fal'
  or (p_receipt->>'model')!~'^[A-Za-z0-9][A-Za-z0-9._-]*(/[A-Za-z0-9][A-Za-z0-9._-]*)+$'
  or length(p_receipt->>'model')>240 or length(p_receipt->>'id')not between 1 and 256 or(p_receipt->>'id')!~'^[A-Za-z0-9_-]+$'
  or(p_receipt->>'submitted_at')!~'^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}([.][0-9]{1,9})?(Z|[+-][0-9]{2}:[0-9]{2})$'
 then raise exception'RP400: An exact supported video submission receipt is required';end if;
 begin t:=(p_receipt->>'submitted_at')::timestamptz;exception when others then raise exception'RP400: Invalid original video submission timestamp';end;
 endpoint:=case when p_receipt->>'model'like'fal-ai/%'or p_receipt->>'model'like'bria/%'then p_receipt->>'model'else'fal-ai/'||(p_receipt->>'model')end;
 root:=split_part(endpoint,'/',1)||'/'||split_part(endpoint,'/',2);
 -- Exact same full endpoint or official SDK owner/alias root, no credentials,
 -- query, fragment, percent escapes, sibling model or arbitrary remote host.
 if p_receipt->>'poll_url'not in('https://queue.fal.run/'||endpoint||'/requests/'||(p_receipt->>'id')||'/status',
  'https://queue.fal.run/'||root||'/requests/'||(p_receipt->>'id')||'/status')then raise exception'RP400: The provider receipt URL does not match its model and request';end if;
 -- Same current READ authority as routedContentOrg/contentOrgForUser status;
 -- a paid actor who now has a read-only role may retrieve their own receipt.
 scope:=public.listing_library_scope(p_actor,p_listing);
 if scope->>'org_id'is distinct from p_org::text then raise exception'RP404: The saved video belongs to another library';end if;
 select*into r from public.app_video_cost_reservations where actor_id=p_actor and org_id=p_org and idempotency_key=p_key;
 if not found or r.feature<>'reel'or r.provider<>'fal'or r.model is distinct from p_receipt->>'model'
  or r.meta->>'task'is distinct from'video.reel_clip'or r.released_at is not null
  or r.input_sha256!~'^[a-f0-9]{64}$'or not(r.total_cents>0 and r.hold_cents>=r.total_cents)
  or not isfinite(t)or t<r.created_at-interval'5 minutes'or t>now()+interval'5 minutes'
 then return null;end if;
 select*into a from public.app_video_allowance_receipts where reservation_id=r.id;
 if not found or a.listing_id is distinct from p_listing then return null;end if;
 if r.provider_request_id is null and r.cost_ledger_id is null and r.settled_at is null then
  select*into h from public.serving_cost_reservations where org_id=p_org and actor_id=p_actor and request_key=p_key
   and stage='reel'and provider=r.provider and model=r.model;
  if not found or(select count(*)from public.serving_cost_reservations where org_id=p_org and actor_id=p_actor and request_key=p_key
   and stage='reel'and provider=r.provider and model=r.model)<>1
   or h.input_sha256 is distinct from r.input_sha256 or h.state<>'succeeded'or h.ledger_id is not null
   or r.billing_org_id is null or h.billing_org_id is distinct from r.billing_org_id
   or not(h.hold_cents>=r.total_cents)then return null;end if;
 else
  if r.provider_request_id is distinct from p_receipt->>'id'or r.cost_ledger_id is null or r.settled_at is null then return null;end if;
  select*into l from public.cost_ledger where id=r.cost_ledger_id;
  if not found or l.org_id is distinct from p_org or l.feature<>'reel'or l.provider<>r.provider or l.model<>r.model
   or not(l.total_cents>0)or l.meta->>'app_video_reservation_id'is distinct from r.id::text
   or l.meta->>'request_id'is distinct from p_receipt->>'id'or l.meta->>'billing_org_id'is distinct from p_org::text
   or l.meta->>'request_key'is distinct from p_key or l.meta->>'stage'is distinct from'reel'then return null;end if;
 end if;
 return r.id;
end$$;
revoke all on function public.app_video_submission_receipt_authority(uuid,uuid,text,uuid,jsonb)from public,anon,authenticated;
grant execute on function public.app_video_submission_receipt_authority(uuid,uuid,text,uuid,jsonb)to service_role;

create or replace function public.app_video_submission_receipt_save(
 p_actor uuid,p_org uuid,p_key text,p_listing uuid,p_receipt jsonb
)returns jsonb language plpgsql security definer set search_path=''as $$
declare id uuid;s public.app_video_submission_receipts;
begin
 if current_setting('role',true)is distinct from'service_role'then raise insufficient_privilege using message='service role required';end if;
 -- Canonical deletion lock order; the parent FKs make a late acceptance
 -- incapable of resurrecting a deleted actor/workspace/property.
 perform 1 from auth.users where auth.users.id=p_actor for share;
 perform 1 from public.profiles where profiles.id=p_actor for share;
 perform 1 from public.orgs where orgs.id=p_org for share;
 perform 1 from public.listings where listings.id=p_listing for share;
 perform 1 from public.app_video_cost_reservations where actor_id=p_actor and org_id=p_org and idempotency_key=p_key for update;
 id:=public.app_video_submission_receipt_authority(p_actor,p_org,p_key,p_listing,p_receipt);
 if id is null then raise exception'RP409: The accepted video receipt does not match its held or paid admission';end if;
 select*into s from public.app_video_submission_receipts where reservation_id=id;
 if found then
  if row(s.actor_id,s.org_id,s.operation_id,s.listing_id,s.receipt)is distinct from row(p_actor,p_org,p_key,p_listing,p_receipt)
  then raise exception'RP409: The original video submission receipt is immutable';end if;
 else
  insert into public.app_video_submission_receipts(reservation_id,actor_id,org_id,operation_id,listing_id,receipt)
   values(id,p_actor,p_org,p_key,p_listing,p_receipt);
 end if;
 return jsonb_build_object('saved',true,'receipt',p_receipt);
end$$;
revoke all on function public.app_video_submission_receipt_save(uuid,uuid,text,uuid,jsonb)from public,anon,authenticated;
grant execute on function public.app_video_submission_receipt_save(uuid,uuid,text,uuid,jsonb)to service_role;

create or replace function public.app_video_submission_receipt_read(
 p_actor uuid,p_org uuid,p_key text,p_listing uuid
)returns jsonb language plpgsql stable security definer set search_path=''as $$
declare scope jsonb;s public.app_video_submission_receipts;reply jsonb;
begin
 if current_setting('role',true)is distinct from'service_role'then raise insufficient_privilege using message='service role required';end if;
 if p_actor is null or p_org is null or p_listing is null or p_key is null or p_key!~'^[!-~]{8,128}$'
 then raise exception'RP400: An exact saved video operation scope is required';end if;
 scope:=public.listing_library_scope(p_actor,p_listing);
 if scope->>'org_id'is distinct from p_org::text then raise exception'RP404: The saved video belongs to another library';end if;
 reply:=jsonb_build_object('actor_id',p_actor,'org_id',p_org,'listing_id',p_listing,'operation_id',p_key);
 select*into s from public.app_video_submission_receipts where actor_id=p_actor and org_id=p_org and operation_id=p_key and listing_id=p_listing;
 if not found then return reply||jsonb_build_object('status','pending');end if;
 if public.app_video_submission_receipt_authority(p_actor,p_org,p_key,p_listing,s.receipt)is distinct from s.reservation_id
 then raise exception'RP409: The saved video held or paid admission could not be verified';end if;
 return reply||jsonb_build_object('status','accepted','receipt',s.receipt);
end$$;
revoke all on function public.app_video_submission_receipt_read(uuid,uuid,text,uuid)from public,anon,authenticated;
grant execute on function public.app_video_submission_receipt_read(uuid,uuid,text,uuid)to service_role;
