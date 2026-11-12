-- Account deletion deliberately removes a solo workspace's cost ledger while
-- retaining provider liabilities. A retained hold is not an operational
-- ledger failure once its workspace is gone. Do not rewrite or refund it.
-- Preserve every other finding, the admin recipients and existing dedupe keys.
do $$
declare
 definition text := pg_get_functiondef('public.ops_health_findings()'::regprocedure);
 needle text := $old$select count(*) into n from public.serving_cost_reservations where budget_source='ceiling' and state='succeeded' and ledger_id is null and settled_at<now()-interval '1 hour';$old$;
 replacement text := $new$select count(*) into n from public.serving_cost_reservations hold_row join public.orgs live_org on live_org.id=hold_row.org_id and live_org.deleted_at is null where hold_row.budget_source='ceiling' and hold_row.state='succeeded' and hold_row.ledger_id is null and hold_row.settled_at<now()-interval '1 hour';$new$;
begin
 -- Replay-safe without silently accepting a different function body.
 if position(replacement in definition)>0 then return;end if;
 if (length(definition)-length(replace(definition,needle,'')))/length(needle)<>1 then
  raise exception 'live-workspace alert migration: expected exactly one missing-ledger criterion';
 end if;
 execute replace(definition,needle,replacement);
end$$;
