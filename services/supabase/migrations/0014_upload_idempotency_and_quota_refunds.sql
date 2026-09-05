-- 0014: upload-ticket idempotency + quota refunds (2026-09-04, audit F-E-06 / F-E-16).
--
-- Two money leaks that survived the earlier waves, both on the "the client
-- retried and the server treated it as a brand-new request" axis.
--
-- 1. F-E-06 (residual) — POST /uploads ignored `Idempotency-Key`.
--    The app has sent a STABLE key ("ticket:<sha256 of path>:<bytes>") since
--    fix wave 1, but the endpoint never read it: every retry of the same
--    logical ticket minted a NEW capture_assets row, a NEW R2 key and, for a
--    >64 MB video, a NEW multipart session — while charging the org's daily
--    ticket budget (2000/day) and byte budget (200 GB/day) again. Five PUT
--    failures on one walkthrough left five orphan rows, five abandoned
--    multipart sessions accruing R2 storage, and 5 x the declared bytes
--    charged against the workspace. `idem_key` gives the endpoint the same
--    replay lookup `create_render_job` has had since 0006.
--
--    Scope: (listing_id, idem_key) — the same shape as
--    `uq_render_jobs_idem` — and only while the asset is still IN FLIGHT
--    (`uploaded = false`). Once an upload completes, the key is free again:
--    the app's key is derived from the file path + size, so re-uploading a
--    re-rendered tour to the same path must not be permanently wedged by a
--    row that already finished. A replay therefore can never resurrect a
--    completed asset — /complete's own idempotent replay path (F-E-05) owns
--    that case.
--
-- 2. F-E-16 (residual) — a charged quota was never given back when the paid
--    provider call then failed. `guardEdit`/`guardGenerate` bump the monthly
--    meter immediately before calling Gemini / fal; a 502 from the provider
--    left the counter incremented, so an org lost an AI photo edit (or a
--    $3.60 Topaz allowance) for a request that produced nothing. refund_rate()
--    is the exact inverse of bump_rate(): it subtracts within the CURRENT
--    window only and floors at zero, so it can neither create free allowance
--    in a later window nor be replayed into a negative counter.
--
-- Both are service-role only, like every other counter RPC.

-- ── 1. Upload-ticket idempotency ────────────────────────────────────────────

alter table public.capture_assets add column if not exists idem_key text;

comment on column public.capture_assets.idem_key is
  'Client Idempotency-Key for POST /uploads. A retry with the same key and the '
  'same (bytes, kind, bucket) replays the SAME ticket instead of minting a new '
  'asset row and re-charging the org daily upload budget (audit F-E-06).';

-- Unique only while the upload is still in flight (see the note above).
create unique index if not exists uq_capture_assets_idem
  on public.capture_assets (listing_id, idem_key)
  where idem_key is not null and uploaded = false;

-- ── 2. refund_rate(): give back a counted unit inside its own window ─────────

create or replace function public.refund_rate(
  p_key text,
  p_window_seconds integer,
  p_cost integer default 1
) returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare
  v_cost integer := greatest(1, coalesce(p_cost, 1));
  v_refunded boolean := false;
begin
  -- Only refund inside the window the charge belongs to. If the window has
  -- already rolled over, the charge is gone from the counter anyway and
  -- subtracting would hand out free allowance in the NEW window.
  update rate_limits r
     set count = greatest(0, r.count - v_cost)
   where r.key = p_key
     and r.window_start >= now() - make_interval(secs => coalesce(p_window_seconds, 0))
  returning true into v_refunded;

  return coalesce(v_refunded, false);
end;
$$;

revoke execute on function public.refund_rate(text, integer, integer) from public, anon, authenticated;
grant  execute on function public.refund_rate(text, integer, integer) to service_role;

comment on function public.refund_rate(text, integer, integer) is
  'Inverse of bump_rate() for a charge whose paid provider call then failed '
  '(audit F-E-16). Floors at zero and refuses to cross a window boundary.';
