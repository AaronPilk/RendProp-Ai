-- Disposable, rollback-only proof of the prospective variable-credit admission.
begin;
create temporary table pm_admission_checks(n integer not null default 0);
insert into pm_admission_checks default values;
grant all on pm_admission_checks to service_role;
create function pg_temp.pm_admit_ok(v boolean,label text)
returns void language plpgsql as $$begin
  if v is distinct from true then raise exception 'PM CREDIT ADMISSION FAIL: %',label;end if;
  update pm_admission_checks set n=n+1;
end$$;
create function pg_temp.pm_admit_refuses(statement text,needle text,label text)
returns void language plpgsql as $$begin
  begin execute statement;exception when others then
    if position(needle in sqlerrm)>0 then perform pg_temp.pm_admit_ok(true,label);return;end if;
    raise;
  end;
  raise exception 'PM CREDIT ADMISSION FAIL admitted: %',label;
end$$;
insert into auth.users(id,email,is_anonymous) values
 ('b0111111-1111-4111-8111-111111111111','pm-credit@example.invalid',false);
insert into public.orgs(id,name,plan,plan_source) values
 ('b0aaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa','Photo Motion credit fixture','pro','manual');
insert into public.memberships(user_id,org_id,role) values
 ('b0111111-1111-4111-8111-111111111111',
  'b0aaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa','owner');
insert into public.listings(id,org_id,agent_id,address) values
 ('b0222222-2222-4222-8222-222222222222',
  'b0aaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
  'b0111111-1111-4111-8111-111111111111','Synthetic video property');
-- An existing property remains usable when the original plan downgrades and
-- the workspace later buys one-off processing credits.
update public.orgs set plan='free',plan_source=null
 where id='b0aaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
set local session_replication_role=replica;
insert into public.capture_assets(id,listing_id,kind,bucket,storage_key,
 bytes,sha256,uploaded,transport_version,content_type,width,height) values
 ('b0333333-3333-4333-8333-333333333333',
  'b0222222-2222-4222-8222-222222222222','photo','uploads',
  'uploads/b0aaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa/b0222222-2222-4222-8222-222222222222/front.jpg',
  1000000,repeat('a',64),true,2,'image/jpeg',2560,1440);
insert into public.photos(listing_id,original_key) values
 ('b0222222-2222-4222-8222-222222222222',
  'uploads/b0aaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa/b0222222-2222-4222-8222-222222222222/front.jpg');
insert into public.upload_reservations(asset_id,org_id,listing_id,actor_id,day,
 spec,held_bytes,spent_bytes,state,settled_at) values
 ('b0333333-3333-4333-8333-333333333333',
  'b0aaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
  'b0222222-2222-4222-8222-222222222222',
  'b0111111-1111-4111-8111-111111111111',current_date,
  '{"bucket":"uploads","kind":"photo"}',0,1000000,'completed',now());
insert into public.upload_operations(asset_id,kind,bucket,object_key,bytes,
 expected_bytes,content_type,content_type_declared,asset_kind,state,etag) values
 ('b0333333-3333-4333-8333-333333333333','copy','uploads',
  'uploads/b0aaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa/b0222222-2222-4222-8222-222222222222/front.jpg',
  1000000,1000000,'image/jpeg',true,'photo','retained','"pm-credit"');
set local session_replication_role=origin;
insert into public.credit_grants(org_id,environment,source,reference,product_id,
 granted_credits,remaining_credits,expires_at) values
 ('b0aaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa','Production','topup',
  'synthetic-pm-credit-topup','com.rendprop.app.credits.100',100,100,null);
update public.app_config set value=jsonb_set(value,'{enabled}','true'::jsonb)
 where key='property_video_jobs';
insert into public.app_config(key,value) values('photo_motion_renderer_v2',
 jsonb_build_object('enabled',true,
   'composition_profile','photo-motion-v2-cfr24',
   'producer_identity',jsonb_build_object(
      'image_uri','registry.cloudflare.com/9c332c75b96cc642621dad5d86d4bf18/rendprop-property-video-photo-motion@sha256:f8bf65d52390bdd4470c36638b141251ec9fe924aa30bb7218fdbcba09a809ec',
      'controller_sha256','604b92b2c8b6a3ccfd49ac6bec6ff81993e52062c71ba6f910f057d1e2cb3db6',
      'renderer_source_sha256','a98b48825fbd819dbf49fd4c2cca4b836cdd81d57bedda5bf2de7774a42d98be')))
