-- Prospective smooth photo-animation recipe. No app_config/default/route,
-- saved manifest/profile, price, allowance, hold or historical output changes.
begin;
do $patch$declare p record;body text;original text;definition text;i integer;begin
 for p in select *from(values
('public.property_video_quality_profile()','73a53253d8b7e08c6f48b98d273c06ec','ea27e5d9a2848810bbd28ec744819f47',array[$anchor$if c->'enabled'='true'::jsonb and c->>'profile'='fal-kling3-4k-v1'then return'fal-kling3-4k-v1';end if;$anchor$],array[$replacement$if c->'enabled'='true'::jsonb and c->>'profile'in('fal-kling3-4k-v1','fal-kling3-4k-steady-v2')then return c->>'profile';end if;$replacement$]),
('public.property_video_quality_freeze()','3c46e55a9b75179c95c7bbe4b9d587c8','6ae05e2c05a0007cbedeb754437889bd',array[$anchor$quoted not in('legacy','fal-kling3-4k-v1')$anchor$,$anchor$if quoted='fal-kling3-4k-v1'then new.deadline$anchor$],array[$replacement$quoted not in('legacy','fal-kling3-4k-v1','fal-kling3-4k-steady-v2')$replacement$,$replacement$if quoted in('fal-kling3-4k-v1','fal-kling3-4k-steady-v2')then new.deadline$replacement$]),
('public.property_video_job_admit(uuid,jsonb,numeric,text)','65c378cc76463df69aa047f9954e808f','7a2b40f20d4c63c2faf0029e5e1bda94',array[$anchor$p_quality_profile not in('legacy','fal-kling3-4k-v1')$anchor$,$anchor$if p_quality_profile='fal-kling3-4k-v1'and($anchor$],array[$replacement$p_quality_profile not in('legacy','fal-kling3-4k-v1','fal-kling3-4k-steady-v2')$replacement$,$replacement$if p_quality_profile in('fal-kling3-4k-v1','fal-kling3-4k-steady-v2')and($replacement$]),
('public.paid_quality_processing_budget(uuid)','dc9545aca93587c3d9261c808084996f','d519be40bb1028a8d014fd1f47d20130',array[$anchor$v->>'profile'='fal-kling3-4k-v1'$anchor$],array[$replacement$v->>'profile'in('fal-kling3-4k-v1','fal-kling3-4k-steady-v2')$replacement$]),
('public.property_video_job_audio_preflight(uuid,uuid,text,text,numeric,integer)','08392090a9ceec5ee8fb8d72fe3f7bfd','2b4f442689386f645e9cb89fcfd4be91',array[$anchor$join_frames integer;begin$anchor$,$anchor$join_frames:=case j.manifest#>>'{presentation,transition}'when'dissolve'then 8 when'whip'then 5 else 0 end;max_duration:=j.source_count*5-(j.source_count-1)*join_frames/30.0;$anchor$],array[$replacement$join_frames integer;output_fps integer;begin$replacement$,$replacement$output_fps:=case when j.quality_profile='fal-kling3-4k-steady-v2'then 24 else 30 end;
 join_frames:=case j.manifest#>>'{presentation,transition}'when'dissolve'then case when output_fps=24 then 6 else 8 end when'whip'then case when output_fps=24 then 4 else 5 end else 0 end;max_duration:=j.source_count*5-(j.source_count-1)*join_frames/output_fps::numeric;$replacement$]),
('public.background_video_delivery(uuid,uuid,uuid,text,bigint)','1b32cd06de0d5d7d2bee53f6302e4d2a','67354e0acac516a3c6402903318235ab',array[$anchor$'max_object_bytes',1610612736);$anchor$],array[$replacement$'max_object_bytes',1610612736)||case when j.quality_profile='fal-kling3-4k-steady-v2'then jsonb_build_object('quality_profile',j.quality_profile)else'{}'::jsonb end;$replacement$])
 )v(signature,before_md5,after_md5,anchors,replacements)loop
  select prosrc into body from pg_proc where oid=p.signature::regprocedure;
  if md5(body)not in(p.before_md5,p.after_md5)then raise exception'Review changed steady-v2 dependency: %',p.signature;end if;
  if md5(body)=p.before_md5 then
   original:=body;
   for i in 1..array_length(p.anchors,1)loop
    if(length(body)-length(replace(body,p.anchors[i],'')))/length(p.anchors[i])<>1 then raise exception'Exact steady-v2 anchor changed: %',p.signature;end if;
    body:=replace(body,p.anchors[i],p.replacements[i]);
   end loop;
   if md5(body)<>p.after_md5 then raise exception'Unexpected steady-v2 body: %',p.signature;end if;
   definition:=pg_get_functiondef(p.signature::regprocedure);
   if position(original in definition)=0 then raise exception'Steady-v2 function definition changed: %',p.signature;end if;
   execute replace(definition,original,body);
  end if;
 end loop;
end$patch$;
do $constraint$declare actual text;begin
 select pg_get_constraintdef(oid)into actual from pg_constraint where conrelid='public.property_video_jobs'::regclass and conname='property_video_quality_profile_check'and contype='c'and convalidated;
 if actual=$old$CHECK ((quality_profile = ANY (ARRAY['legacy'::text, 'fal-kling3-4k-v1'::text])))$old$ then
  alter table public.property_video_jobs drop constraint property_video_quality_profile_check;
  alter table public.property_video_jobs add constraint property_video_quality_profile_check check(quality_profile in('legacy','fal-kling3-4k-v1','fal-kling3-4k-steady-v2'));
 elsif actual is distinct from $expected$CHECK ((quality_profile = ANY (ARRAY['legacy'::text, 'fal-kling3-4k-v1'::text, 'fal-kling3-4k-steady-v2'::text])))$expected$ then raise exception'Review changed saved quality profile constraint';end if;
end$constraint$;
commit;
