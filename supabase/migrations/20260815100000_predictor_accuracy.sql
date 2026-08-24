-- The leaderboard reports points, which mix how often a predictor was right
-- with how far price ran. Accuracy answers the simpler question on its own:
-- of the calls in the window, how many are pointing the right way.
--
-- It counts calls that are still running, at their current standing, for the
-- same reason the points total does: a call cast this morning already moves
-- the score, so leaving it out of accuracy makes the two numbers contradict
-- each other. A running call can still flip before its 24 hours are up.
--
-- Accuracy is scored over a trailing 30 days rather than all time, so a good
-- month cannot be carried forever by an old streak. A trailing window is used
-- instead of the calendar month because the calendar version collapses to
-- "no resolved calls" every time the month rolls over.

begin;

drop function if exists public.get_daily_predictor_leaderboard(integer);

create function public.get_daily_predictor_leaderboard(
  p_limit integer default 10
)
returns table (
  rank_position integer,
  user_id uuid,
  display_name text,
  avatar_key text,
  total_score numeric,
  prediction_count integer,
  scored_count integer,
  correct_count integer,
  is_current_user boolean
)
language sql
stable
security definer
set search_path = public
as $$
  with participants as (
    select p.id, p.display_name, p.avatar_key
    from public.profiles p
    where p.id = auth.uid()
       or exists (select 1 from public.daily_predictions d where d.user_id = p.id)
  ), marked as (
    select d.user_id, d.predicted_at,
      now() >= d.evaluation_ends_at as is_resolved,
      d.predicted_at >= now() - interval '30 days' as in_accuracy_window,
      case
        when now() >= d.evaluation_ends_at then coalesce((
          select h.close_price
          from public.market_state_history h
          where h.symbol_id = d.symbol_id
            and h.timeframe = '15m'
            and h.candle_close_time >= d.evaluation_ends_at
            and h.close_price > 0
          order by h.candle_close_time asc, h.observed_at desc
          limit 1
        ), s.current_price, d.entry_price)
        else coalesce(s.current_price, d.entry_price)
      end as mark_price,
      d.entry_price,
      d.direction
    from public.daily_predictions d
    join public.symbols s on s.id = d.symbol_id
  ), contributions as (
    select m.user_id, m.predicted_at, m.is_resolved, m.in_accuracy_window,
      ((m.mark_price / m.entry_price) - 1) * 100
        * case when m.direction = 'up' then 1 else -1 end as raw_move,
      greatest(-5::numeric, least(5::numeric,
        ((m.mark_price / m.entry_price) - 1) * 100
        * case when m.direction = 'up' then 1 else -1 end
      )) as points
    from marked m
  ), totals as (
    select p.id as user_id,
      coalesce(nullif(p.display_name, ''), 'Trendyssey') as display_name,
      p.avatar_key,
      round(100 + coalesce(sum(c.points), 0), 2) as total_score,
      count(c.points)::integer as prediction_count,
      count(*) filter (where c.in_accuracy_window)::integer as scored_count,
      count(*) filter (where c.in_accuracy_window and c.raw_move > 0)::integer as correct_count,
      max(c.predicted_at) as last_prediction_at
    from participants p
    left join contributions c on c.user_id = p.id
    group by p.id, p.display_name, p.avatar_key
  ), ranked as (
    select row_number() over (
      order by t.total_score desc, t.prediction_count desc,
               t.last_prediction_at asc nulls last, t.user_id
    )::integer as rank_position,
      t.*
    from totals t
  )
  select r.rank_position, r.user_id, r.display_name, r.avatar_key,
         r.total_score, r.prediction_count, r.scored_count, r.correct_count,
         r.user_id = auth.uid()
  from ranked r
  where r.rank_position <= greatest(1, least(coalesce(p_limit, 10), 50))
     or r.user_id = auth.uid()
  order by r.rank_position;
$$;

revoke all on function public.get_daily_predictor_leaderboard(integer) from public;
grant execute on function public.get_daily_predictor_leaderboard(integer) to authenticated;

commit;
