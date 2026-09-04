-- 0013: the trial actually gets to try the AI (2026-09-04).
--
-- Two reasons, one of them urgent:
--
-- 1. PRODUCT. `trial` and `free` had aerials_per_month = 0 and topaz_per_month
--    = 0, so the two features that differentiate Rendprop — the grounded aerial
--    intro and the Cinematic/4K render tiers — were the exact two a new user
--    could never try. A trial that cannot exercise the flagship feature is not
--    a trial. The 7-day trial requires a card, so the exposure is bounded and
--    the abuse surface is small.
--
-- 2. APP REVIEW (Guideline 3.1.1). An App Store reviewer signs in with their own
--    Apple ID and lands on `trial`. With zero aerials they tap "Aerial intro",
--    get a 402, and see an "Upgrade plan" link out to the web — which is the
--    textbook "accesses digital content purchased outside the app" rejection.
--    With allowances instead of hard locks, the app reads as metered SaaS
--    (Guideline 3.1.3(f), companion to a paid web service) and the reviewer
--    never meets a paywall at all.
--
-- Exposure per trial org at the measured unit costs: 2 aerials (2 x $0.80) +
-- 1 Topaz ($3.60) = $5.20, under the $8.00 ceiling this sets. The per-org
-- monthly COGS ceiling in log_job_cost() remains the hard backstop.
--
-- rendprop.com/pricing is updated in the same commit so the published trial and
-- the enforced trial still match — tests/invariants.sql asserts that equality
-- and is the guard against the drift this project has had before.

update public.plan_entitlements
   set aerials_per_month  = 2,
       topaz_per_month    = 1,
       cogs_ceiling_cents = 800
 where plan in ('trial', 'free');