on conflict(key) do update set value=excluded.value;
drop trigger credit_photo_motion_activation_guard on public.app_config;
update public.app_config set value=jsonb_set(
  jsonb_set(value,'{enabled}','true'::jsonb),
  '{activation_ready}','true'::jsonb) where key='credit_photo_motion';

create temporary table pm_admission_manifest as select jsonb_build_object(
 'source_mode','photo_motion_v1','composition_profile','photo-motion-v2-cfr24',
 'operation_id','b0444444-4444-4444-8444-444444444444',
 'listing_id','b0222222-2222-4222-8222-222222222222',
 'expected_org_id','b0aaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
 'purpose','listing','aspect','16:9',
 'sources',jsonb_build_array(jsonb_build_object(
   'photo_id','synthetic-original-1',
   'photo_asset_id','b0333333-3333-4333-8333-333333333333',
   'photo_version_id','asset:b0333333-3333-4333-8333-333333333333',
   'photo_provenance_id',null,'motion','push_in','visible_frames',48,
   'source_sha256',repeat('a',64),'source_bytes',1000000)),
 'presentation',jsonb_build_object('transition','cut',
   'shot_caption_style','off','spoken_captions',false,
   'shot_labels',jsonb_build_array('')),
 'allow_original_photo_fallback',false,'music',null) manifest;
grant select on pm_admission_manifest to service_role;

set local role service_role;
select pg_temp.pm_admit_ok((select
  (public.credit_photo_motion_quote(
    'b0111111-1111-4111-8111-111111111111',manifest,'Production')->>'credits')::integer=8
  from pm_admission_manifest),'one-photo supplier maximum rounds to eight credits');
select pg_temp.pm_admit_ok((select
  public.credit_photo_motion_quote(
    'b0111111-1111-4111-8111-111111111111',manifest,'Production')->>'quote_sha256'
  is distinct from public.credit_photo_motion_quote(
    'b0111111-1111-4111-8111-111111111111',manifest,'Sandbox')->>'quote_sha256'
  from pm_admission_manifest),
  'Sandbox approval cannot authorize the same recipe against Production credits');
select pg_temp.pm_admit_ok((select
  public.credit_photo_motion_quote(
    'b0111111-1111-4111-8111-111111111111',manifest,'Production')->>'quote_sha256'
  is distinct from public.credit_photo_motion_quote(
    'b0111111-1111-4111-8111-111111111111',
    jsonb_set(manifest,'{operation_id}',
      '"b0555555-5555-4555-8555-555555555555"'::jsonb),
    'Production')->>'quote_sha256'
  from pm_admission_manifest),
  'same-price changed recipe requires a new approval digest');
select pg_temp.pm_admit_ok((select public.credit_photo_motion_applicable(
  'b0111111-1111-4111-8111-111111111111',
  'b0aaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa','Production')),
  'free account with verified top-up wallet uses credit route');
select pg_temp.pm_admit_refuses($sql$select public.property_video_job_admit_photo_motion(
  'b0111111-1111-4111-8111-111111111111',manifest)
  from pm_admission_manifest$sql$,
  'RP409: Photo Motion credit quote changed before admission',
  'direct create cannot bypass the exact displayed quote');
select pg_temp.pm_admit_refuses($sql$select public.property_video_job_admit_photo_motion_quoted(
  'b0111111-1111-4111-8111-111111111111',manifest,
  public.credit_photo_motion_quote(
    'b0111111-1111-4111-8111-111111111111',manifest,'Sandbox')->>'quote_sha256')
  from pm_admission_manifest$sql$,
  'RP409: Photo Motion credit quote changed before admission',
  'a Sandbox approval cannot create a Production hold');
select pg_temp.pm_admit_ok(not exists(select 1 from public.credit_holds
  where operation='video.photo_motion'),
  'mismatched preflight hashes create no customer hold');
reset role;
update public.app_config set value=jsonb_set(value,'{enabled}','false'::jsonb)
  where key='credit_photo_motion';
