-- Supplier request reference for RentCast attempt receipts (O09 / E3).
-- RentCast answers from Google Frontend with `x-cloud-trace-context` (a 32-hex
-- trace id) and no `x-request-id`, so the uuid column stayed null for every
-- real lookup. This adds one bounded text column and a nine-argument finish
-- overload that stores it; the eight-argument RPC becomes a delegating wrapper
-- so an in-flight pre-reference function keeps working. No price, admission,
-- grant, route, trigger, historical row, uuid column or default is changed.
begin;
do $guard$declare f record;begin
 select p.*,l.lanname into f from pg_proc p join pg_language l on l.oid=p.prolang
 where p.oid=to_regprocedure('public.provider_attempt_finish(uuid,uuid,uuid,text,integer,uuid,numeric,text)');
 if not found or md5(f.prosrc)not in('7516d4d95ab1a53363f7dbeb9484673f','b40c02ede684b8c0e918a90c3bc2788c')
  or f.prosecdef is distinct from true or f.proconfig is distinct from array['search_path=""']
  or f.proacl is distinct from array['postgres=X/postgres','service_role=X/postgres']::aclitem[]
  or pg_get_userbyid(f.proowner)is distinct from'postgres' or f.lanname is distinct from'plpgsql'
  or f.prorettype is distinct from'jsonb'::regtype or f.proretset or f.prokind<>'f'
  or f.proisstrict or f.proleakproof or f.provolatile<>'v'
  or f.proargnames is distinct from array['p_actor','p_org','p_attempt','p_outcome','p_http_status','p_provider_request_id','p_estimated_cents','p_ledger_status']
  or f.pronargs<>8 or f.pronargdefaults<>0 or f.proargdefaults is not null or f.provariadic<>0 then
  raise exception'Review changed provider attempt finish authority';end if;
 select p.*,l.lanname into f from pg_proc p join pg_language l on l.oid=p.prolang
 where p.oid=to_regprocedure('public.provider_attempt_finish(uuid,uuid,uuid,text,integer,uuid,text,numeric,text)');
 if found and(md5(f.prosrc)<>'13e21de79cd2d4217211b078493f3fa3' or f.prosecdef is distinct from true or f.proconfig is distinct from array['search_path=""']
  or pg_get_userbyid(f.proowner)is distinct from'postgres')then raise exception'Review changed provider attempt reference authority';end if;
 if to_regclass('public.provider_attempt_receipts')is null then raise exception'Provider attempt receipts must exist before a supplier reference';end if;
 if exists(select 1 from pg_attribute where attrelid='public.provider_attempt_receipts'::regclass and attname='provider_request_ref'
  and not attisdropped and(atttypid<>'text'::regtype or attnotnull or atthasdef))then raise exception'Review changed provider_request_ref';end if;
 if exists(select 1 from pg_attribute where attrelid='public.provider_attempt_receipts'::regclass and attname='provider_request_id'
  and not attisdropped and atttypid<>'uuid'::regtype)then raise exception'Review changed provider_request_id';end if;
end$guard$;
alter table public.provider_attempt_receipts add column if not exists provider_request_ref text;
comment on column public.provider_attempt_receipts.provider_request_ref is 'Opaque supplier-side reference when it is not a UUID (RentCast: Google Frontend x-cloud-trace-context trace id, 32 hex). Null when the supplier sent none; never a URL, credential, address or client-generated value.';
do $constraints$begin
 if not exists(select 1 from pg_constraint where conrelid='public.provider_attempt_receipts'::regclass and conname='provider_attempt_receipts_request_ref_shape')then
  alter table public.provider_attempt_receipts add constraint provider_attempt_receipts_request_ref_shape check(provider_request_ref is null or provider_request_ref ~ '^[a-f0-9]{32}$');
 end if;
 if not exists(select 1 from pg_constraint where conrelid='public.provider_attempt_receipts'::regclass and conname='provider_attempt_receipts_intent_no_ref')then
  alter table public.provider_attempt_receipts add constraint provider_attempt_receipts_intent_no_ref check(outcome<>'intent' or provider_request_ref is null);
 end if;
end$constraints$;

create or replace function public.provider_attempt_finish(p_actor uuid,p_org uuid,p_attempt uuid,p_outcome text,p_http_status integer,p_provider_request_id uuid,p_provider_request_ref text,p_estimated_cents numeric,p_ledger_status text)
returns jsonb language plpgsql security definer set search_path='' as $$
declare r public.provider_attempt_receipts;basis text;
begin
 if current_setting('role',true)is distinct from 'service_role'then raise insufficient_privilege;end if;
 if p_outcome is null or p_outcome not in('hit','no_record','http_error','invalid_response','transport_unknown')
  or(p_http_status is not null and p_http_status not between 200 and 599)
  or(p_outcome='transport_unknown'and p_http_status is not null)
  or(p_provider_request_ref is not null and p_provider_request_ref !~ '^[a-f0-9]{32}$')
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
  if row(r.outcome,r.http_status,r.provider_request_id,r.provider_request_ref,r.estimated_cents,r.ledger_status)is distinct from row(p_outcome,p_http_status,p_provider_request_id,p_provider_request_ref,p_estimated_cents,p_ledger_status)then raise exception 'RP409: Provider outcome is immutable';end if;
  return jsonb_build_object('saved',true,'replay',true,'attempt_id',r.id);
 end if;
 update public.provider_attempt_receipts set outcome=p_outcome,http_status=p_http_status,provider_request_id=p_provider_request_id,provider_request_ref=p_provider_request_ref,
  estimated_cents=p_estimated_cents,price_basis=basis,ledger_status=p_ledger_status,terminal_at=now()where id=r.id;
 return jsonb_build_object('saved',true,'replay',false,'attempt_id',r.id);
end$$;
-- Pre-reference writer compatibility: identical evidence, no supplier reference.
-- Deploy this migration before the function that passes p_provider_request_ref.
create or replace function public.provider_attempt_finish(p_actor uuid,p_org uuid,p_attempt uuid,p_outcome text,p_http_status integer,p_provider_request_id uuid,p_estimated_cents numeric,p_ledger_status text)
returns jsonb language plpgsql security definer set search_path='' as $$
begin
 return public.provider_attempt_finish(p_actor,p_org,p_attempt,p_outcome,p_http_status,p_provider_request_id,null::text,p_estimated_cents,p_ledger_status);
end$$;
revoke all on function public.provider_attempt_finish(uuid,uuid,uuid,text,integer,uuid,text,numeric,text),public.provider_attempt_finish(uuid,uuid,uuid,text,integer,uuid,numeric,text)from public,anon,authenticated;
grant execute on function public.provider_attempt_finish(uuid,uuid,uuid,text,integer,uuid,text,numeric,text),public.provider_attempt_finish(uuid,uuid,uuid,text,integer,uuid,numeric,text)to service_role;
commit;
