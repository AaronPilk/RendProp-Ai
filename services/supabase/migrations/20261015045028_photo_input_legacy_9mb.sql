-- Restore the existing decoded 9 MB editing-copy contract after verification
-- under the matching Edge Runtime 1.77.0 native 256 MB/2 second governor.
-- Originals, candidate output bounds, geometry, ownership, paid receipts, context
-- and historical pointers are unchanged. No policy is activated here.
begin;
do $restore$declare f regprocedure:='public.photo_quality_begin(uuid,uuid,text,uuid,text,text,uuid,jsonb,jsonb)'::regprocedure; definition text; actual text;begin
 select md5(prosrc)into actual from pg_proc where oid=f;
 if actual='7797c55957200efed1e247dda01aff92'then return;end if;
 if actual is distinct from'e5f4ddba1d19c1096c7368f97bb44cf4'then raise exception'Review changed photo input authority photo_quality_begin';end if;
 select pg_get_functiondef(f)into definition;
 if (length(definition)-length(replace(definition,'(p_input->>''bytes'')::bigint>1000000','')))/length('(p_input->>''bytes'')::bigint>1000000')<>1 then raise exception'Expected one prepared input guard in photo_quality_begin';end if;
 execute replace(definition,'(p_input->>''bytes'')::bigint>1000000','(p_input->>''bytes'')::bigint>9000000');
 if(select md5(prosrc)from pg_proc where oid=f)is distinct from'7797c55957200efed1e247dda01aff92'then raise exception'Unexpected restored photo input authority photo_quality_begin';end if;
end$restore$;

do $restore$declare f regprocedure:='public.photo_quality_calibration_begin(uuid,uuid,text,text,uuid,text,text,uuid,jsonb,jsonb)'::regprocedure; definition text; actual text;begin
 select md5(prosrc)into actual from pg_proc where oid=f;
 if actual='7e208bcdf50821cd400cb33b5e00e8fc'then return;end if;
 if actual is distinct from'6a1e555f624803c16e36b75c61f508e2'then raise exception'Review changed photo input authority photo_quality_calibration_begin';end if;
 select pg_get_functiondef(f)into definition;
 if (length(definition)-length(replace(definition,'(p_input->>''bytes'')::bigint>1000000','')))/length('(p_input->>''bytes'')::bigint>1000000')<>1 then raise exception'Expected one prepared input guard in photo_quality_calibration_begin';end if;
 execute replace(definition,'(p_input->>''bytes'')::bigint>1000000','(p_input->>''bytes'')::bigint>9000000');
 if(select md5(prosrc)from pg_proc where oid=f)is distinct from'7e208bcdf50821cd400cb33b5e00e8fc'then raise exception'Unexpected restored photo input authority photo_quality_calibration_begin';end if;
end$restore$;
commit;