set local role service_role;
select pg_temp.pm_admit_refuses($sql$select public.property_video_job_admit_photo_motion_quoted(
  'b0111111-1111-4111-8111-111111111111',manifest,
  public.credit_photo_motion_quote(
    'b0111111-1111-4111-8111-111111111111',manifest,'Production')->>'quote_sha256')
  from pm_admission_manifest$sql$,
  'RP409: Photo Motion credit route changed before admission',
  'a switch from credits to plan cannot use a saved credit approval');
reset role;
update public.app_config set value=jsonb_set(value,'{enabled}','true'::jsonb)
  where key='credit_photo_motion';
set local role service_role;
select pg_temp.pm_admit_ok((select
  (public.property_video_job_admit_photo_motion_quoted(
    'b0111111-1111-4111-8111-111111111111',manifest,
    public.credit_photo_motion_quote(
      'b0111111-1111-4111-8111-111111111111',manifest,'Production')->>'quote_sha256')->>'accepted')::boolean
  from pm_admission_manifest),'exact saved Photo Motion job is admitted');
select pg_temp.pm_admit_ok((select count(*)=1 and min(credits)=8
  from public.credit_holds where operation='video.photo_motion'),
  'one immutable eight-credit hold is created');
select pg_temp.pm_admit_ok((select remaining_credits=92 from public.credit_grants
  where reference='synthetic-pm-credit-topup'),
  'top-up credits fund the new video in place of a monthly reel counter');
select pg_temp.pm_admit_ok(not exists(select 1 from public.rate_limits
  where key='reelmo:b0aaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'),
  'credit video does not also consume legacy clip allowance');
select pg_temp.pm_admit_ok((select count(*)=1 and
  bool_and(q.job_id is not null and r.budget_source='credits' and
    r.credit_hold_id=q.hold_id and r.hold_cents=q.maximum_supplier_cents)
  from public.credit_photo_motion_quotes q
  join public.serving_cost_reservations r on r.id=q.reservation_id),
  'job, exact supplier envelope and customer hold bind atomically');
select pg_temp.pm_admit_ok((select
  (public.property_video_job_admit_photo_motion(
    'b0111111-1111-4111-8111-111111111111',manifest)->>'accepted')::boolean
  from pm_admission_manifest),'lost reply replays the same operation');
select pg_temp.pm_admit_ok((select count(*)=1 and min(credits)=8
  from public.credit_holds where operation='video.photo_motion') and
  (select remaining_credits=92 from public.credit_grants
   where reference='synthetic-pm-credit-topup'),
  'replay cannot double-charge customer credits');
select pg_temp.pm_admit_ok((select count(*)=1 and bool_and(
  risk.job_id=q.job_id and risk.reservation_id=q.reservation_id and
  risk.maximum_cents=q.maximum_supplier_cents and risk.state='reserved')
  from public.credit_photo_motion_failure_budget risk
  join public.credit_photo_motion_quotes q on q.hold_id=risk.hold_id),
  'one full supplier-failure risk hold is bound to the exact job');
reset role;
update public.property_video_jobs set state='cancelled',cancelled_at=now(),updated_at=now()
 where operation_id='b0444444-4444-4444-8444-444444444444';
set local role service_role;
select pg_temp.pm_admit_ok((select
  public.credit_photo_motion_reconcile(q.job_id)->>'state'='released'
  from public.credit_photo_motion_quotes q where q.operation_id=
  'b0444444-4444-4444-8444-444444444444'),
  'cancel before CPU work returns every customer credit');
select pg_temp.pm_admit_ok((select h.state='released' and r.state='rejected'
  and risk.state='released' and risk.spent_cents=0
  from public.credit_photo_motion_quotes q
  join public.credit_holds h on h.id=q.hold_id
  join public.serving_cost_reservations r on r.id=q.reservation_id
  join public.credit_photo_motion_failure_budget risk on risk.hold_id=q.hold_id
  where q.operation_id='b0444444-4444-4444-8444-444444444444') and
  (select remaining_credits=100 from public.credit_grants
    where reference='synthetic-pm-credit-topup'),
  'definitive no-work outcome has no supplier liability or customer debit');

reset role;
update pm_admission_manifest set manifest=jsonb_set(manifest,
  '{operation_id}','"b0555555-5555-4555-8555-555555555555"'::jsonb);
