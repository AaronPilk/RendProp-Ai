begin;
-- Rotation changes a credential's transport, never the scheduler's authority.
-- Existing Vault names and scheduler states remain untouched. A new secret key
-- cannot be put in a Bearer JWT header: the gateway must receive it as apikey.
create or replace function public.maintenance_http_headers(p_key text)
returns jsonb language plpgsql immutable set search_path='' as $$
begin
 if p_key is null or length(p_key)<10 or length(p_key)>2048 then
  raise exception 'RP503: maintenance credential is not configured';
 end if;
 if left(p_key,10)='sb_secret_' then
  return jsonb_build_object('apikey',p_key,'Content-Type','application/json');
 end if;
 return jsonb_build_object('apikey',p_key,'Authorization','Bearer '||p_key,'Content-Type','application/json');
end$$;
revoke all on function public.maintenance_http_headers(text) from public,anon,authenticated;
grant execute on function public.maintenance_http_headers(text) to service_role;

-- These exact existing functions are otherwise preserved, including lease,
-- due-work, retention, endpoint and timeout checks. Fail closed on source drift
-- instead of replacing an unrelated function or silently leaving a consumer.
do $$
declare target regprocedure; source text; changed text;
begin
 foreach target in array array[
  'public.notification_drain(integer)'::regprocedure,
  'public.account_deletion_drain()'::regprocedure,
  'public.media_privacy_drain(text)'::regprocedure
 ] loop
  source:=pg_get_functiondef(target);
  if position('public.maintenance_http_headers(' in source)>0 then continue;end if;
  changed:=regexp_replace(source,
   'jsonb_build_object\([[:space:]]*''Authorization''[[:space:]]*,[[:space:]]*''Bearer ''[[:space:]]*\|\|[[:space:]]*(v_key|service_key)[[:space:]]*,[[:space:]]*''Content-Type''[[:space:]]*,[[:space:]]*''application/json''[[:space:]]*\)',
   'public.maintenance_http_headers(\1)','g');
  if changed=source or position('public.maintenance_http_headers(' in changed)=0 then
   raise exception 'RP409: maintenance transport source drift for %',target;
  end if;
  execute changed;
 end loop;
end$$;
commit;
