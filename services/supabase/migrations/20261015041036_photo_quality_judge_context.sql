-- Retain the verified request's bounded judge context before a paid check.
-- Service-only: clients cannot rewrite instructions after their body hash was
-- admitted, and a private worker never accepts arbitrary instructions/models.
begin;
alter table public.photo_edit_evidence add column if not exists judge_context jsonb;
create or replace function public.photo_quality_set_context(p_actor uuid,p_evidence uuid,p_request_sha256 text,p_context jsonb)returns jsonb
language plpgsql security definer set search_path=''as $$declare e public.photo_edit_evidence;q public.photo_quality_checks;begin
 if current_setting('role',true)is distinct from'service_role'then raise insufficient_privilege;end if;
 e:=public.photo_quality_scope(p_actor,p_evidence);
 select * into q from public.photo_quality_checks where evidence_id=e.id and automatic for update;
 select * into e from public.photo_edit_evidence where id=e.id for update;
 if p_request_sha256 is distinct from e.request_sha256 then raise exception'RP409: Judge context must match the admitted complete photo request';end if;
 if jsonb_typeof(p_context)is distinct from'object'then raise exception'RP400: Exact bounded retained photo judge context is required';end if;
 if(select count(*)from jsonb_object_keys(p_context))<>3
  or exists(select 1 from jsonb_object_keys(p_context)k where k not in('edit','style','instruction'))
  or p_context->'edit'is distinct from to_jsonb(e.edit)or p_context->'style'is distinct from coalesce(to_jsonb(e.style),'null'::jsonb)
  or jsonb_typeof(p_context->'instruction')is distinct from'string'or length(p_context->>'instruction')>600 or octet_length(p_context->>'instruction')>2400 or pg_column_size(p_context)>4096 then raise exception'RP400: Exact bounded retained photo judge context is required';end if;
 if e.judge_context is not null then if e.judge_context is distinct from p_context then raise exception'RP409: Saved photo judge context is immutable';end if;return public.photo_quality_snapshot(p_actor,e.id);end if;
 if q.id is null or q.judge_started_at is not null or q.state in('checking','accept','refuse','hold')then raise exception'RP409: Photo judge context cannot be added after dispatch or a terminal review';end if;
 update public.photo_edit_evidence set judge_context=p_context,updated_at=now()where id=e.id;
 return public.photo_quality_snapshot(p_actor,e.id);end$$;
-- Keep the reviewed binding implementation, but make the only callable entry
-- enforce saved context. The previous function is deliberately not executable
-- by the service role, preventing an accidental bypass from another handler.
do $$begin if to_regprocedure('public.photo_quality_bind_before_context(uuid,uuid,uuid,uuid)')is null then
 if(select md5(prosrc)from pg_proc where oid='public.photo_quality_check_bind(uuid,uuid,uuid,uuid)'::regprocedure)is distinct from'947f12ca92492be65da21ceaa3beb29a'then raise exception'Review changed photo quality funding bind before adding context';end if;
 alter function public.photo_quality_check_bind(uuid,uuid,uuid,uuid)rename to photo_quality_bind_before_context;
end if;end$$;
create or replace function public.photo_quality_check_bind(p_actor uuid,p_check uuid,p_lease uuid,p_reservation uuid)returns jsonb
language plpgsql security definer set search_path=''as $$declare q public.photo_quality_checks;e public.photo_edit_evidence;begin
 if current_setting('role',true)is distinct from'service_role'then raise insufficient_privilege;end if;
 select * into q from public.photo_quality_checks where id=p_check for update;
 if q.id is null then raise exception'RP404: Saved photo check is unavailable';end if;e:=public.photo_quality_scope(p_actor,q.evidence_id);
 if e.judge_context is null then raise exception'RP409: Exact saved photo judge context is missing; no quality provider was dispatched';end if;
 return public.photo_quality_bind_before_context(p_actor,p_check,p_lease,p_reservation);end$$;
revoke all on function public.photo_quality_set_context(uuid,uuid,text,jsonb),public.photo_quality_check_bind(uuid,uuid,uuid,uuid)from public,anon,authenticated;
grant execute on function public.photo_quality_set_context(uuid,uuid,text,jsonb),public.photo_quality_check_bind(uuid,uuid,uuid,uuid)to service_role;
revoke all on function public.photo_quality_bind_before_context(uuid,uuid,uuid,uuid)from public,anon,authenticated,service_role;
grant execute on function public.photo_quality_bind_before_context(uuid,uuid,uuid,uuid)to postgres;
commit;
