-- SOURCE ONLY. Prospective server accounting: no enrollment/backfill of old jobs.
begin;
set local lock_timeout='5s';
lock table public.property_video_jobs in share row exclusive mode;
do $pin$declare sig text;h text;begin
 for sig,h in select * from(values
 ('public.property_video_job_admit_photo_motion(uuid,jsonb)','35b94c98d84adec35ca2caab48a23a7b'),
 ('public.property_video_job_finish_photo_motion(uuid,uuid,jsonb)','25065e0fa94010703b637d9b4796b786'),
 ('public.property_video_photo_motion_observe(uuid,uuid,text,text,text,bigint,jsonb)','495f1866eea2b0fce75b885c97b35caf'),
 ('public.cost_ledger_settle_serving_hold()','b02d5dc9f5a6196e9c658ab236c90475'),
 ('public.serving_ceiling_spent_cents(uuid,timestamptz,timestamptz)','158bb63c2b597e4eb20495b634cf2e53'),
 ('public.pipeline_record_provider_cost(uuid,uuid,uuid,text,text,text,text,text,uuid,text,numeric,numeric,numeric,jsonb)','5500cfe7e17058770a1eeeb006196cdd'),
 ('public.pipeline_cost_covered_cents(uuid,timestamptz,timestamptz)','80187fb4191277dccc4a09eade462407'),
 ('public.serving_cost_finish(uuid,uuid,text,text,text,integer)','46474c45de38f761d755ecea0fa1083f'))v(sig,h)loop
  if(select md5(prosrc)from pg_proc where oid=to_regprocedure(sig))is distinct from h then raise exception 'Review changed Photo Motion cost predecessor: %',sig;end if;
 end loop;
end$pin$;
create table public.property_video_pm_cost_eligibility(
 job_id uuid primary key,operation_id uuid not null,actor_id uuid not null,org_id uuid not null,library_org_id uuid not null,billing_org_id uuid not null,
 manifest_sha256 text not null check(manifest_sha256~'^[a-f0-9]{64}$'),quality_identity jsonb not null,
 reservation_id uuid not null unique references public.serving_cost_reservations(id),hold_cents numeric not null check(hold_cents>0),
 protocol text not null default 'photo-motion-server-cost-v1' check(protocol='photo-motion-server-cost-v1'),
 unit_cost_cents numeric not null default .006112 check(unit_cost_cents=.006112),created_at timestamptz not null default now());
create table public.property_video_pm_server_costs(
 job_id uuid not null references public.property_video_pm_cost_eligibility(job_id),lease_token uuid not null,phase text not null check(phase in('compose','inspect_audio')),
 reservation_id uuid not null references public.serving_cost_reservations(id),manifest_sha256 text not null,outcome text not null check(outcome in('completed','failed')),
 producer_identity jsonb,processing_wall_ms bigint check(processing_wall_ms is null or(processing_wall_ms between 0 and 1260000 and processing_wall_ms%10=0)),
 modeled_cents numeric,ledger_id uuid unique references public.cost_ledger(id),
 cost_basis text not null default 'modeled_cpu_wall_time' check(cost_basis='modeled_cpu_wall_time'),invoice_verified boolean not null default false check(not invoice_verified),
 accounting_state text not null check(accounting_state in('pending','recorded','unconfirmed','error')),last_error_sqlstate text check(last_error_sqlstate is null or last_error_sqlstate~'^[A-Z0-9]{5}$'),
 created_at timestamptz not null default now(),updated_at timestamptz not null default now(),primary key(job_id,phase,lease_token),
 check((processing_wall_ms is null and modeled_cents is null)or(processing_wall_ms is not null and modeled_cents=ceil(processing_wall_ms::numeric/1000*.006112*10000)/10000)));
