-- CLI scaffold: supabase migration new spatial_training_quality_limits.
-- 0055 is the owner-authorized next sequence; earlier migrations stay intact.
-- Admits the measured B/D candidate profile without selecting or enabling it.
-- Runtime values, budgets, reservations, lifetime, grants and RLS are unchanged.
alter table public.spatial_runtime
  drop constraint spatial_runtime_max_iterations_check,
  add constraint spatial_runtime_max_iterations_check
    check (max_iterations between 100 and 30000),
  drop constraint spatial_runtime_max_training_seconds_check,
  add constraint spatial_runtime_max_training_seconds_check
    check (max_training_seconds between 1 and 4200);
