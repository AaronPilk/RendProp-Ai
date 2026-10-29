-- Declutter inside the funded subscription trial.
-- iOS runs a Declutter assessment (ai-photo edit "suggest" with the declutter
-- assessment protocol, stage photo.suggest) before the customer chooses what to
-- remove. photo_declutter_assessment_admit already admits that assessment for an
-- active trial (tier 'trial': 5 a day, 10 a month) and the Edge function allows
-- it, but subscription_trial_cost_guard refused every photo.suggest for trial
-- funding, so Declutter could not start during a trial although the paywall
-- offers AI photo edits for decluttering or staging. An assessment with an exact
-- admission row for the same billing workspace, actor and request key is now held
-- against the trial's funded slice like any other attempt, without using one of
-- the included photo edits. Plain suggestions and prompt rewriting stay refused.
-- The rewrite anchors on the exact live body and refuses if it drifted.
create function pg_temp.rp_patch(fn regprocedure,needle text,replacement text,expected_md5 text)returns void
language plpgsql as $$
declare def text;n integer;
begin
 def:=pg_get_functiondef(fn);
 if md5(def) is distinct from expected_md5 then raise exception 'trial declutter assessment: % changed (md5 %); refusing to patch',fn,md5(def);end if;
 n:=(length(def)-length(replace(def,needle,'')))/length(needle);
 if n<>1 then raise exception 'trial declutter assessment: anchor for % found % times; refusing to patch',fn,n;end if;
 execute replace(def,needle,replacement);
end$$;
select pg_temp.rp_patch('public.subscription_trial_cost_guard()'::regprocedure,
 $n$ if new.stage in('photo.suggest','photo.improve_prompt')then$n$,
 $r$ -- An admitted Declutter assessment (photo_declutter_assessment_admit, trial tier) is
 -- analysis, not one of the included photo edits; its hold still counts against the slice.
 if new.stage='photo.suggest' and exists(select 1 from public.photo_declutter_assessment_admissions a
   where a.billing_org_id=public.library_actor_billing_org(new.actor_id,new.org_id)
     and a.actor_id=new.actor_id and a.request_key=new.request_key)then return new;end if;
 if new.stage in('photo.suggest','photo.improve_prompt')then$r$,
 '3a4428df1d69ce6aecf52ce37db30639');
do $$ begin
 if md5(pg_get_functiondef('public.subscription_trial_cost_guard()'::regprocedure)) <> 'a9912ad38bd71b48e132f771beb5bf8e'
 then raise exception 'trial declutter assessment: unexpected result body'; end if;
end $$;