alter table public.property_video_pm_cost_eligibility enable row level security;
alter table public.property_video_pm_server_costs enable row level security;
revoke all on public.property_video_pm_cost_eligibility,public.property_video_pm_server_costs from public,anon,authenticated,service_role;
grant select on public.property_video_pm_cost_eligibility,public.property_video_pm_server_costs to service_role;
create function public.property_video_pm_cost_admission()returns trigger language plpgsql security definer set search_path=''as $$
declare r public.serving_cost_reservations;begin
 if new.manifest->>'source_mode'is distinct from'photo_motion_v1'theN return new;end if;
 -- This insertion is the explicit prospective opt-in. Existing jobs cannot
 -- enroll through a read/replay/observation, even when they finish later.
 if current_setting('role',true)is distinct from'service_role'or current_setting('rendprop.photo_motion_admission',true)is distinct from new.manifest_sha256 then raise exception'RP409: Exact new Photo Motion admission is required for accounting';end if;
 select*into r from public.serving_cost_reservations where actor_id=new.actor_id and org_id=new.org_id and request_key='photomotion:'||new.operation_id and stage='photo_motion'for update;
 if r.id is null or r.state<>'reserved'or r.ledger_id is not null or r.input_sha256 is distinct from new.manifest_sha256 or r.provider<>'cloudflare'or r.model<>'container-standard-3'or r.billing_org_id is null
 or exists(select 1 from public.pipeline_provider_cost_bindings where reservation_id=r.id)then raise exception'RP409: Exact prospective Photo Motion liability is required';end if;
 insert into public.property_video_pm_cost_eligibility(job_id,operation_id,actor_id,org_id,library_org_id,billing_org_id,manifest_sha256,quality_identity,reservation_id,hold_cents)
 values(new.id,new.operation_id,new.actor_id,new.org_id,new.library_org_id,r.billing_org_id,new.manifest_sha256,new.quality_identity,r.id,r.hold_cents);return new;
end$$;
create trigger property_video_pm_cost_admission after insert on public.property_video_jobs for each row execute function public.property_video_pm_cost_admission();
create function public.property_video_pm_cost_hold_guard()returns trigger language plpgsql security definer set search_path=''as $$
declare e public.property_video_pm_cost_eligibility;begin
 select*into e from public.property_video_pm_cost_eligibility where reservation_id=old.id;if e.job_id is null then return new;end if;
 if row(new.id,new.actor_id,new.org_id,new.billing_org_id,new.request_key,new.stage,new.provider,new.model,new.input_sha256,new.hold_cents)
 is distinct from row(old.id,e.actor_id,e.org_id,e.billing_org_id,'photomotion:'||e.operation_id,'photo_motion','cloudflare','container-standard-3',e.manifest_sha256,e.hold_cents)
 or new.ledger_id is not null then raise exception'RP409: Prospective Photo Motion liability uses exact partial cost coverage';end if;
 if new.state='rejected'and exists(select 1 from public.property_video_photo_motion_observations where job_id=e.job_id)then raise exception'RP409: Observed Photo Motion liability cannot be rejected';end if;return new;
