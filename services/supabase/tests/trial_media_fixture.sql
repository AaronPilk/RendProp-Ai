-- Shared synthetic local media coverage for rollback-only trial fixtures.
-- No production account, provider call, or owner cash is created.
set local role service_role;
select public.provision_media_account_reserve(
 'synthetic-trial-media-account','9c332c75b96cc642621dad5d86d4bf18',
 'business_paid_cash',repeat('9',64),now()-interval '1 day',
 now()+interval '130 days',21000,
 '{"r2_a_cents_per_million":450,"r2_b_cents_per_million":36,"worker_cents_per_million":30,"worker_cpu_cents_per_million_ms":2,"edge_cents_per_million":200,"db_cents":100,"logs_cents":100,"storage_cents_per_gb_month":1.5}',
 '{"storage":0,"delivery":5000,"compute":5000,"email":0,"support":0,"retention":0,"uncertainty":0}');
reset role;
-- Historical trial runners stop before the media-template migration. Seed the
-- template only when that later schema is present; the account reserve above
-- still exercises the shared media fixture at either schema point.
do $$begin
 if to_regclass('public.subscription_trial_media_template') is not null then
  update public.subscription_trial_media_template set enabled=true,
   account_reserve_ref='synthetic-trial-media-account',request_limit=1000,
   byte_limit=1073741824,storage_limit=1342177280,
   evidence_sha256=repeat('8',64) where singleton;
 end if;
end$$;
