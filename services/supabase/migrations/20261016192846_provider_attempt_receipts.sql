-- Metadata-only property-provider attempts. No funding/admission, rate, price,
-- ledger, existing function, product result, route or default is changed.
begin;
create table if not exists public.provider_attempt_receipts (
 id uuid primary key default gen_random_uuid(),
 actor_id uuid not null references auth.users(id) on delete cascade,
 org_id uuid not null references public.orgs(id) on delete cascade,
 billing_org_id uuid not null references public.orgs(id) on delete cascade,
 operation_sha256 text not null check(operation_sha256 ~ '^[a-f0-9]{64}$'),
 input_sha256 text not null check(input_sha256 ~ '^[a-f0-9]{64}$'),
 provider text not null default 'rentcast' check(provider='rentcast'),
 stage text not null default 'property.lookup' check(stage='property.lookup'),
 model text not null default 'properties' check(model='properties'),
 outcome text not null default 'intent' check(outcome in('intent','hit','no_record','http_error','invalid_response','transport_unknown')),
 http_status integer check(http_status between 200 and 599),
 provider_request_id uuid,
 estimated_cents numeric(20,4) check(estimated_cents>0 and estimated_cents<=100000000 and estimated_cents::text not in('NaN','Infinity','-Infinity')),
 price_basis text not null default 'unknown' check(price_basis in('unknown','configured_catalog_estimate_not_invoice')),
 ledger_status text not null default 'not_booked' check(ledger_status in('not_booked','recorded','unconfirmed')),
 -- No source here can establish an actual invoice charge.
 actual_cents numeric(20,4) check(actual_cents is null),
 created_at timestamptz not null default now(),terminal_at timestamptz,
 unique(actor_id,org_id,operation_sha256),
 check((outcome='intent' and terminal_at is null and http_status is null and provider_request_id is null and estimated_cents is null and price_basis='unknown' and ledger_status='not_booked')
  or(outcome<>'intent' and terminal_at is not null)),
 check((outcome in('hit','no_record') and estimated_cents is not null and price_basis='configured_catalog_estimate_not_invoice' and ledger_status in('recorded','unconfirmed'))
  or(outcome not in('hit','no_record') and estimated_cents is null and price_basis='unknown' and ledger_status='not_booked')),
 check(outcome<>'transport_unknown' or http_status is null)
);
comment on table public.provider_attempt_receipts is 'Service-only metadata: intent is not proof of dispatch, acceptance or charge. Unresolved intent and lost transport are unknown. Catalog estimates are not supplier invoices. No address, customer payload, URL, credential or media.';
create index if not exists provider_attempt_receipts_created on public.provider_attempt_receipts(created_at);
alter table public.provider_attempt_receipts enable row level security;
revoke all on public.provider_attempt_receipts from public,anon,authenticated,service_role;
grant select on public.provider_attempt_receipts to service_role;

create or replace function public.provider_attempt_begin(p_actor uuid,p_org uuid,p_operation_sha256 text,p_input_sha256 text)
returns jsonb language plpgsql security definer set search_path='' as $$
declare r public.provider_attempt_receipts;a jsonb;dispatch boolean:=false;
begin
 if current_setting('role',true)is distinct from 'service_role'then raise insufficient_privilege;end if;
 if p_actor is null or p_org is null or p_operation_sha256 is null or p_operation_sha256 !~ '^[a-f0-9]{64}$'
  or p_input_sha256 is null or p_input_sha256 !~ '^[a-f0-9]{64}$' then raise exception 'RP400: A bounded provider operation identity is required';end if;
 perform 1 from public.orgs where id=p_org and deleted_at is null for update;
 if not found then raise exception 'RP403: Current property editor access is required';end if;
 a:=public.library_access(p_actor,p_org);
 if a->>'can_write' is distinct from 'true' or not(exists(select 1 from auth.users where id=p_actor and is_anonymous is false)
  or public.org_has_verified_retail_guest(p_actor,p_org))then raise exception 'RP403: Current property editor access is required';end if;
 perform pg_advisory_xact_lock(hashtextextended('provider-attempt:'||p_actor||':'||p_org||':'||p_operation_sha256,78132));
 select * into r from public.provider_attempt_receipts where actor_id=p_actor and org_id=p_org and operation_sha256=p_operation_sha256 for update;
 if r.id is not null then
  if r.input_sha256<>p_input_sha256 then raise exception 'RP409: Provider operation inputs are immutable';end if;
 else
  insert into public.provider_attempt_receipts(actor_id,org_id,billing_org_id,operation_sha256,input_sha256)
   values(p_actor,p_org,(a->>'billing_org_id')::uuid,p_operation_sha256,p_input_sha256) returning * into r;
  dispatch:=true;
 end if;
 return jsonb_build_object('attempt_id',r.id,'actor_id',r.actor_id,'org_id',r.org_id,'operation_sha256',r.operation_sha256,'input_sha256',r.input_sha256,'dispatch',dispatch,'outcome',r.outcome);
