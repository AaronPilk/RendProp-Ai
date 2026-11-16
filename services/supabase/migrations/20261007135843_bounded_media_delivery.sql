begin;
-- No budget, tariff, funding, cleanup schedule or customer object is seeded.
-- One immutable budget covers the complete service+retention period. Reads
-- spend before dispatch; ambiguity/cancellation never refunds or renews it.
create table if not exists public.media_delivery_budgets(
 id uuid primary key default gen_random_uuid(), org_id uuid not null,
 receipt_ref text not null unique check(length(receipt_ref) between 8 and 200),
 funding_id uuid unique references public.serving_funding(id),
 starts_at timestamptz not null,ends_at timestamptz not null,
 request_limit bigint not null check(request_limit between 1 and 10000000),
 byte_limit bigint not null check(byte_limit between 1 and 10995116277760),
 storage_limit bigint not null check(storage_limit between 1 and 1099511627776),
 used_requests bigint not null default 0 check(used_requests between 0 and request_limit),
 used_bytes bigint not null default 0 check(used_bytes between 0 and byte_limit),
 tariff jsonb not null,reserves jsonb not null,evidence_sha256 text not null check(evidence_sha256~'^[a-f0-9]{64}$'),
 created_at timestamptz not null default now(),
 check(ends_at>starts_at and ends_at<=starts_at+interval '466 days')
);
create index if not exists media_delivery_budget_current on public.media_delivery_budgets(org_id,starts_at,ends_at);
-- This is a liability journal, not a reference counter: a metadata deletion or
-- failed/uncertain PUT cannot release physical storage. Only an acknowledged,
-- exact deletion can mark a receipt released. No deletion is authorized here.
create table if not exists public.media_storage_receipts(
 org_id uuid not null,bucket text not null check(bucket in('uploads','renders')),
 object_key text not null,bytes bigint not null check(bytes between 1 and 12884901888),
 created_at timestamptz not null default now(),deleted_at timestamptz,deletion_evidence_sha256 text,
 primary key(bucket,object_key),check((deleted_at is null and deletion_evidence_sha256 is null)or
 (deleted_at is not null and deletion_evidence_sha256~'^[a-f0-9]{64}$'))
);
create index if not exists media_storage_receipts_org on public.media_storage_receipts(org_id)where deleted_at is null;
alter table public.media_delivery_budgets enable row level security;
alter table public.media_storage_receipts enable row level security;
revoke all on public.media_delivery_budgets,public.media_storage_receipts from public,anon,authenticated,service_role;
grant select on public.media_delivery_budgets,public.media_storage_receipts to service_role;

create or replace function public.provision_media_delivery_budget(p_org uuid,p_ref text,p_funding uuid,
 p_start timestamptz,p_end timestamptz,p_requests bigint,p_bytes bigint,p_storage bigint,
 p_tariff jsonb,p_reserves jsonb,p_evidence text)returns jsonb
language plpgsql security definer set search_path='' as $$
declare old public.media_delivery_budgets; f public.serving_funding; k text; n numeric;
 delivery numeric;compute numeric;storage numeric;storage_liability numeric;budget_id uuid;
