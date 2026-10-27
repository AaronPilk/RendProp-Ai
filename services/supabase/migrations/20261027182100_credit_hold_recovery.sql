-- Recover aged Declutter/Stage customer credits after a process crash or a
-- failed credit-wallet RPC. Never infer supplier rejection from a timeout:
-- accepted, pending and uncertain provider attempts retain their liability.
begin;

create index if not exists credit_photo_holds_recovery_scan
 on public.credit_holds(created_at,id)
 where state='reserved' and operation in('photo.declutter','photo.stage');
create index if not exists photo_credit_recovery_evidence_lookup
 on public.photo_edit_evidence(actor_id,request_key)
 where edit in('declutter','stage');

create or replace function public.credit_photo_hold_reconcile(p_limit integer default 100)
returns jsonb language plpgsql security definer set search_path='' as $$
declare candidate record; held public.credit_holds; outcome jsonb;
 released integer:=0; settled integer:=0; review_count integer:=0;
 scanned integer:=0; main_stage text;
begin
 if current_setting('role',true) is distinct from 'service_role' then
   raise insufficient_privilege;
 end if;
 if p_limit is null or p_limit not between 1 and 500 then
   raise exception 'RP400: A bounded reconciliation batch is required';
 end if;
 -- A manual invocation and the scheduled run cannot sweep the same batch
 -- simultaneously. Wallet finish itself provides the per-workspace lock and
 -- exact state/idempotency check; do not acquire provider locks here.
 if not pg_try_advisory_xact_lock(hashtextextended('credit-photo-hold-recovery',71004)) then
   return jsonb_build_object('busy',true,'scanned',0,'released',0,'settled',0,'needs_review',0);
 end if;
 -- Select only actionable holds. Otherwise a batch of old uncertain provider
 -- attempts would sit at the front of the index and starve later refunds.
 for candidate in
   select h.id from public.credit_holds h
    where h.state='reserved' and h.operation in('photo.declutter','photo.stage')
      and h.created_at<=now()-interval '1 hour'
      and (exists(
        select 1 from public.serving_cost_reservations r
        where r.credit_hold_id=h.id and r.budget_source='credits'
          and r.state='succeeded' and r.actor_id=h.actor_id
          and r.billing_org_id=h.org_id and r.credit_environment=h.environment
          and r.request_key=h.request_key
          and r.stage~case h.operation when 'photo.declutter'
            then '^photo[.]declutter:[0-9]+$' else '^photo[.]stage:[0-9]+$' end
          and (r.ledger_id is not null or exists(
            select 1 from public.photo_edit_evidence e
            where e.org_id=r.org_id and e.actor_id=r.actor_id
              and e.request_key=r.request_key
              and e.edit=substring(h.operation from 7)
              and e.generation_stage=r.stage and e.generation_provider=r.provider
              and e.generation_model=r.model and e.output_etag is not null))
      ) or (not exists(
        select 1 from public.serving_cost_reservations r
        where r.credit_hold_id=h.id and r.budget_source='credits'
          and r.state<>'rejected'
      ) and not exists(
        select 1 from public.photo_edit_evidence e
        where e.actor_id=h.actor_id and e.request_key=h.request_key
          and e.edit=substring(h.operation from 7)
          and (e.output is not null or e.output_etag is not null)
          and exists(select 1 from public.serving_cost_reservations r
            where r.credit_hold_id=h.id and r.org_id=e.org_id
              and r.actor_id=e.actor_id and r.request_key=e.request_key)
      )))
    order by h.created_at,h.id limit p_limit
 loop
   select * into held from public.credit_holds where id=candidate.id;
   if not found or held.state<>'reserved' or held.created_at>now()-interval '1 hour' then
     continue;
   end if;
   scanned:=scanned+1;
   main_stage:=case held.operation when 'photo.declutter' then '^photo[.]declutter:[0-9]+$'
     else '^photo[.]stage:[0-9]+$' end;
   -- fundedAttempt marks a supplier attempt succeeded on a valid dispatch
   -- receipt, before awaitJob/download. Require proof that a photo actually
   -- came back: its exact cost receipt or immutable saved output receipt.
   if exists(
      select 1 from public.serving_cost_reservations r
      where r.credit_hold_id=held.id and r.budget_source='credits'
        and r.state='succeeded' and r.actor_id=held.actor_id
        and r.billing_org_id=held.org_id and r.credit_environment=held.environment
        and r.request_key=held.request_key and r.stage~main_stage
        and (r.ledger_id is not null or exists(
          select 1 from public.photo_edit_evidence e
          where e.org_id=r.org_id and e.actor_id=r.actor_id
            and e.request_key=r.request_key
            and e.edit=substring(held.operation from 7)
            and e.generation_stage=r.stage and e.generation_provider=r.provider
            and e.generation_model=r.model and e.output_etag is not null))
   ) then
     begin
       outcome:=public.credit_wallet_finish(held.actor_id,held.org_id,
         held.environment,held.request_key,'settled');
     exception when raise_exception then
       -- The live request may have completed while this sweep scanned it.
       if SQLERRM like 'RP409:%' then continue;end if;
       raise;
     end;
     if outcome->>'replay'='false' then settled:=settled+1;end if;
   elsif not exists(
      select 1 from public.serving_cost_reservations r
      where r.credit_hold_id=held.id and r.budget_source='credits'
        and r.state<>'rejected'
   ) and not exists(
      select 1 from public.photo_edit_evidence e
      where e.actor_id=held.actor_id and e.request_key=held.request_key
        and e.edit=substring(held.operation from 7)
        and (e.output is not null or e.output_etag is not null)
        and exists(select 1 from public.serving_cost_reservations r
          where r.credit_hold_id=held.id and r.org_id=e.org_id
            and r.actor_id=e.actor_id and r.request_key=e.request_key)
   ) then
     -- credit_wallet_finish rechecks supplier liabilities under the wallet
     -- lock, so a racing dispatch cannot slip between this scan and release.
     begin
       outcome:=public.credit_wallet_finish(held.actor_id,held.org_id,
         held.environment,held.request_key,'released');
     exception when raise_exception then
       -- A racing supplier reservation makes the release unsafe. Preserve
       -- the hold and reassess it on the next scheduled run.
       if SQLERRM like 'RP409:%' then continue;end if;
       raise;
     end;
     if outcome->>'replay'='false' then released:=released+1;end if;
   end if;
 end loop;
 -- Count liabilities requiring human/provider reconciliation independently
 -- of p_limit; deferred safe refunds are not mislabeled as uncertain.
 select count(*) into review_count from public.credit_holds h
 where h.state='reserved' and h.operation in('photo.declutter','photo.stage')
   and h.created_at<=now()-interval '1 hour'
   and (exists(select 1 from public.serving_cost_reservations r
      where r.credit_hold_id=h.id and r.budget_source='credits'
        and r.state<>'rejected')
     or exists(select 1 from public.photo_edit_evidence e
      where e.actor_id=h.actor_id and e.request_key=h.request_key
        and e.edit=substring(h.operation from 7)
        and (e.output is not null or e.output_etag is not null)
        and exists(select 1 from public.serving_cost_reservations r
          where r.credit_hold_id=h.id and r.org_id=e.org_id
            and r.actor_id=e.actor_id and r.request_key=e.request_key)))
   and not exists(select 1 from public.serving_cost_reservations r
      where r.credit_hold_id=h.id and r.budget_source='credits'
        and r.state='succeeded' and r.actor_id=h.actor_id
        and r.billing_org_id=h.org_id and r.credit_environment=h.environment
        and r.request_key=h.request_key
        and r.stage~case h.operation when 'photo.declutter'
          then '^photo[.]declutter:[0-9]+$' else '^photo[.]stage:[0-9]+$' end
        and (r.ledger_id is not null or exists(
          select 1 from public.photo_edit_evidence e
          where e.org_id=r.org_id and e.actor_id=r.actor_id
            and e.request_key=r.request_key
            and e.edit=substring(h.operation from 7)
            and e.generation_stage=r.stage and e.generation_provider=r.provider
            and e.generation_model=r.model and e.output_etag is not null)));
 return jsonb_build_object('busy',false,'scanned',scanned,'released',released,
   'settled',settled,'needs_review',review_count);
