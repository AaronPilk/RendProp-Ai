\set ON_ERROR_STOP on
begin;
-- Recreate0052's exact-lookup failure in a rolled-back local transaction.
update ai_routes set note=case when task='photo.declutter' then 'prompt-only declutter' else null end
 where task in ('photo.sky','photo.twilight','photo.lawn','photo.declutter','photo.stage','photo.custom')
   and provider='gemini' and model='gemini-3.1-flash-image' and enabled and note='legacy';
create temporary table fallback_before as select id,to_jsonb(r)-'note' as immutable,to_jsonb(r) as whole,enabled from ai_routes r;
do $$begin
  if (select count(*) from ai_routes where task like 'photo.%' and note like 'legacy — repointed%')<>6 then raise exception 'Expected six disabled0052 rows with extended notes';end if;
  if exists(select 1 from ai_routes where task like 'photo.%' and note='legacy') then raise exception 'Negative-before control failed: exact router lookup unexpectedly finds rows';end if;
end $$;
\ir ../migrations/0056_active_photo_fallback.sql
\ir ../migrations/0056_active_photo_fallback.sql
do $$begin
  if (select count(*) from ai_routes where task in ('photo.sky','photo.twilight','photo.lawn','photo.declutter','photo.stage','photo.custom') and note='legacy' and provider='gemini' and model='gemini-3.1-flash-image' and enabled and unit_cents=6.7)<>6 then raise exception 'Exact active photo fallback lookup not restored';end if;
  if exists(select 1 from ai_routes where task like 'photo.%' and note='legacy' and not enabled) then raise exception 'Disabled photo row marked as fallback';end if;
  if exists(select 1 from fallback_before b full join ai_routes r on r.id=b.id where b.id is null or r.id is null or b.immutable is distinct from(to_jsonb(r)-'note')) then raise exception 'A model, enabled flag, price or other route field changed';end if;
  if exists(select 1 from fallback_before b join ai_routes r on r.id=b.id where not b.enabled and b.whole is distinct from to_jsonb(r)) then raise exception 'A disabled row changed, including its marker';end if;
end $$;
-- An operator-disabled active candidate must stay unselectable on replay.
update ai_routes set enabled=false,note=null where task='photo.sky' and note='legacy';
\ir ../migrations/0056_active_photo_fallback.sql
do $$begin
  if exists(select 1 from ai_routes where task='photo.sky' and note='legacy') then raise exception 'Disabled-only task acquired a fallback';end if;
  if exists(select 1 from ai_routes where provider in('kie','higgsfield') and enabled) then raise exception 'Blocked provider became enabled';end if;
end $$;
select 'PASS active photo fallback: exact lookup0 before/6 after; repeated migration; every non-note field and every disabled row immutable; disabled-only replay remains unavailable';
rollback;