begin
 if current_setting('role',true)is distinct from 'service_role'then raise insufficient_privilege;end if;
 if p_org is null or p_ref is null or length(p_ref)not between 8 and 200 or p_evidence is null or p_evidence!~'^[a-f0-9]{64}$'
  or p_start is null or p_end is null or not isfinite(p_start)or not isfinite(p_end)or p_start>now()+interval '5 minutes'
  or p_end<=now()or p_end<=p_start or p_end>p_start+interval '466 days'
  or p_requests is null or p_requests not between 1 and 10000000
  or p_bytes is null or p_bytes not between 1 and 10995116277760
  or p_storage is null or p_storage not between 1 and 1099511627776
  or jsonb_typeof(p_tariff)is distinct from 'object'or jsonb_typeof(p_reserves)is distinct from 'object'then
  raise exception 'RP400: Exact bounded media liability and supplier evidence required';end if;
 -- These are worst-case rates, without allocating free tiers. Invoice/plan
 -- evidence must cover DB compute and logs; a low average is not authority.
 foreach k in array array['r2_a_cents_per_million','r2_b_cents_per_million','worker_cents_per_million','worker_cpu_cents_per_million_ms','edge_cents_per_million','db_cents','logs_cents','storage_cents_per_gb_month']loop
  if jsonb_typeof(p_tariff->k)is distinct from 'number'then raise exception 'RP400: Complete media tariff required';end if;
  n:=(p_tariff->>k)::numeric;if n<0 or n>1000000000 then raise exception 'RP400: Invalid media tariff';end if;
 end loop;
 if(select count(*)from jsonb_object_keys(p_tariff))<>8 or(p_tariff->>'r2_a_cents_per_million')::numeric<450 or(p_tariff->>'r2_b_cents_per_million')::numeric<36
  or(p_tariff->>'worker_cents_per_million')::numeric<30 or(p_tariff->>'worker_cpu_cents_per_million_ms')::numeric<2
  or(p_tariff->>'edge_cents_per_million')::numeric<200 or(p_tariff->>'db_cents')::numeric<=0
  or(p_tariff->>'storage_cents_per_gb_month')::numeric<1.5 then raise exception 'RP400: Supplier floor and fixed compute reserve required';end if;
 foreach k in array array['delivery','compute','storage','retention']loop
  if jsonb_typeof(p_reserves->k)is distinct from 'number'then raise exception 'RP400: Complete media reserves required';end if;
  n:=(p_reserves->>k)::numeric;if n<0 or n<>trunc(n)or n>1000000000 then raise exception 'RP400: Integer media reserves required';end if;
 end loop;
 if(select count(*)from jsonb_object_keys(p_reserves))<>4 then raise exception 'RP400: Unknown media reserve';end if;
 -- Each charged authority request conservatively covers one Worker, four R2
 -- Class A writes, two Class B reads and one Edge invocation, even when it only validates/HEADs.
 -- Billable operation and GB-month rounding is included per budget.
 delivery:=ceil(p_requests::numeric/1000000)*(4*(p_tariff->>'r2_a_cents_per_million')::numeric+2*(p_tariff->>'r2_b_cents_per_million')::numeric+(p_tariff->>'worker_cents_per_million')::numeric);
 compute:=ceil(p_requests::numeric/1000000)*(p_tariff->>'edge_cents_per_million')::numeric+
  ceil(p_requests::numeric*1000/1000000)*(p_tariff->>'worker_cpu_cents_per_million_ms')::numeric+
  (p_tariff->>'db_cents')::numeric+(p_tariff->>'logs_cents')::numeric;
 storage:=ceil(p_storage::numeric/1000000000)*ceil(extract(epoch from(p_end-p_start))/2592000)*(p_tariff->>'storage_cents_per_gb_month')::numeric;
 if(p_reserves->>'delivery')::numeric<ceil(delivery)or(p_reserves->>'compute')::numeric<ceil(compute)
  or(p_reserves->>'storage')::numeric+(p_reserves->>'retention')::numeric<ceil(storage)then raise exception 'RP402: Media reserves do not cover the complete bounded period';end if;
 perform 1 from public.orgs where id=p_org and deleted_at is null for update;
 if not found then raise exception 'RP403: Current workspace required';end if;
 perform pg_advisory_xact_lock(hashtextextended('media-budget:'||p_org,72453));
 -- Rollover/read-only budgets still owe every unreleased physical byte.
 -- Lock the current receipts under the same org/advisory order as writes.
 select coalesce(sum(bytes),0)into storage_liability from
  (select bytes from public.media_storage_receipts where org_id=p_org and deleted_at is null for update) current_receipts;
 if storage_liability>p_storage then raise exception 'RP402: Media storage budget is below retained physical liability';end if;
 select * into old from public.media_delivery_budgets where receipt_ref=p_ref;
 if found then
  if row(old.org_id,old.funding_id,old.starts_at,old.ends_at,old.request_limit,old.byte_limit,old.storage_limit,old.tariff,old.reserves,old.evidence_sha256)
   is distinct from row(p_org,p_funding,p_start,p_end,p_requests,p_bytes,p_storage,p_tariff,p_reserves,p_evidence)then raise exception 'RP409: Media budget receipt is immutable';end if;
  return jsonb_build_object('ok',true,'id',old.id,'replay',true);end if;
 if exists(select 1 from public.media_delivery_budgets where org_id=p_org and starts_at<p_end and ends_at>p_start and(p_funding is null or funding_id is null))then raise exception 'RP409: Media periods cannot overlap or reset';end if;
 if p_funding is not null then
  select * into f from public.serving_funding where id=p_funding and org_id=p_org and revoked_at is null for update;
  if not found or p_start is distinct from f.starts_at or p_end is distinct from f.retention_ends_at or
   (p_reserves->>'delivery')::numeric>(f.reserve_components->>'delivery')::numeric or
   (p_reserves->>'compute')::numeric>(f.reserve_components->>'compute')::numeric or
   (p_reserves->>'storage')::numeric>(f.reserve_components->>'storage')::numeric or
   (p_reserves->>'retention')::numeric>(f.reserve_components->>'retention')::numeric then raise exception 'RP402: Verified funding does not cover media reserves';end if;
 elsif exists(select 1 from public.serving_funding where org_id=p_org)then
  raise exception 'RP402: Funded workspaces require their exact financial receipt';
 end if;
 -- Legacy tester budgets are explicit operator-sponsored liabilities. The
 -- service-only RPC does not mint financial funding or activate a trial.
 insert into public.media_delivery_budgets(org_id,receipt_ref,funding_id,starts_at,ends_at,request_limit,byte_limit,storage_limit,tariff,reserves,evidence_sha256)
 values(p_org,p_ref,p_funding,p_start,p_end,p_requests,p_bytes,p_storage,p_tariff,p_reserves,p_evidence)returning media_delivery_budgets.id into budget_id;
 return jsonb_build_object('ok',true,'id',budget_id,'replay',false);
