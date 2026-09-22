-- Included by invariants.sql and its focused negative fixture. The caller owns
-- the temporary _inv table. Both checks MUST insert a result: bare SELECT only
-- prints a failure and cannot affect the final asserting gate.
insert into _inv(name, pass, note)
select 'all three explicit Astra writing seats keep their 0030/0034 paid-plan gates',
       count(*) = 3
   and count(*) filter (where task = 'copy.shotlist' and position = 1 and provider = 'openai'
                        and min_plan = 'starter') = 1
   and count(*) filter (where task = 'copy.reel_script' and position = 1 and provider = 'openai'
                        and min_plan = 'starter') = 1
   and count(*) filter (where task = 'copy.agent_reel' and position = 1 and provider = 'openai'
                        and min_plan = 'pro') = 1,
       coalesce(string_agg(format('%s/%s min_plan=%s', task, position, min_plan), ', '), 'no Astra rows')
from public.ai_routes
where model = 'gpt-6-astra';

insert into _inv(name, pass, note)
select 'no gpt-6-astra row is reachable on the free or trial tier',
       count(*) = 0,
       coalesce(string_agg(format('%s/%s min_plan=%s', task, position, min_plan), ', '), 'no free/trial Astra rows')
from public.ai_routes
where model = 'gpt-6-astra' and min_plan in ('free', 'trial');