end$$;

create or replace function public.provider_attempt_finish(p_actor uuid,p_org uuid,p_attempt uuid,p_outcome text,p_http_status integer,p_provider_request_id uuid,p_estimated_cents numeric,p_ledger_status text)
returns jsonb language plpgsql security definer set search_path='' as $$
declare r public.provider_attempt_receipts;basis text;
begin
 if current_setting('role',true)is distinct from 'service_role'then raise insufficient_privilege;end if;
 if p_outcome is null or p_outcome not in('hit','no_record','http_error','invalid_response','transport_unknown')
  or(p_http_status is not null and p_http_status not between 200 and 599)
  or(p_outcome='transport_unknown'and p_http_status is not null)
  or p_ledger_status is null or p_ledger_status not in('not_booked','recorded','unconfirmed')
  or(p_outcome='hit'and(p_http_status is null or p_http_status not between 200 and 299))
  or(p_outcome='no_record'and(p_http_status is null or(p_http_status not between 200 and 299 and p_http_status<>404)))
  or(p_outcome='http_error'and(p_http_status is null or p_http_status<300 or p_http_status=404))
  or(p_outcome='invalid_response'and(p_http_status is null or p_http_status not between 200 and 299))then raise exception 'RP400: Bounded provider outcome evidence is required';end if;
 basis:=case when p_outcome in('hit','no_record')then 'configured_catalog_estimate_not_invoice'else 'unknown'end;
 if (p_outcome in('hit','no_record') and(p_estimated_cents is null or p_estimated_cents<=0 or p_estimated_cents>100000000 or p_estimated_cents::text in('NaN','Infinity','-Infinity') or p_estimated_cents<>round(p_estimated_cents,4) or p_ledger_status='not_booked'))
  or(p_outcome not in('hit','no_record')and(p_estimated_cents is not null or p_ledger_status<>'not_booked'))then raise exception 'RP400: Unknown outcomes cannot invent a charge';end if;
 select * into r from public.provider_attempt_receipts where id=p_attempt and actor_id=p_actor and org_id=p_org for update;
 if r.id is null then raise exception 'RP404: Provider attempt not found';end if;
 if r.outcome<>'intent'then
  if row(r.outcome,r.http_status,r.provider_request_id,r.estimated_cents,r.ledger_status)is distinct from row(p_outcome,p_http_status,p_provider_request_id,p_estimated_cents,p_ledger_status)then raise exception 'RP409: Provider outcome is immutable';end if;
  return jsonb_build_object('saved',true,'replay',true,'attempt_id',r.id);
 end if;
 update public.provider_attempt_receipts set outcome=p_outcome,http_status=p_http_status,provider_request_id=p_provider_request_id,
  estimated_cents=p_estimated_cents,price_basis=basis,ledger_status=p_ledger_status,terminal_at=now()where id=r.id;
 return jsonb_build_object('saved',true,'replay',false,'attempt_id',r.id);
end$$;
revoke all on function public.provider_attempt_begin(uuid,uuid,text,text),public.provider_attempt_finish(uuid,uuid,uuid,text,integer,uuid,numeric,text)from public,anon,authenticated;
grant execute on function public.provider_attempt_begin(uuid,uuid,text,text),public.provider_attempt_finish(uuid,uuid,uuid,text,integer,uuid,numeric,text)to service_role;
commit;