end$$;

create or replace function public.media_delivery_admit(p_org uuid,p_bytes bigint,p_required boolean default true)returns jsonb
language plpgsql security definer set search_path='' as $$
declare b public.media_delivery_budgets;
begin
 if current_setting('role',true)is distinct from 'service_role'then raise insufficient_privilege;end if;
 if p_org is null or p_bytes is null or p_bytes not between 0 and 268435456 or p_required is null then raise exception 'RP400: Invalid media admission';end if;
 perform 1 from public.orgs where id=p_org and deleted_at is null for update;
 if not found then raise exception 'RP404: Workspace unavailable';end if;
 perform pg_advisory_xact_lock(hashtextextended('media-budget:'||p_org,72453));
 select * into b from public.media_delivery_budgets where org_id=p_org and starts_at<=now()and ends_at>now()order by starts_at desc,id limit 1 for update;
 if not found then
  if not p_required and not exists(select 1 from public.serving_funding where org_id=p_org)then return jsonb_build_object('admitted',true,'legacy_unbudgeted',true);end if;
  raise exception 'RP503: Bounded media service activation pending';end if;
 if b.funding_id is not null and not exists(select 1 from public.serving_funding where id=b.funding_id and org_id=p_org and revoked_at is null and retention_ends_at>now())then raise exception 'RP404: Media funding unavailable';end if;
 if b.used_requests>=b.request_limit or p_bytes>b.byte_limit-b.used_bytes then raise exception 'RP429: Media serving allowance exhausted';end if;
 update public.media_delivery_budgets set used_requests=used_requests+1,used_bytes=used_bytes+p_bytes where id=b.id;
 return jsonb_build_object('admitted',true,'legacy_unbudgeted',false);
end$$;

-- Recovery/complete reads resolve the server-held upload org. Clients cannot
-- choose a cheap/legacy org while replaying multipart or object HEAD requests.
create or replace function public.media_upload_read_admit(p_asset uuid)returns jsonb
language plpgsql security definer set search_path='' as $$declare org uuid;begin
 if current_setting('role',true)is distinct from 'service_role'then raise insufficient_privilege;end if;
 select r.org_id into org from public.upload_reservations r join public.capture_assets a on a.id=r.asset_id
 join public.listings l on l.id=a.listing_id and l.org_id=r.org_id where r.asset_id=p_asset and l.deleted_at is null;
 if org is null then raise exception 'RP404: Upload media unavailable';end if;
 return public.media_delivery_admit(org,0,false);
