-- Prospective pipeline modeled-cost linkage. No historical DML, prices or grants.
-- Generic HTTP acceptance remains uncertain; a linked attempt counts the larger
-- of its admitted bound and modeled ledger cost, not both amounts added together.
begin;
-- Before ANY DDL, replay accepts only this migration's exact own objects: the
-- relation's exact shape, constraints, RLS and ACL, and each helper's exact
-- body, security, config, signature and ACL. An unknown same-name object is
-- refused here rather than silently normalised by IF NOT EXISTS / OR REPLACE.
-- Missing objects are the first apply. Nothing below is historical DML.
do $own_replay_guard$
declare e record;p pg_catalog.pg_proc;rel oid;owner_expected oid;service_oid oid;postgres_oid oid;shape text;
begin
 select proowner into owner_expected from pg_catalog.pg_proc where oid='public.serving_cost_finish(uuid,uuid,text,text,text,integer)'::regprocedure;
 select oid into service_oid from pg_catalog.pg_roles where rolname='service_role';
 select oid into postgres_oid from pg_catalog.pg_roles where rolname='postgres';
 if owner_expected is null or service_oid is null then raise exception 'Serving finish authority and service_role must exist before pipeline cost binding';end if;
 for e in select *from(values
  ('public.pipeline_record_provider_cost(uuid,uuid,uuid,text,text,text,text,text,uuid,text,numeric,numeric,numeric,jsonb)','5500cfe7e17058770a1eeeb006196cdd','plpgsql','v','jsonb',
   array['p_actor','p_org','p_reservation','p_key','p_stage','p_provider','p_model','p_input_sha256','p_job','p_feature','p_units','p_unit_cost','p_total','p_meta']),
  ('public.pipeline_cost_covered_cents(uuid,timestamptz,timestamptz)','80187fb4191277dccc4a09eade462407','sql','s','numeric',array['p_reservation','p_start','p_end'])
 )v(signature,body_md5,lang,volatility,result_type,arg_names)loop
  if to_regprocedure(e.signature)is not null then
   select *into p from pg_catalog.pg_proc where oid=to_regprocedure(e.signature);
   if md5(p.prosrc)<>e.body_md5 or p.proowner<>owner_expected or p.prokind<>'f'
    or p.prolang<>(select oid from pg_catalog.pg_language where lanname=e.lang)
    or not p.prosecdef or p.provolatile::text<>e.volatility or p.proisstrict or p.proleakproof or p.proparallel<>'u'
    or p.proconfig is distinct from array['search_path=""']::text[]
    or p.proargnames is distinct from e.arg_names or p.proargmodes is not null or p.proallargtypes is not null
    or p.provariadic<>0 or p.pronargdefaults<>0 or p.proargdefaults is not null
    or p.prorettype is distinct from to_regtype(e.result_type)::oid
    or exists(select 1 from aclexplode(coalesce(p.proacl,acldefault('f',p.proowner)))a
      where a.grantor<>owner_expected or a.privilege_type<>'EXECUTE'or a.is_grantable
       or a.grantee not in(owner_expected,service_oid,postgres_oid))
    or not exists(select 1 from aclexplode(coalesce(p.proacl,acldefault('f',p.proowner)))a where a.grantee=owner_expected)
    or not exists(select 1 from aclexplode(coalesce(p.proacl,acldefault('f',p.proowner)))a where a.grantee=service_oid)then
    raise exception 'Review changed pipeline cost binding helper: %',e.signature;
   end if;
  end if;
 end loop;
 rel:=to_regclass('public.pipeline_provider_cost_bindings');
 if rel is not null then
  select string_agg(a.attname||' '||format_type(a.atttypid,a.atttypmod)||case when a.attnotnull then ' not null'else ''end||coalesce(' default '||pg_get_expr(d.adbin,d.adrelid),''),', 'order by a.attnum)
   into shape from pg_catalog.pg_attribute a left join pg_catalog.pg_attrdef d on d.adrelid=a.attrelid and d.adnum=a.attnum
   where a.attrelid=rel and a.attnum>0 and not a.attisdropped;
  if shape is distinct from 'reservation_id uuid not null, ledger_id uuid not null, created_at timestamp with time zone not null default now()'
   or(select string_agg(conname||': '||pg_get_constraintdef(oid),'; 'order by conname)from pg_catalog.pg_constraint where conrelid=rel)is distinct from
    'pipeline_provider_cost_bindings_ledger_id_fkey: FOREIGN KEY (ledger_id) REFERENCES cost_ledger(id) ON DELETE CASCADE; pipeline_provider_cost_bindings_ledger_id_key: UNIQUE (ledger_id); pipeline_provider_cost_bindings_pkey: PRIMARY KEY (reservation_id); pipeline_provider_cost_bindings_reservation_id_fkey: FOREIGN KEY (reservation_id) REFERENCES serving_cost_reservations(id)'
   or(select string_agg(indexrelid::regclass::text,', 'order by indexrelid::regclass::text)from pg_catalog.pg_index where indrelid=rel)is distinct from
    'pipeline_provider_cost_bindings_ledger_id_key, pipeline_provider_cost_bindings_pkey'
   or(select relkind<>'r'or not relrowsecurity or relforcerowsecurity or relowner<>owner_expected from pg_catalog.pg_class where oid=rel)
   or exists(select 1 from pg_catalog.pg_policy where polrelid=rel)
   or exists(select 1 from pg_catalog.pg_trigger where tgrelid=rel and not tgisinternal)
   or exists(select 1 from pg_catalog.pg_class c,aclexplode(coalesce(c.relacl,acldefault('r',c.relowner)))a where c.oid=rel
      and(a.grantor<>owner_expected or a.is_grantable or(a.grantee<>owner_expected and(a.grantee<>service_oid or a.privilege_type<>'SELECT'))))
   or not exists(select 1 from pg_catalog.pg_class c,aclexplode(coalesce(c.relacl,acldefault('r',c.relowner)))a where c.oid=rel and a.grantee=service_oid and a.privilege_type='SELECT')then
   raise exception 'Review changed pipeline cost binding relation: public.pipeline_provider_cost_bindings';
  end if;
 end if;
