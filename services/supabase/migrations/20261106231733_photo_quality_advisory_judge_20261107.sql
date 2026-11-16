-- photo_quality_finish: the judge becomes advisory (owner decision, 6 Nov 2026).
--
-- Before: an edit was delivered only when the verdict was pass/accept with
-- confidence >= .85, artifacts >= 90, edit_quality >= 80, every preservation
-- axis >= 95 and ZERO findings; anything else was held as private and the
-- realtor saw a failure. Two weeks of production: 4 of 7 judged edits held,
-- including a declutter whose only finding was a window that became visible
-- once boxes were removed, and every twilight edit.
--
-- After: a verdict that the edge parser accepted (action = 'accept', which
-- 20261107 ai-photo/photo-qc-verdict.ts now sets for every well-formed judge
-- answer) delivers the edit, provided the cost reservation and the QC ledger
-- receipt exist exactly as before. The verdict, scores and findings are still
-- recorded on the disclosure record (record_media_qc) unchanged, so the
-- realtor sees what the judge saw and decides; feedback trains the system.
-- Malformed or non-final judge answers still arrive with action 'hold' and
-- stay held. Saved verdicts remain immutable. Backward compatible with the
-- currently deployed edge code (which only ever sent 'accept' for verdicts
-- that also met every threshold here).
begin;
set local lock_timeout = '5s';
set local statement_timeout = '60s';

do $repair$
declare d text; from_needle text; to_needle text; replacement text; before_meta jsonb; target regprocedure; p_from int; p_to int;
begin
 target := 'public.photo_quality_finish(uuid,uuid,uuid,jsonb)'::regprocedure;
 if (select md5(prosrc) from pg_proc where oid = target) is distinct from '161b233d66b210e6dfffa4d5b8188adc' then
  raise exception 'photo_quality_finish changed since 2026-11-06; review the advisory-judge rewrite before applying';
 end if;
 select to_jsonb(p) - 'prosrc' - 'prosqlbody', pg_get_functiondef(p.oid) into before_meta, d from pg_proc p where p.oid = target;
 from_needle := $n$ accept:=p_result->>'action'='accept'and p_result->>'verdict'='pass'and r.id is not null and l.id is not null$n$;
 to_needle := $n$ accept:=coalesce(accept,false);$n$;
 if length(d) - length(replace(d, from_needle, '')) <> length(from_needle) then raise exception 'acceptance predicate seam not found exactly once'; end if;
 if length(d) - length(replace(d, to_needle, '')) <> length(to_needle) then raise exception 'acceptance coalesce seam not found exactly once'; end if;
 p_from := position(from_needle in d);
 p_to := position(to_needle in d) + length(to_needle);
 if p_to <= p_from then raise exception 'acceptance seams are out of order'; end if;
 replacement := $r$ accept:=coalesce(p_result->>'action','')='accept'and r.id is not null and l.id is not null and jsonb_typeof(p_result->'preservation')='object'and jsonb_typeof(p_result->'findings')='array';$r$;
 execute substr(d, 1, p_from - 1) || replacement || substr(d, p_to);
 if (select to_jsonb(p) - 'prosrc' - 'prosqlbody' from pg_proc p where p.oid = target) is distinct from before_meta then
  raise exception 'photo_quality_finish metadata changed';
 end if;
 if (select prosrc from pg_proc where oid = target) not like '%' || replacement || '%' then raise exception 'rewrite did not land'; end if;
 if (select prosrc from pg_proc where oid = target) like '%findings''=''[]''::jsonb%' then raise exception 'old zero-findings gate still present'; end if;
end
$repair$;
commit;
