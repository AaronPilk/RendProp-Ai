-- Source-only proposal: one raw source-duration tolerance. No media/state/data writes.
-- Actual captured predecessor full pg_get_functiondef MD5: 53c0fb5bcd45377af7753cbcd3d1cb86.
-- Raw ffprobe FORMAT timing may be millisecond-rounded. Normalized output stays exact.
begin;
set local lock_timeout='5s';
set local statement_timeout='30s';
do $precision$
declare
 target_ regprocedure := 'public.property_video_aerial_cpu_output(uuid,text,uuid,jsonb,boolean)'::regprocedure;
 before_ text; after_ text; metadata_ jsonb; after_metadata_ jsonb;
 needle_ text := $needle$or coalesce(abs((p_facts#>>'{source_metadata,duration_s}')::numeric-(p_facts->>'available_frames')::numeric/24),1)>.000001$needle$;
 replacement_ text := $needle$or coalesce(abs((p_facts#>>'{source_metadata,duration_s}')::numeric-(p_facts->>'available_frames')::numeric/24),1)>.001$needle$;
begin
 select pg_get_functiondef(target_) into before_;
 if md5(before_) is distinct from '53c0fb5bcd45377af7753cbcd3d1cb86'
  or (length(before_)-length(replace(before_,needle_,'')))/length(needle_) <> 1
 then raise exception 'Aerial precision predecessor changed; no replacement applied'; end if;
 select (to_jsonb(p)-'prosrc')||jsonb_build_object('comment',obj_description(p.oid,'pg_proc')) into metadata_ from pg_proc p where p.oid=target_;
 after_ := replace(before_,needle_,replacement_);
 if md5(after_) is distinct from '9f2251777f9e9e475e56121c8ab07582'
 then raise exception 'Aerial precision replacement is not the exact reviewed definition'; end if;
 execute after_;
 select (to_jsonb(p)-'prosrc')||jsonb_build_object('comment',obj_description(p.oid,'pg_proc')) into after_metadata_ from pg_proc p where p.oid=target_;
 if metadata_ is distinct from after_metadata_
  or pg_get_functiondef(target_) is distinct from after_
 then raise exception 'Aerial precision metadata or definition changed unexpectedly'; end if;
end
$precision$;
commit;
