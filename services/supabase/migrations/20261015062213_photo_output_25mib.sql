-- Actual4K Gemini DeveloperAPI output has no JPEG/compression control. Preserve
-- the exact lossless supplier master up to the already-existing25MiB inline
-- media ceiling. Prepared inputs remain9MB; historical calibration remains9MB;
-- geometry, scope, immutable receipts, paid/QC promotion and ACLs are unchanged.
do $$declare definition text;before_clause text:='(p_output->>''bytes'')::bigint>9000000';after_clause text:='(p_output->>''bytes'')::bigint>(case when e.purpose=''calibration''then 9000000 else 26214400 end)';begin
 definition:=pg_get_functiondef('public.photo_quality_evidence_reserve(uuid,uuid,jsonb)'::regprocedure);
 if(select md5(prosrc)from pg_proc where oid='public.photo_quality_evidence_reserve(uuid,uuid,jsonb)'::regprocedure)='770b45978bb6d57c074bac2a9fdc54ba'then return;end if;
 if (select md5(prosrc)from pg_proc where oid='public.photo_quality_evidence_reserve(uuid,uuid,jsonb)'::regprocedure)<>'01d75528461a5bd46d6e2aaf8d305bb6'
  or length(definition)-length(replace(definition,before_clause,''))<>length(before_clause)then
  raise exception'Review changed photo candidate output admission before applying25MiB bound';
 end if;
 execute replace(definition,before_clause,after_clause);
 if(select md5(prosrc)from pg_proc where oid='public.photo_quality_evidence_reserve(uuid,uuid,jsonb)'::regprocedure)<>'770b45978bb6d57c074bac2a9fdc54ba'then raise exception'Unexpected changed photo output authority';end if;
end$$;