end$$;
create or replace function public.media_storage_reserve(p_org uuid,p_bucket text,p_key text,p_bytes bigint)returns jsonb
language plpgsql security definer set search_path='' as $$
declare prior public.media_storage_receipts;b public.media_delivery_budgets;used numeric;k text;listing uuid;
begin
 if current_setting('role',true)is distinct from 'service_role'and pg_trigger_depth()=0 then raise insufficient_privilege;end if;
 if p_org is null or p_bucket is null or p_bucket not in('uploads','renders')or p_key is null or length(p_key)not between 1 and 4096
  or p_key~'[[:cntrl:]\\%?#]'or p_key~'(^|/)\.\.?(/|$)'or p_bytes is null or p_bytes not between 1 and 12884901888 then raise exception 'RP400: Invalid stored media receipt';end if;
 perform 1 from public.orgs where id=p_org and deleted_at is null for update;
 if not found then raise exception 'RP403: Current storage workspace required';end if;
 perform pg_advisory_xact_lock(hashtextextended('media-budget:'||p_org,72453));
 k:=case when p_key like '_staging/%' then substr(p_key,10)else p_key end;
 if not ((p_bucket='uploads'and(split_part(k,'/',1)in('uploads','studio-project','ai-voice','presenter-private'))or
  p_bucket='renders'and split_part(k,'/',1)in('renders','ai-router','presenter-private','video-reflections'))and split_part(k,'/',2)=p_org::text)then
  -- Published Python renders retain their existing renders/<listing>/<render>
  -- namespace. Resolve the complete listing owner; do not rewrite tester URLs.
  if p_bucket<>'renders'or split_part(k,'/',1)<>'renders'or split_part(k,'/',2)!~'^[a-f0-9]{8}(-[a-f0-9]{4}){3}-[a-f0-9]{12}$'then raise exception 'RP403: Exact owned storage namespace required';end if;
  listing:=split_part(k,'/',2)::uuid;
  perform 1 from public.listings where id=listing and org_id=p_org and deleted_at is null for share;
  if not found then raise exception 'RP403: Exact owned render listing required';end if;
 end if;
 select * into b from public.media_delivery_budgets where org_id=p_org and starts_at<=now()and ends_at>now()order by starts_at desc,id limit 1 for update;
 if not found then
  if exists(select 1 from public.serving_funding where org_id=p_org)then raise exception 'RP503: Bounded media storage activation pending';end if;
 elsif b.funding_id is not null and not exists(select 1 from public.serving_funding where id=b.funding_id and org_id=p_org and revoked_at is null and retention_ends_at>now())then raise exception 'RP403: Current media storage funding required';end if;
 -- Each reserve, including replay, spends one request before a possible PUT.
 -- No missing response or repeated exact key restores the write allowance.
 if b.id is not null then
  if b.used_requests>=b.request_limit then raise exception 'RP429: Media write request allowance exhausted';end if;
  update public.media_delivery_budgets set used_requests=used_requests+1 where id=b.id;
 end if;
 select * into prior from public.media_storage_receipts where bucket=p_bucket and object_key=p_key;
 if found then
  if row(prior.org_id,prior.bytes)is distinct from row(p_org,p_bytes)or prior.deleted_at is not null then raise exception 'RP409: Stored media receipt is immutable';end if;
  return jsonb_build_object('reserved',true,'replay',true);end if;
 if b.funding_id is not null and not exists(select 1 from public.serving_funding where id=b.funding_id and org_id=p_org and revoked_at is null and ends_at>now())then raise exception 'RP403: Current media write funding required';end if;
 -- Physical liability survives budget rollover and metadata/account deletion.
 select coalesce(sum(bytes),0)into used from public.media_storage_receipts where org_id=p_org and deleted_at is null;
 if b.id is not null and p_bytes>b.storage_limit-used then raise exception 'RP429: Stored media allowance exhausted';end if;
 insert into public.media_storage_receipts(org_id,bucket,object_key,bytes)values(p_org,p_bucket,p_key,p_bytes);
 return jsonb_build_object('reserved',true,'replay',false,'legacy_unbudgeted',b.id is null);
