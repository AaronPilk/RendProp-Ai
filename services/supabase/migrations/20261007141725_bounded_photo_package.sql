begin;

-- Five trial photo credits reserve image-generation admissions, including a
-- priced fallback. Vision/prompt helpers are separately priced paid operations;
-- they cannot spend this trial's sponsor cash before its included images.
-- Existing unlimited QA and genuine pre-config trial funding remain unchanged.
-- No price, allowance, sponsor cash, schedule or activation is written here.
do $patch$
declare body text;definition text;
 anchor text:=$anchor$ if new.stage in('photo.suggest','photo.improve_prompt')then
  if(select count(*)from public.subscription_trial_actions where grant_id=g.id and kind='photo')>=g.photo_cap
   and(select count(*)from public.subscription_trial_actions where grant_id=g.id and kind='walkthrough')>=g.walkthrough_cap
   and(select count(*)from public.subscription_trial_actions where grant_id=g.id and kind='publication')>=g.listing_cap then raise exception 'RP402: The included trial usage is exhausted';end if;
  return new;
 end if;$anchor$;
 replacement text:=$replacement$ if new.stage in('photo.suggest','photo.improve_prompt')then
  raise exception 'RP402: Photo suggestions and prompt rewriting are not included in the bounded subscription trial';
 end if;$replacement$;
begin
 select prosrc into body from pg_proc where oid='public.subscription_trial_cost_guard()'::regprocedure;
 if md5(body)='785f137e1e459f0fc46245bcd92ad214'then return;end if;
 if md5(body)<>'1f890de861451d49d21033a6f9a0ab96'or
  (length(body)-length(replace(body,anchor,'')))/length(anchor)<>1 then
  raise exception 'Trial cost guard differs from the reviewed canonical body; no photo package patch was applied';
 end if;
 definition:=pg_get_functiondef('public.subscription_trial_cost_guard()'::regprocedure);
 execute replace(definition,anchor,replacement);
 if(select md5(prosrc)from pg_proc where oid='public.subscription_trial_cost_guard()'::regprocedure)<>'785f137e1e459f0fc46245bcd92ad214'then
  raise exception 'Trial helper stage fence does not match the reviewed body';
 end if;
end$patch$;

commit;