set local role service_role;
select pg_temp.pm_admit_ok((select
  (public.property_video_job_admit_photo_motion_quoted(
    'b0111111-1111-4111-8111-111111111111',manifest,
    public.credit_photo_motion_quote(
      'b0111111-1111-4111-8111-111111111111',manifest,'Production')->>'quote_sha256')->>'accepted')::boolean
  from pm_admission_manifest),'a second immutable credit job can use refunded top-up');
reset role;
update public.property_video_jobs set state='composing',compose_attempts=1,
  compose_lease='b0666666-6666-4666-8666-666666666666',updated_at=now()
 where operation_id='b0555555-5555-4555-8555-555555555555';
set local role service_role;
select pg_temp.pm_admit_ok((select
  (public.property_video_photo_motion_observe(j.id,j.compose_lease,
    j.manifest_sha256,'compose','failed',1000,
    j.quality_identity->'producer_identity')->>'recorded')::boolean
  from public.property_video_jobs j where operation_id=
    'b0555555-5555-4555-8555-555555555555'),
  'failed CPU observation journals a real supplier attempt');
reset role;
update public.property_video_jobs set state='failed',updated_at=now()
 where operation_id='b0555555-5555-4555-8555-555555555555';
set local role service_role;
select pg_temp.pm_admit_ok((select
  public.credit_photo_motion_reconcile(q.job_id)->>'state'='released'
  from public.credit_photo_motion_quotes q where q.operation_id=
  'b0555555-5555-4555-8555-555555555555'),
  'failed CPU work refunds the customer while retaining supplier liability');
select pg_temp.pm_admit_ok((select h.state='released' and
  r.budget_source='video_failure' and risk.state='spent' and
  risk.spent_cents=q.maximum_supplier_cents
  from public.credit_photo_motion_quotes q
  join public.credit_holds h on h.id=q.hold_id
  join public.serving_cost_reservations r on r.id=q.reservation_id
  join public.credit_photo_motion_failure_budget risk on risk.hold_id=q.hold_id
  where q.operation_id='b0555555-5555-4555-8555-555555555555') and
  (select remaining_credits=100 from public.credit_grants
    where reference='synthetic-pm-credit-topup'),
  'failure loss is capped outside customer credits and refunded once');
select pg_temp.pm_admit_ok((select
  public.credit_photo_motion_reconcile(q.job_id)->>'replay'='true'
  from public.credit_photo_motion_quotes q where q.operation_id=
  'b0555555-5555-4555-8555-555555555555'),
  'terminal reconciliation replays without another refund');

reset role;
update pm_admission_manifest set manifest=jsonb_set(manifest,
  '{operation_id}','"b0999999-9999-4999-8999-999999999999"'::jsonb);
set local role service_role;
select pg_temp.pm_admit_ok((select
  (public.property_video_job_admit_photo_motion_quoted(
    'b0111111-1111-4111-8111-111111111111',manifest,
    public.credit_photo_motion_quote(
      'b0111111-1111-4111-8111-111111111111',manifest,'Production')->>'quote_sha256')->>'accepted')::boolean
  from pm_admission_manifest),'successful credit job is admitted once');
reset role;
update public.property_video_jobs set state='composing',compose_attempts=1,
  compose_lease='b0a33333-3333-4333-8333-333333333333',updated_at=now()
 where operation_id='b0999999-9999-4999-8999-999999999999';
set local role service_role;
select pg_temp.pm_admit_ok((select
  (public.property_video_photo_motion_observe(j.id,j.compose_lease,
    j.manifest_sha256,'compose','failed',1000,
    j.quality_identity->'producer_identity')->>'recorded')::boolean
  from public.property_video_jobs j where operation_id=
    'b0999999-9999-4999-8999-999999999999'),
  'first failed CPU attempt makes supplier liability uncertain');
reset role;
update public.property_video_jobs set state='composing',compose_attempts=2,
  compose_lease='b0a00000-0000-4000-8000-000000000000',updated_at=now()
 where operation_id='b0999999-9999-4999-8999-999999999999';
set local role service_role;
select pg_temp.pm_admit_ok((select
  (public.property_video_photo_motion_observe(j.id,j.compose_lease,
    j.manifest_sha256,'compose','completed',1000,
    j.quality_identity->'producer_identity')->>'recorded')::boolean
  from public.property_video_jobs j where operation_id=
    'b0999999-9999-4999-8999-999999999999'),
  'retry completion is retained under its second exact CPU lease');