end$own_replay_guard$;
create table if not exists public.pipeline_provider_cost_bindings (
 reservation_id uuid primary key references public.serving_cost_reservations(id),
 ledger_id uuid not null unique references public.cost_ledger(id) on delete cascade,
 created_at timestamptz not null default now()
);
alter table public.pipeline_provider_cost_bindings enable row level security;
revoke all on public.pipeline_provider_cost_bindings from public,anon,authenticated,service_role;
grant select on public.pipeline_provider_cost_bindings to service_role;

create or replace function public.pipeline_record_provider_cost(
 p_actor uuid,p_org uuid,p_reservation uuid,p_key text,p_stage text,p_provider text,p_model text,
 p_input_sha256 text,p_job uuid,p_feature text,p_units numeric,p_unit_cost numeric,p_total numeric,p_meta jsonb
)returns jsonb language plpgsql security definer set search_path='' as $$
declare r public.serving_cost_reservations;l public.cost_ledger;b public.pipeline_provider_cost_bindings;
 server_meta jsonb;token jsonb;cost_key text;live_org uuid;live_job uuid;
begin
 if current_setting('role',true)is distinct from 'service_role'then raise insufficient_privilege;end if;
 if p_actor is null or p_org is null or p_reservation is null or p_job is null
  or p_key is distinct from p_job::text or p_stage is distinct from 'worker:'||left(p_input_sha256,48)
  or coalesce(p_input_sha256,'')!~'^[a-f0-9]{64}$'
  or p_feature is null or p_feature not in('restage','declutter','hero','drone_render','qc')
  or p_units is null or not(p_units>=0 and p_units<=1000000)or p_units<>round(p_units,4)
  or p_unit_cost is null or not(p_unit_cost>=0 and p_unit_cost<=100000000)or p_unit_cost<>round(p_unit_cost,6)
  or p_total is null or not(p_total>=0 and p_total<=100000000)or p_total<>round(p_total,4)
  or jsonb_typeof(p_meta)is distinct from 'object'or octet_length(p_meta::text)>16000
 then raise exception 'RP400: Exact bounded pipeline accounting identity required';end if;
 -- Same lock/row order as finish; a concurrent definitive rejection cannot
 -- race through a completed accounting write. No fresh grant is created here.
 perform pg_advisory_xact_lock(hashtextextended('serving:'||p_org,72452));
 select *into r from public.serving_cost_reservations where id=p_reservation for update;
 if r.id is null or r.actor_id is distinct from p_actor or r.org_id is distinct from p_org
  or r.request_key is distinct from p_key or r.stage is distinct from p_stage
  or r.provider is distinct from p_provider or r.model is distinct from p_model
  or r.input_sha256 is distinct from p_input_sha256 or r.billing_org_id is null
  or r.state='rejected'
 then raise exception 'RP403: Pipeline cost does not match its admitted attempt';end if;
 token:=jsonb_build_object('reservation_id',r.id,'actor_id',r.actor_id,'org_id',r.org_id,
  'request_key',r.request_key,'stage',r.stage,'provider',r.provider,'model',r.model,'input_sha256',r.input_sha256);
 if p_meta->'pipeline_funding'is distinct from token
  or(p_meta?'billing_org_id'and p_meta->>'billing_org_id'is distinct from r.billing_org_id::text)
 then raise exception 'RP403: Immutable pipeline funding receipt mismatch';end if;
 server_meta:=p_meta||jsonb_build_object('pipeline_cost_protocol','pipeline-cost-v1',
  'pipeline_reservation_id',r.id,'request_key',r.request_key,'stage',r.stage,
  'actor_id',r.actor_id,'input_sha256',r.input_sha256,'cost_basis','pipeline_modeled_estimate','invoice_verified',false);
 -- A live parent is used when available; deletion never selects another payer.
 select id into live_org from public.orgs where id=r.org_id;
 select id into live_job from public.render_jobs where id=p_job;
 if live_job is not null and not exists(select 1 from public.render_jobs j join public.listings x on x.id=j.listing_id where j.id=live_job and x.org_id=r.org_id)
 then raise exception 'RP403: Pipeline job belongs to another library';end if;
 cost_key:='pipeline:'||r.id::text;
 select *into l from public.cost_ledger where idempotency_key=cost_key for update;
 if l.id is null then
  insert into public.cost_ledger(job_id,org_id,billing_org_id,feature,provider,model,units,unit_cost_cents,total_cents,meta,idempotency_key)
  values(live_job,live_org,r.billing_org_id,p_feature,r.provider,r.model,p_units,p_unit_cost,p_total,server_meta,cost_key)
  returning *into l;
 end if;
 if l.org_id is distinct from live_org or l.job_id is distinct from live_job
  or l.billing_org_id is distinct from r.billing_org_id or l.provider is distinct from r.provider
  or l.model is distinct from r.model or l.feature is distinct from p_feature
  or l.units is distinct from p_units or l.unit_cost_cents is distinct from p_unit_cost
  or l.total_cents is distinct from p_total or l.meta is distinct from server_meta
 then raise exception 'RP409: Existing pipeline cost receipt has another identity';end if;
 select *into b from public.pipeline_provider_cost_bindings where reservation_id=r.id;
 if b.reservation_id is not null and b.ledger_id is distinct from l.id then raise exception 'RP409: Pipeline attempt already has another cost receipt';end if;
 if exists(select 1 from public.pipeline_provider_cost_bindings where ledger_id=l.id and reservation_id<>r.id)then raise exception 'RP409: Pipeline cost receipt already belongs to another attempt';end if;
 if b.reservation_id is null then insert into public.pipeline_provider_cost_bindings(reservation_id,ledger_id)values(r.id,l.id);end if;
 return jsonb_build_object('recorded',true,'ledger_id',l.id,'billing_org_id',r.billing_org_id,
  'reservation_id',r.id,'idempotency_key',cost_key,'actor_id',r.actor_id,'org_id',r.org_id,
  'request_key',r.request_key,'stage',r.stage,'provider',r.provider,'model',r.model,'input_sha256',r.input_sha256);