end$$;

revoke all on function public.credit_photo_hold_reconcile(integer)
 from public,anon,authenticated;
grant execute on function public.credit_photo_hold_reconcile(integer) to service_role;

-- The existing hourly admin alert channel also checks unresolved customer
-- holds. It reports ambiguous liability; it never changes a supplier result.
do $patch$
declare definition text; body text; anchor text; replacement text;
begin
 select pg_get_functiondef(oid),prosrc into definition,body
   from pg_proc where oid='public.ops_health_findings()'::regprocedure;
 anchor:=E' return;\nend';
 replacement:=E' select count(*) into n from public.credit_holds h\n'
  ||E'  where h.state=''reserved'' and h.operation in(''photo.declutter'',''photo.stage'')\n'
  ||E'    and h.created_at<=now()-interval ''1 hour'';\n'
  ||E' if n>0 then\n'
  ||E'  code:=''credit_photo_holds_need_review'';title:=n||'' photo credit hold(s) older than 1 hour'';\n'
  ||E'  body:=''Run credit_photo_hold_reconcile if its job stopped. Check provider receipts for any remaining pending or uncertain attempts; never release an ambiguous supplier hold without evidence.'';\n'
  ||E'  data:=jsonb_build_object(''reserved_holds'',n);return next;\n'
  ||E' end if;\n return;\nend';
 if position('credit_photo_holds_need_review' in body)=0 then
   if (length(body)-length(replace(body,anchor,'')))/length(anchor)<>1 then
     raise exception 'Ops health function changed; review credit recovery alert';
   end if;
   execute replace(definition,anchor,replacement);
 end if;
end$patch$;

do $schedule$
declare v_id bigint;
begin
 if not exists(select 1 from pg_extension where extname='pg_cron') then
   raise notice 'credit_hold_recovery: pg_cron unavailable; schedule public.credit_photo_hold_reconcile() externally every 15 minutes.';
   return;
 end if;
 select jobid into v_id from cron.job where jobname='credit-photo-hold-reconcile';
 if v_id is not null then perform cron.unschedule(v_id);end if;
 perform cron.schedule('credit-photo-hold-reconcile','*/15 * * * *',
   'set role service_role;select public.credit_photo_hold_reconcile();');
exception when others then
 raise notice 'credit_hold_recovery: scheduling failed (% — %); public.credit_photo_hold_reconcile() remains callable.',SQLSTATE,SQLERRM;
end$schedule$;
commit;