end$$;
create trigger property_video_pm_cost_hold_guard before update on public.serving_cost_reservations for each row execute function public.property_video_pm_cost_hold_guard();
create function public.property_video_pm_record_server_cost(p_job uuid,p_lease uuid,p_phase text)returns jsonb language plpgsql security definer set search_path=''as $$
declare e public.property_video_pm_cost_eligibility;j public.property_video_jobs;o public.property_video_photo_motion_observations;r public.serving_cost_reservations;c public.property_video_pm_server_costs;l public.cost_ledger;
 total numeric;meta_ jsonb;key_ text;error_ text;begin
 if current_setting('role',true)is distinct from'service_role'then raise insufficient_privilege;end if;
 select*into e from public.property_video_pm_cost_eligibility where job_id=p_job;
 if e.job_id is null then return jsonb_build_object('eligible',false,'recorded',false);end if;
 perform pg_advisory_xact_lock(hashtextextended('serving:'||e.billing_org_id,72452));
 perform pg_advisory_xact_lock(hashtextextended('serving:'||e.org_id,72452));
 select*into j from public.property_video_jobs where id=p_job for update;
 select*into r from public.serving_cost_reservations where id=e.reservation_id for update;
 select*into o from public.property_video_photo_motion_observations where job_id=p_job and lease_token=p_lease and phase=p_phase;
 if j.id is null or row(j.actor_id,j.org_id,j.library_org_id,j.operation_id,j.manifest_sha256,j.quality_identity)is distinct from row(e.actor_id,e.org_id,e.library_org_id,e.operation_id,e.manifest_sha256,e.quality_identity)
 or r.id is null or row(r.actor_id,r.org_id,r.billing_org_id,r.request_key,r.stage,r.provider,r.model,r.input_sha256,r.hold_cents)is distinct from row(e.actor_id,e.org_id,e.billing_org_id,'photomotion:'||e.operation_id,'photo_motion','cloudflare','container-standard-3',e.manifest_sha256,e.hold_cents)
 or r.state='rejected'or r.ledger_id is not null or exists(select 1 from public.pipeline_provider_cost_bindings where reservation_id=r.id)
 or o.job_id is null or o.manifest_sha256 is distinct from e.manifest_sha256
 or(o.producer_identity is distinct from e.quality_identity->'producer_identity'and not(o.outcome='failed'and o.producer_identity is null and o.processing_wall_ms is null))
 then raise exception'RP409: Exact admitted Photo Motion observation and liability are required';end if;
 total:=case when o.processing_wall_ms is null then null else ceil(o.processing_wall_ms::numeric/1000*e.unit_cost_cents*10000)/10000 end;
 select*into c from public.property_video_pm_server_costs where job_id=p_job and phase=p_phase and lease_token=p_lease for update;
 if c.job_id is not null and row(c.reservation_id,c.manifest_sha256,c.outcome,c.producer_identity,c.processing_wall_ms,c.modeled_cents)is distinct from row(r.id,e.manifest_sha256,o.outcome,o.producer_identity,o.processing_wall_ms,total)then raise exception'RP409: Saved Photo Motion cost observation is immutable';end if;
 if c.job_id is null then insert into public.property_video_pm_server_costs(job_id,phase,lease_token,reservation_id,manifest_sha256,outcome,producer_identity,processing_wall_ms,modeled_cents,accounting_state)
 values(p_job,p_phase,p_lease,r.id,e.manifest_sha256,o.outcome,o.producer_identity,o.processing_wall_ms,total,case when total is null then'unconfirmed'else'pending'end)returning*into c;end if;
 if total is null then return jsonb_build_object('eligible',true,'recorded',true,'confirmed',false,'modeled_cents',null);end if;
 key_:='photo-motion-cost-v1:'||p_job||':'||p_phase||':'||p_lease;
 meta_:=jsonb_build_object('photo_motion_cost_protocol',e.protocol,'property_video_job_id',p_job,'operation_id',e.operation_id,'manifest_sha256',e.manifest_sha256,'lease_token',p_lease,'phase',p_phase,'outcome',o.outcome,'producer_identity',o.producer_identity,'processing_wall_ms',o.processing_wall_ms,'reservation_id',r.id,'request_key',r.request_key,'stage',r.stage,'actor_id',r.actor_id,'input_sha256',r.input_sha256,'cost_basis','modeled_cpu_wall_time','invoice_verified',false);
 -- Ledger failure is isolated in its own subtransaction. The durable error
 -- marker and full reservation remain; an output can still become READY.
 begin
  select*into l from public.cost_ledger where idempotency_key=key_ for update;
  if l.id is null then insert into public.cost_ledger(job_id,org_id,billing_org_id,feature,provider,model,units,unit_cost_cents,total_cents,meta,idempotency_key)
   values(null,e.org_id,e.billing_org_id,'photo_motion','cloudflare','container-standard-3',o.processing_wall_ms::numeric/1000,e.unit_cost_cents,total,meta_,key_)returning*into l;end if;
  if l.id is null or row(l.job_id,l.org_id,l.billing_org_id,l.feature,l.provider,l.model,l.units,l.unit_cost_cents,l.total_cents,l.meta)
   is distinct from row(null::uuid,e.org_id,e.billing_org_id,'photo_motion','cloudflare','container-standard-3',o.processing_wall_ms::numeric/1000,e.unit_cost_cents,total,meta_)or(c.ledger_id is not null and c.ledger_id is distinct from l.id)
   then raise exception'RP409: Existing Photo Motion cost has another exact identity';end if;
  update public.property_video_pm_server_costs set ledger_id=l.id,accounting_state='recorded',last_error_sqlstate=null,updated_at=now()where job_id=p_job and phase=p_phase and lease_token=p_lease;
  return jsonb_build_object('eligible',true,'recorded',true,'confirmed',true,'ledger_id',l.id,'modeled_cents',total,'invoice_verified',false);
 exception when others then get stacked diagnostics error_=returned_sqlstate;
  update public.property_video_pm_server_costs set accounting_state='error',last_error_sqlstate=error_,updated_at=now()where job_id=p_job and phase=p_phase and lease_token=p_lease;
  return jsonb_build_object('eligible',true,'recorded',false,'accounting_error',true);
 end;