end$$;
create or replace function public.media_storage_deletion_ack(p_org uuid,p_bucket text,p_key text,p_evidence text)returns jsonb
language plpgsql security definer set search_path='' as $$
declare prior public.media_storage_receipts;
begin
 if current_setting('role',true)is distinct from 'service_role'then raise insufficient_privilege;end if;
 if p_org is null or p_bucket is null or p_key is null or p_evidence is null or p_evidence!~'^[a-f0-9]{64}$'then raise exception 'RP400: Exact storage deletion acknowledgement required';end if;
 perform pg_advisory_xact_lock(hashtextextended('media-budget:'||p_org,72453));
 select * into prior from public.media_storage_receipts where org_id=p_org and bucket=p_bucket and object_key=p_key for update;
 if not found then raise exception 'RP404: Exact owned storage receipt required';end if;
 if prior.deletion_evidence_sha256 is not null and prior.deletion_evidence_sha256<>p_evidence then raise exception 'RP409: Storage deletion acknowledgement is immutable';end if;
 update public.media_storage_receipts set deleted_at=coalesce(deleted_at,now()),deletion_evidence_sha256=coalesce(deletion_evidence_sha256,p_evidence)
 where org_id=p_org and bucket=p_bucket and object_key=p_key;
 return jsonb_build_object('acknowledged',true);
end$$;

create or replace function public.media_storage_before_write()returns trigger
language plpgsql security definer set search_path='' as $$
declare org uuid;i integer;
begin
 if tg_table_name='private_ai_outputs'then
  if tg_op='UPDATE'and row(new.org_id,new.bucket,new.storage_key,new.bytes)is distinct from row(old.org_id,old.bucket,old.storage_key,old.bytes)then raise exception 'RP409: Stored output identity is immutable';end if;
  if tg_op='INSERT'then perform public.media_storage_reserve(new.org_id,new.bucket,new.storage_key,new.bytes);end if;
 elsif tg_table_name='upload_operations'then
  if tg_op='UPDATE'and row(new.asset_id,new.bucket,new.object_key,new.expected_bytes)is distinct from row(old.asset_id,old.bucket,old.object_key,old.expected_bytes)then raise exception 'RP409: Stored upload identity is immutable';end if;
  if tg_op='INSERT'or(tg_op='UPDATE'and new.state='dispatching'and old.state<>'dispatching')then
   -- cancel_legacy_upload records an already existing, uncertain object for
   -- cleanup only. It grants no write lease/PUT and must remain available
   -- without purchasing a new service budget. Existing storage liability is
   -- untouched; unmeasured legacy objects require physical inventory before
   -- any budget/cutover acceptance, never an inferred deletion/refund here.
   if new.state='uncertain'and new.bytes=0 and new.claim is not null and new.cleanup_after is not null and exists(
    select 1 from public.upload_reservations r join public.capture_assets a on a.id=r.asset_id
    where r.asset_id=new.asset_id and r.state='cancelled'and r.held_bytes=0 and r.spec->>'legacy_physical_bytes'='unknown'
     and a.transport_version=1 and not a.uploaded and a.bucket=new.bucket and new.expected_bytes=greatest(1,coalesce(a.bytes,1))
     and(new.kind='single'and a.upload_id is null and new.object_key='_staging/'||a.storage_key
      or new.kind='init'and a.upload_id is not null and new.object_key=a.storage_key))then return new;end if;
   select org_id into org from public.upload_reservations where asset_id=new.asset_id;
   if org is null then raise exception 'RP403: Registered upload owner required';end if;
   perform public.media_storage_reserve(org,new.bucket,new.object_key,new.expected_bytes);
  end if;
 elsif tg_table_name='studio_project_media'then
  if tg_op='UPDATE'and row(new.id,new.actor_id,new.org_id,new.bytes,new.sha256)is distinct from row(old.id,old.actor_id,old.org_id,old.bytes,old.sha256)then raise exception 'RP409: Stored project identity is immutable';end if;
  if tg_op='INSERT'then
   for i in 0..((new.bytes+8388607)/8388608)-1 loop
    perform public.media_storage_reserve(new.org_id,'uploads','studio-project/'||new.org_id||'/'||new.actor_id||'/'||new.id||'/'||i,least(8388608,new.bytes-i*8388608));
   end loop;
  end if;
 elsif tg_table_name='voice_storage_reservations'then
  if tg_op='UPDATE'and row(new.actor_id,new.org_id,new.storage_key)is distinct from row(old.actor_id,old.org_id,old.storage_key)then raise exception 'RP409: Narration storage identity is immutable';end if;
  if tg_op='INSERT'then perform public.media_storage_reserve(new.org_id,'uploads',new.storage_key,20971520);end if;
 elsif tg_table_name='video_erase_jobs'then
  if tg_op='UPDATE'and row(new.id,new.org_id)is distinct from row(old.id,old.org_id)then raise exception 'RP409: Reflection storage identity is immutable';end if;
  if tg_op='INSERT'then perform public.media_storage_reserve(new.org_id,'renders','video-reflections/'||new.org_id||'/'||new.id||'.mp4',104857600);end if;
 elsif tg_table_name='studio_presenter_jobs'then
  if tg_op='UPDATE'and row(new.org_id,new.output_key)is distinct from row(old.org_id,old.output_key)then raise exception 'RP409: Presenter storage identity is immutable';end if;
  if tg_op='INSERT'then perform public.media_storage_reserve(new.org_id,'uploads',new.output_key,50331648);end if;
 elsif tg_table_name='org_brand_assets'then
  if tg_op='UPDATE'and row(new.org_id,new.object_key,new.bytes)is distinct from row(old.org_id,old.object_key,old.bytes)then raise exception 'RP409: Logo storage identity is immutable';end if;
  if tg_op='INSERT'then perform public.media_storage_reserve(new.org_id,'renders',new.object_key,new.bytes);end if;
 else raise exception 'RP403: Unknown storage writer';end if;
 return new;
