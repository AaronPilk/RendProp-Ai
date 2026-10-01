-- 0056: recover exact photo fallback lookup using already-enabled routes.
-- 0052 appended prose to disabled fallback markers. Restoring those markers
-- would activate disabled rows through the historical legacy resolver. Instead
-- identify the existing enabled Gemini 3.1 rows, retaining their real 6.7c price.
-- router.ts now requires enabled=true and all photo eligibility checks on this
-- path; providers/chain.ts fails closed if the live authorization is absent.
-- Never change any enabled flag, model, price, or disabled-row marker.
update public.ai_routes
   set note='legacy'
 where task in ('photo.sky','photo.twilight','photo.lawn','photo.declutter','photo.stage','photo.custom')
   and provider='gemini'
   and model='gemini-3.1-flash-image'
   and position in (1,2)
   and enabled=true
   and retire_after is null
   and not exists (
       select 1 from public.ai_routes existing
        where existing.task=ai_routes.task and existing.note='legacy'
          and existing.id<>ai_routes.id
   );