end$$;
create function public.property_video_pm_try_server_cost(p_job uuid,p_lease uuid,p_phase text)returns void language plpgsql security definer set search_path=''as $$begin
 perform public.property_video_pm_record_server_cost(p_job,p_lease,p_phase);exception when others then return;end$$;
alter function public.property_video_photo_motion_observe(uuid,uuid,text,text,text,bigint,jsonb)rename to property_video_pm_observe_before_cost_v1;
create function public.property_video_photo_motion_observe(p_job uuid,p_lease uuid,p_manifest text,p_phase text,p_outcome text,p_wall_ms bigint,p_producer jsonb)returns jsonb language plpgsql security definer set search_path=''as $$declare answer jsonb;begin
 answer:=public.property_video_pm_observe_before_cost_v1(p_job,p_lease,p_manifest,p_phase,p_outcome,p_wall_ms,p_producer);
 perform public.property_video_pm_try_server_cost(p_job,p_lease,p_phase);return answer;end$$;
alter function public.property_video_job_finish_photo_motion(uuid,uuid,jsonb)rename to property_video_pm_finish_before_cost_v1;
create function public.property_video_job_finish_photo_motion(p_job uuid,p_lease uuid,p_facts jsonb)returns public.property_video_jobs language plpgsql security definer set search_path=''as $$declare j public.property_video_jobs;o public.property_video_photo_motion_observations;begin
 j:=public.property_video_pm_finish_before_cost_v1(p_job,p_lease,p_facts);
 for o in select*from public.property_video_photo_motion_observations where job_id=p_job loop perform public.property_video_pm_try_server_cost(p_job,o.lease_token,o.phase);end loop;return j;end$$;
create function public.property_video_pm_cost_covered_cents(p_reservation uuid,p_start timestamptz,p_end timestamptz)returns numeric language sql stable security definer set search_path=''as $$
 select coalesce(sum(l.total_cents),0)from public.property_video_pm_server_costs c
 join public.property_video_pm_cost_eligibility e on e.job_id=c.job_id and e.reservation_id=c.reservation_id
 join public.serving_cost_reservations r on r.id=e.reservation_id
 join public.cost_ledger l on l.id=c.ledger_id
 where r.id=p_reservation and r.state<>'rejected'and c.accounting_state='recorded'and l.job_id is null
 and l.billing_org_id=e.billing_org_id and l.org_id=e.org_id and l.provider='cloudflare'and l.model='container-standard-3'and l.feature='photo_motion'
 and l.total_cents=c.modeled_cents and l.units=c.processing_wall_ms::numeric/1000 and l.unit_cost_cents=e.unit_cost_cents
 and l.idempotency_key='photo-motion-cost-v1:'||c.job_id||':'||c.phase||':'||c.lease_token
 and l.meta->>'photo_motion_cost_protocol'=e.protocol and l.meta->>'reservation_id'=r.id::text and l.meta->>'manifest_sha256'=e.manifest_sha256
 and l.meta->>'cost_basis'='modeled_cpu_wall_time'and l.meta->'invoice_verified'='false'::jsonb
 and(p_start is null or l.created_at>=p_start)and(p_end is null or l.created_at<p_end)