end$$;
drop trigger if exists media_storage_private_output on public.private_ai_outputs;
create trigger media_storage_private_output before insert or update of org_id,bucket,storage_key,bytes on public.private_ai_outputs for each row execute function public.media_storage_before_write();
drop trigger if exists media_storage_upload on public.upload_operations;
create trigger media_storage_upload before insert or update of asset_id,bucket,object_key,expected_bytes,state on public.upload_operations for each row execute function public.media_storage_before_write();
drop trigger if exists media_storage_project on public.studio_project_media;
create trigger media_storage_project before insert or update of id,actor_id,org_id,bytes,sha256 on public.studio_project_media for each row execute function public.media_storage_before_write();
drop trigger if exists media_storage_voice on public.voice_storage_reservations;
create trigger media_storage_voice before insert or update of actor_id,org_id,storage_key on public.voice_storage_reservations for each row execute function public.media_storage_before_write();
drop trigger if exists media_storage_erase on public.video_erase_jobs;
create trigger media_storage_erase before insert or update of id,org_id on public.video_erase_jobs for each row execute function public.media_storage_before_write();
drop trigger if exists media_storage_presenter on public.studio_presenter_jobs;
create trigger media_storage_presenter before insert or update of org_id,output_key on public.studio_presenter_jobs for each row execute function public.media_storage_before_write();
drop trigger if exists media_storage_logo on public.org_brand_assets;
create trigger media_storage_logo before insert or update of org_id,object_key,bytes on public.org_brand_assets for each row execute function public.media_storage_before_write();
revoke all on function public.provision_media_delivery_budget(uuid,text,uuid,timestamptz,timestamptz,bigint,bigint,bigint,jsonb,jsonb,text),public.media_delivery_admit(uuid,bigint,boolean),public.media_upload_read_admit(uuid),public.media_storage_reserve(uuid,text,text,bigint),public.media_storage_before_write(),public.media_storage_deletion_ack(uuid,text,text,text)from public,anon,authenticated;
grant execute on function public.provision_media_delivery_budget(uuid,text,uuid,timestamptz,timestamptz,bigint,bigint,bigint,jsonb,jsonb,text),public.media_delivery_admit(uuid,bigint,boolean),public.media_upload_read_admit(uuid),public.media_storage_reserve(uuid,text,text,bigint),public.media_storage_deletion_ack(uuid,text,text,text)to service_role;
commit;