end$$;
revoke all on function public.pipeline_record_provider_cost(uuid,uuid,uuid,text,text,text,text,text,uuid,text,numeric,numeric,numeric,jsonb)from public,anon,authenticated;
grant execute on function public.pipeline_record_provider_cost(uuid,uuid,uuid,text,text,text,text,text,uuid,text,numeric,numeric,numeric,jsonb)to service_role,postgres;

create or replace function public.pipeline_cost_covered_cents(p_reservation uuid,p_start timestamptz,p_end timestamptz)
returns numeric language sql stable security definer set search_path='' as $$
 select coalesce((select l.total_cents
 from public.pipeline_provider_cost_bindings b
 join public.serving_cost_reservations r on r.id=b.reservation_id
 join public.cost_ledger l on l.id=b.ledger_id
 where r.id=p_reservation and r.state<>'rejected'
  and l.billing_org_id=r.billing_org_id and l.provider=r.provider and l.model=r.model
  and(l.org_id=r.org_id or(l.org_id is null and not exists(select 1 from public.orgs where id=r.org_id)))
  and l.idempotency_key='pipeline:'||r.id::text
  and l.meta->>'pipeline_cost_protocol'='pipeline-cost-v1'
  and l.meta->>'pipeline_reservation_id'=r.id::text
  and l.meta->>'request_key'=r.request_key and l.meta->>'stage'=r.stage
  and l.meta->>'actor_id'=r.actor_id::text and l.meta->>'input_sha256'=r.input_sha256
  and(p_start is null or l.created_at>=p_start)and(p_end is null or l.created_at<p_end)),0);
