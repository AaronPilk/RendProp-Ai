-- Keep incurred ordinary-video costs visible after a workspace is closed.
-- The credit-period preflight only applies to a live paid workspace; the
-- existing cost journal remains an accounting tombstone through deletion.
begin;
do $patch$ declare definition text; anchor text; replacement text; begin
  definition:=pg_get_functiondef('public.org_month_spend_cents(uuid)'::regprocedure);
  if position('if not exists(select 1 from public.orgs where id=b and deleted_at is null)then' in definition)>0 then
    return;
  end if;
  anchor:='b:=public.library_billing_org(p_org);';
  if (length(definition)-length(replace(definition,anchor,'')))/length(anchor)<>1 then
    raise exception 'Review changed deleted-workspace spend lookup';
  end if;
  replacement:=anchor||E'\n if not exists(select 1 from public.orgs where id=b and deleted_at is null)then\n  return public.serving_ceiling_spent_cents(b,date_trunc(''month'',now()),date_trunc(''month'',now())+interval ''1 month'');\n end if;';
  execute replace(definition,anchor,replacement);
end $patch$;
commit;
