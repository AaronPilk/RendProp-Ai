-- Owner-operated accounting export. SELECT only: no provider call, mutation,
-- customer text, media URL/key, prompt, account name, email or credential.
-- Counts accompany bounded arrays; the report refuses an incomplete export.
with limits as(select 50000 as n),
ledger as(
 select l.id,l.job_id,l.org_id,l.billing_org_id,l.feature,l.provider,l.model,
  l.units::text,l.unit_cost_cents::text,l.total_cents::text,l.created_at,l.idempotency_key,
  j.listing_id,j.status as job_state,
  coalesce((select jsonb_object_agg(k,v) from jsonb_each(l.meta) m(k,v)
   where k=any(array['request_key','request_id','provider_request_id','stage','task','route_id',
    'tariff','price_version','cost_basis','price_estimated','outcome','failed','attempt','attempts',
    'input_tokens','output_tokens','provider_usage','photo_check_id','evidence_id',
    'app_video_reservation_id','kind','verdict','quality_profile'])),'{}') as meta
 from public.cost_ledger l left join public.render_jobs j on j.id=l.job_id
 order by l.created_at,l.id limit(select n+1 from limits)
),
serving as(
 select id,org_id,billing_org_id,actor_id,request_key,stage,provider,model,tariff_version,
  hold_cents::text,state,created_at,settled_at,ledger_id,budget_source
 from public.serving_cost_reservations order by created_at,id limit(select n+1 from limits)
),
video as(
 select id,org_id,billing_org_id,actor_id,idempotency_key,feature,provider,model,
  total_cents::text,hold_cents::text,provider_request_id,cost_ledger_id,created_at,settled_at,
  released_at,rejection_status,rejection_error_class,
  coalesce((select jsonb_object_agg(k,v) from jsonb_each(r.meta) m(k,v)
   where k=any(array['task','route_id','price_estimated','listing_id'])),'{}') as meta
 from public.app_video_cost_reservations r order by created_at,id limit(select n+1 from limits)
),
photo_scope as(
 select e.org_id,e.actor_id,e.listing_id,e.request_key,e.id as evidence_id,
  e.state,q.id as check_id,q.state as check_state
 from public.photo_edit_evidence e left join public.photo_quality_checks q on q.evidence_id=e.id
 order by e.created_at,e.id limit(select n+1 from limits)
),
video_scope as(
 select j.org_id,j.actor_id,j.listing_id,j.id as job_id,j.state as job_state,
  s.position,s.request_key,s.state as source_state,s.quality_retries
 from public.property_video_jobs j join public.property_video_job_sources s on s.job_id=j.id
 order by j.created_at,j.id,s.position limit(select n+1 from limits)
),
spatial as(
 select id,org_id,listing_id,status,cost_cents::text,max_cost_cents::text,created_at
 from public.spatial_jobs order by created_at,id limit(select n+1 from limits)
),
other_journals as(
 select 'presenter' as kind,id::text as id,org_id,listing_id,state,
  price_version,quote_cents::text as priced_cents,held_cents::text as held_cents,
  charged_cents::text as charged_cents,null::uuid as ledger_id,request_id as supplier_request_id,
  (billing_reference is not null) as has_billing_reference,created_at
 from public.studio_presenter_jobs
 union all
 select 'video_erase_job',j.id::text,j.org_id,b.listing_id,j.state,null,j.cost_cents::text,
  case when j.cost_ledger_id is null and j.cost_hold_released_at is null then j.cost_cents else 0 end::text,
  null,j.cost_ledger_id,coalesce(j.provider_ref->>'id',j.provider_ref->>'request_id'),false,j.created_at
 from public.video_erase_jobs j left join public.video_erase_batches b on b.id=j.batch_id
 union all
 select 'video_erase_stage',s.job_id::text||':'||s.stage,j.org_id,b.listing_id,s.state,null,s.cost_cents::text,
  case when s.admitted_at is not null and s.cost_ledger_id is null and s.cost_hold_released_at is null then s.cost_cents else 0 end::text,
  null,s.cost_ledger_id,coalesce(s.provider_ref->>'id',s.provider_ref->>'request_id'),false,j.created_at
 from public.video_erase_stages s join public.video_erase_jobs j on j.id=s.job_id
 left join public.video_erase_batches b on b.id=j.batch_id
 order by created_at,id limit(select n+1 from limits)
)
select jsonb_build_object('schema',1,'currency','USD','exported_at',now(),
 'authority',jsonb_build_object('database_role',current_user,
  'bypass_rls',coalesce((select rolbypassrls or rolsuper from pg_catalog.pg_roles where rolname=current_user),false)),
 'max_rows_per_table',(select n from limits),
 'counts',jsonb_build_object('ledger',(select count(*)from public.cost_ledger),
  'serving',(select count(*)from public.serving_cost_reservations),
  'video',(select count(*)from public.app_video_cost_reservations),
  'photo_scope',(select count(*)from public.photo_edit_evidence e left join public.photo_quality_checks q on q.evidence_id=e.id),
  'video_scope',(select count(*)from public.property_video_job_sources),
  'spatial',(select count(*)from public.spatial_jobs),
  'other_journals',(select count(*)from public.studio_presenter_jobs)+(select count(*)from public.video_erase_jobs)+(select count(*)from public.video_erase_stages)),
 'ledger',coalesce((select jsonb_agg(ledger)from ledger),'[]'),
 'serving',coalesce((select jsonb_agg(serving)from serving),'[]'),
 'video',coalesce((select jsonb_agg(video)from video),'[]'),
 'photo_scope',coalesce((select jsonb_agg(photo_scope)from photo_scope),'[]'),
 'video_scope',coalesce((select jsonb_agg(video_scope)from video_scope),'[]'),
 'spatial',coalesce((select jsonb_agg(spatial)from spatial),'[]'),
 'other_journals',coalesce((select jsonb_agg(other_journals)from other_journals),'[]'),
 'unpriced_usage',jsonb_build_object(
  'metering_watch_ms',(select coalesce(sum(watch_ms),0)::text from public.metering),
  'media_delivery_requests',(select coalesce(sum(used_requests),0)::text from public.media_delivery_budgets),
  'media_delivery_bytes',(select coalesce(sum(used_bytes),0)::text from public.media_delivery_budgets))) as snapshot;