reset role;
set local session_replication_role=replica;
insert into public.capture_assets(id,listing_id,kind,bucket,storage_key,
 bytes,sha256,uploaded,transport_version,content_type,width,height) values
 ('b0a11111-1111-4111-8111-111111111111',
  'b0222222-2222-4222-8222-222222222222','video','renders',
  'renders/b0aaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa/synthetic/credit-master.mp4',
  100000,repeat('b',64),true,2,'video/mp4',1920,1080),
 ('b0a22222-2222-4222-8222-222222222222',
  'b0222222-2222-4222-8222-222222222222','photo','renders',
  'renders/b0aaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa/synthetic/credit-poster.jpg',
  10000,repeat('c',64),true,2,'image/jpeg',1920,1080);
set local session_replication_role=origin;
update public.property_video_jobs set state='ready',updated_at=now(),
  output_asset_id='b0a11111-1111-4111-8111-111111111111',
  poster_asset_id='b0a22222-2222-4222-8222-222222222222',
  result='{"sha256":"synthetic-ready"}'::jsonb
 where operation_id='b0999999-9999-4999-8999-999999999999';
insert into public.property_video_job_outputs(asset_id,job_id,lease_token,kind,
 storage_key,bytes,sha256,content_type,etag,state)
select a.id,j.id,j.compose_lease,
  case when a.kind='video' then 'video' else 'photo' end,a.storage_key,
  a.bytes,a.sha256,a.content_type,'synthetic-ready-etag','ready'
from public.property_video_jobs j join public.capture_assets a on a.id in
 ('b0a11111-1111-4111-8111-111111111111',
  'b0a22222-2222-4222-8222-222222222222')
where j.operation_id='b0999999-9999-4999-8999-999999999999';
set local role service_role;
select pg_temp.pm_admit_ok((select r.state='uncertain'
  from public.credit_photo_motion_quotes q
  join public.serving_cost_reservations r on r.id=q.reservation_id
  where q.operation_id='b0999999-9999-4999-8999-999999999999'),
  'earlier failed CPU lease cannot overwrite its uncertain supplier state');
select pg_temp.pm_admit_ok((select
  public.credit_photo_motion_reconcile(q.job_id)->>'state'='settled'
  from public.credit_photo_motion_quotes q where q.operation_id=
  'b0999999-9999-4999-8999-999999999999'),
  'two exact ready receipts settle the customer credit hold');
select pg_temp.pm_admit_ok((select h.state='settled' and risk.state='released'
  and risk.spent_cents=0 and r.state='uncertain'
  from public.credit_photo_motion_quotes q
  join public.credit_holds h on h.id=q.hold_id
  join public.serving_cost_reservations r on r.id=q.reservation_id
  join public.credit_photo_motion_failure_budget risk on risk.hold_id=q.hold_id
  where q.operation_id='b0999999-9999-4999-8999-999999999999') and
  (select remaining_credits=92 from public.credit_grants
    where reference='synthetic-pm-credit-topup'),
  'successful retry consumes exactly eight credits and releases failure risk');
select pg_temp.pm_admit_ok((select
  public.credit_photo_motion_reconcile(q.job_id)->>'replay'='true'
  from public.credit_photo_motion_quotes q where q.operation_id=
  'b0999999-9999-4999-8999-999999999999'),
  'successful terminal settlement is idempotent');
reset role;

-- A depleted purchased pack keeps the credit route visible for top-up but
-- cannot create another hold, supplier reservation, or background job.
update public.credit_grants set remaining_credits=0
 where reference='synthetic-pm-credit-topup';
update pm_admission_manifest set manifest=jsonb_set(manifest,
  '{operation_id}','"b0b00000-0000-4000-8000-000000000000"'::jsonb);
set local role service_role;
select pg_temp.pm_admit_ok((select
  public.credit_photo_motion_review_quote(
    'b0111111-1111-4111-8111-111111111111',manifest)
      @> '{"mode":"credits","affordable":false,"available_credits":0}'::jsonb
  from pm_admission_manifest),
  'zero-balance Review still quotes the exact video charge for top-up');
select pg_temp.pm_admit_ok((select
  public.property_video_job_admit_photo_motion_quoted(
    'b0111111-1111-4111-8111-111111111111',manifest,
    public.credit_photo_motion_quote(
      'b0111111-1111-4111-8111-111111111111',manifest,'Production')->>'quote_sha256')
    @> '{"accepted":false,"operation_closed":false}'::jsonb
  from pm_admission_manifest),
  'depleted wallet refuses but leaves same frozen operation retryable');
