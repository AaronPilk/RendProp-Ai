-- 0004: durable rate limiting for the PUBLIC endpoints (leads, beacon).
--
-- The in-memory limiter in _shared/http.ts resets whenever an edge-function
-- instance recycles, so a patient bot could spray leads across instances.
-- bump_rate() is an atomic fixed-window counter in Postgres: one row per key,
-- upserted under the row lock, so it is correct under concurrency and shared
-- by every function instance.
--
-- Service-role only: RLS is enabled with no policies, and EXECUTE is granted
-- only to service_role. (Edge functions call it through adminClient().rpc.)

create table if not exists public.rate_limits (
  key          text primary key,
  window_start timestamptz not null,
  count        integer not null
);

alter table public.rate_limits enable row level security;  -- no policies: admin-only

create or replace function public.bump_rate(
  p_key text,
  p_window_seconds integer,
  p_max integer
) returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare
  allowed boolean;
begin
  insert into rate_limits as r (key, window_start, count)
  values (p_key, now(), 1)
  on conflict (key) do update set
    count = case
      when r.window_start < now() - make_interval(secs => p_window_seconds) then 1
      else r.count + 1
    end,
    window_start = case
      when r.window_start < now() - make_interval(secs => p_window_seconds) then now()
      else r.window_start
    end
  returning count <= p_max into allowed;

  -- Opportunistic cleanup (~1% of calls) so stale IP keys don't accumulate.
  if random() < 0.01 then
    delete from rate_limits where window_start < now() - interval '1 day';
  end if;

  return allowed;
end;
$$;

revoke execute on function public.bump_rate(text, integer, integer) from public, anon, authenticated;
grant  execute on function public.bump_rate(text, integer, integer) to service_role;