$$;
-- Four replacements below are generated from exact retained current bodies.
CREATE OR REPLACE FUNCTION public.cost_ledger_settle_serving_hold()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare holds uuid[];key text;v_stage text;
begin
 if new.meta?'photo_motion_cost_protocol'then
  if new.meta->>'photo_motion_cost_protocol'is distinct from'photo-motion-server-cost-v1'or new.job_id is not null
   or not exists(select 1 from public.property_video_pm_server_costs c join public.property_video_pm_cost_eligibility e on e.job_id=c.job_id
    where c.job_id::text=new.meta->>'property_video_job_id'and c.lease_token::text=new.meta->>'lease_token'and c.phase=new.meta->>'phase'
     and c.reservation_id=e.reservation_id and e.reservation_id::text=new.meta->>'reservation_id'and e.manifest_sha256=new.meta->>'manifest_sha256'
     and c.processing_wall_ms::text=new.meta->>'processing_wall_ms'and c.producer_identity=new.meta->'producer_identity'
     and new.org_id=e.org_id and new.billing_org_id=e.billing_org_id and new.feature='photo_motion'and new.provider='cloudflare'and new.model='container-standard-3'
     and new.units=c.processing_wall_ms::numeric/1000 and new.unit_cost_cents=e.unit_cost_cents and new.total_cents=c.modeled_cents
     and new.idempotency_key='photo-motion-cost-v1:'||c.job_id||':'||c.phase||':'||c.lease_token
     and new.meta->>'cost_basis'='modeled_cpu_wall_time'and new.meta->'invoice_verified'='false'::jsonb)
   then raise exception'RP409: Exact Photo Motion server-cost binding is required';end if;
  -- Partial modeled CPU receipts never settle the entire processing envelope.
  return new;
 end if;
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
end$function$
;
CREATE OR REPLACE FUNCTION public.serving_ceiling_spent_cents(p_org uuid, p_start timestamp with time zone, p_end timestamp with time zone)
 RETURNS numeric
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
 select coalesce((select sum(total_cents) from public.cost_ledger c where c.billing_org_id=public.library_billing_org(p_org) and(p_start is null or c.created_at>=p_start)and(p_end is null or c.created_at<p_end)),0)
  +coalesce((select sum(case when exists(select 1 from public.pipeline_provider_cost_bindings b where b.reservation_id=r.id)or exists(select 1 from public.property_video_pm_cost_eligibility e where e.reservation_id=r.id)
   then greatest(0,r.hold_cents-public.pipeline_cost_covered_cents(r.id,p_start,p_end)-public.property_video_pm_cost_covered_cents(r.id,p_start,p_end))else r.hold_cents end)
  from public.serving_cost_reservations r where r.billing_org_id=public.library_billing_org(p_org) and r.budget_source='ceiling'
   and(r.ledger_id is null or exists(select 1 from public.pipeline_provider_cost_bindings b where b.reservation_id=r.id)or exists(select 1 from public.property_video_pm_cost_eligibility e where e.reservation_id=r.id))
     and r.state in('reserved','uncertain','succeeded')),0)
  +coalesce((select sum(v.hold_cents) from public.app_video_cost_reservations v where v.billing_org_id=public.library_billing_org(p_org) and v.cost_ledger_id is null and v.released_at is null

     and not exists(select 1 from public.serving_cost_reservations r where r.org_id=v.org_id and r.request_key=v.idempotency_key and r.budget_source='ceiling' and r.ledger_id is null and r.state<>'rejected')),0)
  +coalesce((select sum(j.cost_cents) from public.video_erase_jobs j where j.billing_org_id=public.library_billing_org(p_org) and j.provider='fal' and j.cost_ledger_id is null and j.cost_hold_released_at is null

     and not exists(select 1 from public.serving_cost_reservations r where r.org_id=j.org_id and r.request_key=j.idempotency_key::text and r.budget_source='ceiling' and r.ledger_id is null and r.state<>'rejected')),0)
  +coalesce((select sum(st.cost_cents) from public.video_erase_stages st join public.video_erase_jobs j on j.id=st.job_id where j.billing_org_id=public.library_billing_org(p_org) and st.cost_ledger_id is null and st.cost_hold_released_at is null
     ),0);
$function$
;
do $acl$declare f regprocedure;begin for f in select p.oid::regprocedure from pg_proc p where p.pronamespace='public'::regnamespace and(p.proname in('property_video_pm_cost_admission','property_video_pm_cost_hold_guard','property_video_pm_record_server_cost','property_video_pm_try_server_cost','property_video_pm_cost_covered_cents','property_video_pm_observe_before_cost_v1','property_video_pm_finish_before_cost_v1','property_video_job_finish_photo_motion','property_video_photo_motion_observe'))loop execute 'revoke all on function '||f||' from public,anon,authenticated,service_role';end loop;end$acl$;
grant execute on function public.property_video_pm_record_server_cost(uuid,uuid,text),public.property_video_job_finish_photo_motion(uuid,uuid,jsonb),public.property_video_photo_motion_observe(uuid,uuid,text,text,text,bigint,jsonb)to service_role;
commit;