select pg_temp.pm_admit_ok(not exists(select 1 from public.credit_holds
  where request_key='photomotion:b0b00000-0000-4000-8000-000000000000')
  and not exists(select 1 from public.property_video_jobs
  where operation_id='b0b00000-0000-4000-8000-000000000000')
  and not exists(select 1 from public.property_video_refused_operations
  where operation_id='b0b00000-0000-4000-8000-000000000000'),
  'low balance cannot leave a partial hold or accepted job');
reset role;
-- Even when this same workspace owns a Production top-up, an authorized
-- internal TestFlight account with no Sandbox credits must stay in Sandbox.
update public.profiles set is_admin=true
 where id='b0111111-1111-4111-8111-111111111111';
update public.orgs set plan='team',plan_source='manual'
 where id='b0aaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
insert into public.org_internal_testing_grants(org_id,owner_user_id,
 unmetered_business_allowances) values(
 'b0aaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
 'b0111111-1111-4111-8111-111111111111',true);
set local role service_role;
select pg_temp.pm_admit_ok((select public.credit_photo_motion_environment(
  'b0111111-1111-4111-8111-111111111111',
  'b0aaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',manifest,39.3668)='Sandbox'
  from pm_admission_manifest),
  'exhausted QA wallet cannot silently fall through to Production credits');
select pg_temp.pm_admit_ok((select
  public.credit_photo_motion_review_quote(
    'b0111111-1111-4111-8111-111111111111',manifest)
      @> '{"mode":"credits","environment":"Sandbox","affordable":false,"available_credits":0}'::jsonb
  from pm_admission_manifest),
  'Review shows Sandbox zero balance instead of a Production debit');
reset role;
-- No purchased pack and no QA grant: a manual Pro workspace uses its plan.
-- The exact quote must stop claiming "included" when the monthly clip meter
-- cannot fit even this one-photo recipe. Review itself never closes the job.
update public.credit_grants set revoked_at=now()
  where reference='synthetic-pm-credit-topup';
update public.org_internal_testing_grants set revoked_at=now()
  where org_id='b0aaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
update public.profiles set is_admin=false
  where id='b0111111-1111-4111-8111-111111111111';
update public.orgs set plan='pro',plan_source='manual'
  where id='b0aaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
update pm_admission_manifest set manifest=jsonb_set(manifest,
  '{operation_id}','"b0c00000-0000-4000-8000-000000000000"'::jsonb);
set local role service_role;
select pg_temp.pm_admit_ok((select
  public.credit_photo_motion_environment(
    'b0111111-1111-4111-8111-111111111111',
    'b0aaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',manifest,39.3668) is null
  from pm_admission_manifest),
  'legacy plan without a credit pack keeps the original plan route');
select pg_temp.pm_admit_ok((select
  public.credit_photo_motion_review_quote(
    'b0111111-1111-4111-8111-111111111111',manifest)
      @> '{"mode":"plan","active":false}'::jsonb
  from pm_admission_manifest),
  'available plan recipe remains included at Review');
reset role;
insert into public.rate_limits(key,window_start,window_seconds,count)
  values('reelmo:b0aaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',now(),2592000,
    (select reels_per_month from public.plan_entitlements where plan='pro'))
  on conflict(key) do update set window_start=excluded.window_start,
    window_seconds=excluded.window_seconds,count=excluded.count;
set local role service_role;
select pg_temp.pm_admit_ok((select
  public.credit_photo_motion_review_quote(
    'b0111111-1111-4111-8111-111111111111',manifest)
      @> '{"mode":"plan","active":false,"affordable":false}'::jsonb
  from pm_admission_manifest),
  'exhausted plan Review no longer says included');
select pg_temp.pm_admit_ok(not exists(select 1 from public.property_video_jobs
  where operation_id='b0c00000-0000-4000-8000-000000000000')
  and not exists(select 1 from public.property_video_refused_operations
  where operation_id='b0c00000-0000-4000-8000-000000000000'),
  'read-only exhausted-plan Review leaves the operation retryable');
select jsonb_build_object('assertions',(select n from pm_admission_checks),'passed',true);
rollback;
