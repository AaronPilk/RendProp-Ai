-- RP402 copy consistency (O03 / E8). `app_video_cost_reserve`'s legacy COGS
-- pre-check refused with "Workspace monthly processing budget would be
-- exceeded" while the shared envelope refuses with "AI usage limit reached".
-- Only the raised text changes, so people see one sentence for one situation
-- and `throwRpc` classifies both as quota_exceeded. The legacy distinction
-- survives as a machine-readable DETAIL for logs and harnesses. The ceiling,
-- the comparison, the lock order, the envelope call and every amount are
-- unchanged. Replays no-op on the spliced body; any other body is refused.
begin;
do $patch$declare p record;body text;original text;definition text;i integer;begin
 for p in select *from(values
('public.app_video_cost_reserve(uuid,uuid,text,text,text,text,text,numeric,numeric,numeric,jsonb)','9828980adb313656910f14caee8a8111','15ff3c0d069dd3155593e2b351b55ccb',
 array[$anchor$    raise exception 'RP402: Workspace monthly processing budget would be exceeded';$anchor$],
 array[$replacement$    raise exception 'RP402: AI usage limit reached' using detail='legacy_cogs_ceiling_precheck';$replacement$])
 )v(signature,before_md5,after_md5,anchors,replacements)loop
  select prosrc into body from pg_proc where oid=p.signature::regprocedure;
  if md5(body)not in(p.before_md5,p.after_md5)then raise exception'Review changed RP402 copy dependency: %',p.signature;end if;
  if md5(body)=p.before_md5 then
   original:=body;
   for i in 1..array_length(p.anchors,1)loop
    if(length(body)-length(replace(body,p.anchors[i],'')))/length(p.anchors[i])<>1 then raise exception'Exact RP402 copy anchor changed: %',p.signature;end if;
    body:=replace(body,p.anchors[i],p.replacements[i]);
   end loop;
   if md5(body)<>p.after_md5 then raise exception'Unexpected RP402 copy body: %',p.signature;end if;
   definition:=pg_get_functiondef(p.signature::regprocedure);
   if position(original in definition)=0 then raise exception'RP402 copy function definition changed: %',p.signature;end if;
   execute replace(definition,original,body);
  end if;
 end loop;
end$patch$;
commit;
