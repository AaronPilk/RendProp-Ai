begin;
do $$
declare h jsonb; target regprocedure; source text;
begin
 h:=public.maintenance_http_headers('sb_secret_synthetic_transport_test');
 if h->>'apikey'<>'sb_secret_synthetic_transport_test' or h ? 'Authorization' or h->>'Content-Type'<>'application/json' then
  raise exception 'FAIL: modern key is apikey only';end if;
 h:=public.maintenance_http_headers('synthetic-legacy-transport');
 if h->>'apikey'<>'synthetic-legacy-transport' or h->>'Authorization'<>'Bearer synthetic-legacy-transport' then
  raise exception 'FAIL: legacy transport preserved during coordinated rotation';end if;
 if has_function_privilege('anon','public.maintenance_http_headers(text)','EXECUTE') or
    has_function_privilege('authenticated','public.maintenance_http_headers(text)','EXECUTE') or
    not has_function_privilege('service_role','public.maintenance_http_headers(text)','EXECUTE') then
  raise exception 'FAIL: clients cannot use maintenance credential transport';end if;
 begin perform public.maintenance_http_headers(null);raise exception 'FAIL: missing maintenance credential admitted';
 exception when others then if SQLERRM not like 'RP503:%' then raise;end if;end;
 foreach target in array array['public.notification_drain(integer)'::regprocedure,
   'public.account_deletion_drain()'::regprocedure,'public.media_privacy_drain(text)'::regprocedure] loop
  source:=pg_get_functiondef(target);
  if position('public.maintenance_http_headers(' in source)=0 or
     source ~ 'jsonb_build_object\([[:space:]]*''Authorization''' or
     position('25000' in source)=0 or position('notify_service_key' in source)=0 then
   raise exception 'FAIL: exact maintenance consumer not migrated: %',target;end if;
 end loop;
end$$;
select 'modern service transport: 7 checks passed';
rollback;
