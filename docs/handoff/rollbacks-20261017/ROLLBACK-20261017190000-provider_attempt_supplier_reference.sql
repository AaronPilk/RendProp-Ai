-- Rollback for 20261017190000_provider_attempt_supplier_reference.sql (E3; file renamed from 20261017170000, content identical).
-- Run ONLY after every `property` function instance that passes
-- p_provider_request_ref has been rolled back (the helper's fallback to the
-- eight-argument RPC covers the window, but do not rely on it on purpose).
-- Restores the original eight-argument body (md5 7516d4d95ab1a53363f7dbeb9484673f)
-- from 20261016192846, drops the nine-argument overload, then the column
-- (which drops its two check constraints with it). Stored references are lost.
begin;
drop function if exists public.provider_attempt_finish(uuid,uuid,uuid,text,integer,uuid,text,numeric,text);
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
revoke all on function public.provider_attempt_finish(uuid,uuid,uuid,text,integer,uuid,numeric,text)from public,anon,authenticated;
grant execute on function public.provider_attempt_finish(uuid,uuid,uuid,text,integer,uuid,numeric,text)to service_role;
alter table public.provider_attempt_receipts drop column if exists provider_request_ref;
do $check$begin
 if (select md5(prosrc) from pg_proc where oid='public.provider_attempt_finish(uuid,uuid,uuid,text,integer,uuid,numeric,text)'::regprocedure)<>'7516d4d95ab1a53363f7dbeb9484673f'
  then raise exception 'Rollback did not restore the original eight-argument body';end if;
end$check$;
commit;
