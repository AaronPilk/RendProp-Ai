-- Rollback for 20261017190100_app_video_rp402_copy.sql (E8). Restores the
-- original legacy pre-check sentence; body md5 back to
-- 9828980adb313656910f14caee8a8111. Copy only: no amount, comparison, lock
-- order or envelope call changes in either direction. Owner and ACL are kept
-- by create or replace. Already-original is a no-op; any unknown body refuses.
begin;
do $rollback$declare body text;original text;definition text;
 sig text:='public.app_video_cost_reserve(uuid,uuid,text,text,text,text,text,numeric,numeric,numeric,jsonb)';
 anchor text:=$a$    raise exception 'RP402: AI usage limit reached' using detail='legacy_cogs_ceiling_precheck';$a$;
 replacement text:=$r$    raise exception 'RP402: Workspace monthly processing budget would be exceeded';$r$;
begin
 select prosrc into body from pg_proc where oid=sig::regprocedure;
 if md5(body)='9828980adb313656910f14caee8a8111' then return; end if;
 if md5(body)<>'15ff3c0d069dd3155593e2b351b55ccb' then raise exception 'E8 rollback refused: unknown app_video_cost_reserve body %',md5(body); end if;
 if (length(body)-length(replace(body,anchor,'')))/length(anchor)<>1 then raise exception 'E8 rollback anchor is not unique'; end if;
 original:=body; body:=replace(body,anchor,replacement);
 if md5(body)<>'9828980adb313656910f14caee8a8111' then raise exception 'E8 rollback would not restore the original body'; end if;
 definition:=pg_get_functiondef(sig::regprocedure);
 if position(original in definition)=0 then raise exception 'E8 rollback: function definition changed'; end if;
 execute replace(definition,original,body);
 if (select md5(prosrc) from pg_proc where oid=sig::regprocedure)<>'9828980adb313656910f14caee8a8111' then raise exception 'E8 rollback did not restore the original body'; end if;
end$rollback$;
commit;
