begin;

-- Predictor leaderboard. Plain accuracy lets a lucky 1/1 outrank a proven
-- 9/10, so ranking uses the Wilson 95% lower bound of the accuracy instead —
-- the standard correction for small samples. At least 5 resolved predictions
-- to appear at all.
create or replace function public.get_top_predictors(p_limit integer default 10)
returns table (
  user_id uuid,
  display_name text,
  avatar_key text,
  resolved_count integer,
  correct_count integer,
  accuracy integer,
  skill numeric
)
language sql
stable
security definer
set search_path = public
as $$
select
  a.user_id,
  coalesce(nullif(p.display_name, ''), 'Trendyssey') as display_name,
  p.avatar_key,
  a.resolved_count::integer,
  a.correct_count::integer,
  round(100.0 * a.correct_count / a.resolved_count)::integer as accuracy,
  round((
    (a.correct_count::numeric / a.resolved_count + 1.9208 / a.resolved_count
      - 1.96 * sqrt((a.correct_count::numeric / a.resolved_count)
        * (1 - a.correct_count::numeric / a.resolved_count) / a.resolved_count
        + 0.9604 / (a.resolved_count * a.resolved_count)))
    / (1 + 3.8416 / a.resolved_count)
  ) * 100, 1) as skill
from public.prediction_accuracy a
join public.profiles p on p.id = a.user_id
where a.resolved_count >= 5
order by skill desc, a.resolved_count desc
limit greatest(1, least(coalesce(p_limit, 10), 50));
$$;

revoke all on function public.get_top_predictors(integer) from public;
grant execute on function public.get_top_predictors(integer) to authenticated;

commit;