$$;
revoke all on function public.pipeline_cost_covered_cents(uuid,timestamptz,timestamptz)from public,anon,authenticated;
grant execute on function public.pipeline_cost_covered_cents(uuid,timestamptz,timestamptz)to service_role,postgres;

-- Keep the legacy unmatched/finally-receipt rules byte-identical. Only the
-- prospective server-validated relation changes this one summand. The ledger
-- sum still contributes modeled cost once; any bound not covered in THIS
-- queried period remains held, even if its ledger is from an older period.
do $patch$declare def text;needle text;replacement text;body text;begin
 select pg_get_functiondef(oid),prosrc into def,body from pg_proc where oid='public.serving_ceiling_spent_cents(uuid,timestamptz,timestamptz)'::regprocedure;
 needle:=$n$select sum(hold_cents) from public.serving_cost_reservations r where r.billing_org_id=public.library_billing_org(p_org) and r.budget_source='ceiling' and r.ledger_id is null$n$;
 replacement:=$n$select sum(case when exists(select 1 from public.pipeline_provider_cost_bindings b where b.reservation_id=r.id)
   then greatest(0,r.hold_cents-public.pipeline_cost_covered_cents(r.id,p_start,p_end))else r.hold_cents end)
  from public.serving_cost_reservations r where r.billing_org_id=public.library_billing_org(p_org) and r.budget_source='ceiling'
   and(r.ledger_id is null or exists(select 1 from public.pipeline_provider_cost_bindings b where b.reservation_id=r.id))$n$;
 if md5(body)='d053fe5bd094d958041a48f0c02dfa4f'then
  if(length(def)-length(replace(def,needle,'')))/length(needle)<>1 then raise exception 'Review changed pipeline ceiling summand';end if;
  execute replace(def,needle,replacement);
 elsif(length(body)-length(replace(body,replacement,'')))/length(replacement)=1
   and md5(replace(body,replacement,needle))='d053fe5bd094d958041a48f0c02dfa4f'then
  null; -- Exact own body only: reversing this single splice restores the pin.
 else raise exception 'Review changed serving ceiling authority';end if;
end$patch$;

-- Outcome evidence is immutable. A receipt already linked to an incurred cost
-- cannot later be relabeled as definitively rejected; uncertain stays uncertain.
do $patch$declare def text;needle text;replacement text;body text;begin
 select pg_get_functiondef(oid),prosrc into def,body from pg_proc where oid='public.serving_cost_finish(uuid,uuid,text,text,text,integer)'::regprocedure;
 needle:=$n$ if r.id is null then raise exception 'RP404: Provider attempt not found';end if;$n$;
 replacement:=needle||E'\n if p_state=\'rejected\'and exists(select 1 from public.pipeline_provider_cost_bindings where reservation_id=r.id)then raise exception\'RP409: An incurred pipeline cost cannot be relabeled rejected\';end if;';
 if md5(body)='8a15681fa25434571b4d7439731a6d3e'then
  if(length(def)-length(replace(def,needle,'')))/length(needle)<>1 then raise exception 'Review changed pipeline finish guard';end if;
  execute replace(def,needle,replacement);
 elsif(length(body)-length(replace(body,replacement,'')))/length(replacement)=1
   and md5(replace(body,replacement,needle))='8a15681fa25434571b4d7439731a6d3e'then
  null; -- Exact own-body replay, never an unknown changed body.
 else raise exception 'Review changed serving finish authority';end if;
end$patch$;
commit;
