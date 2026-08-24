-- A call that has already earned the maximum banks it immediately.
--
-- Points are capped at +/-5, so once a call's favourable move touches +5% there
-- is nothing left to win by waiting — but under the old rule a coin could run
-- +5% by lunchtime, give it all back, and settle at zero. Now the best 15m
-- close inside the window is checked: if the move ever reached +5% the call
-- locks at +5 and stops tracking. Everything else still waits for its full 24
-- hours, so a call cannot lock in a loss early.
--
-- The best excursion is read from market_state_history, the same closed-candle
-- series the settlement price comes from. A coin outside the scanned universe
-- has no such series and simply never locks early.

begin;

create or replace function public.predictor_call_scores(p_user_id uuid default null)
returns table (
  id uuid,
  user_id uuid,
  symbol_id uuid,
  symbol text,
  direction text,
  entry_price numeric,
  mark_price numeric,
  points numeric,
  raw_move numeric,
  is_resolved boolean,
  locked_early boolean,
  prediction_day date,
  predicted_at timestamptz,
  evaluation_ends_at timestamptz
)
language sql
stable
security definer
set search_path = public
as $$
  with base as (
    select d.id, d.user_id, d.symbol_id, s.symbol, d.direction, d.entry_price,
           d.prediction_day, d.predicted_at, d.evaluation_ends_at,
           s.current_price,
           case when d.direction = 'up' then 1 else -1 end as sign,
           (select max(h.close_price) from public.market_state_history h
             where h.symbol_id = d.symbol_id and h.timeframe = '15m'
               and h.candle_close_time >= d.predicted_at
               and h.candle_close_time <= least(now(), d.evaluation_ends_at)
               and h.close_price > 0) as window_high,
           (select min(h.close_price) from public.market_state_history h
             where h.symbol_id = d.symbol_id and h.timeframe = '15m'
               and h.candle_close_time >= d.predicted_at
               and h.candle_close_time <= least(now(), d.evaluation_ends_at)
               and h.close_price > 0) as window_low,
           (select h.close_price from public.market_state_history h
             where h.symbol_id = d.symbol_id and h.timeframe = '15m'
               and h.candle_close_time >= d.evaluation_ends_at
               and h.close_price > 0
             order by h.candle_close_time asc, h.observed_at desc
             limit 1) as settlement_price
    from public.daily_predictions d
    join public.symbols s on s.id = d.symbol_id
    where p_user_id is null or d.user_id = p_user_id
  ), excursion as (
    select b.*,
      case when b.direction = 'up' then b.window_high else b.window_low end as best_price
    from base b
  ), scored as (
    select e.*,
      coalesce(((e.best_price / e.entry_price) - 1) * 100 * e.sign, -999) >= 5 as locked_early,
      case
        when now() >= e.evaluation_ends_at
          then coalesce(e.settlement_price, e.current_price, e.entry_price)
        else coalesce(e.current_price, e.entry_price)
      end as live_price
    from excursion e
  )
  select s.id, s.user_id, s.symbol_id, s.symbol, s.direction, s.entry_price,
    case when s.locked_early then s.best_price else s.live_price end,
    case
      when s.locked_early then 5::numeric
      else greatest(-5::numeric, least(5::numeric,
        ((s.live_price / s.entry_price) - 1) * 100 * s.sign))
    end,
    case
      when s.locked_early then ((s.best_price / s.entry_price) - 1) * 100 * s.sign
      else ((s.live_price / s.entry_price) - 1) * 100 * s.sign
    end,
    s.locked_early or now() >= s.evaluation_ends_at,
    s.locked_early,
    s.prediction_day, s.predicted_at, s.evaluation_ends_at
  from scored s;
$$;

revoke all on function public.predictor_call_scores(uuid) from public, anon;
grant execute on function public.predictor_call_scores(uuid) to authenticated;

create or replace function public.get_daily_predictor_leaderboard(
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
  ), contributions as (
    select c.user_id, c.predicted_at, c.points, c.raw_move,
           c.predicted_at >= now() - interval '30 days' as in_window
    from public.predictor_call_scores() c
  ), totals as (
    select p.id as user_id,
      coalesce(nullif(p.display_name, ''), 'Trendyssey') as display_name,
      p.avatar_key,
      round(100 + coalesce(sum(c.points), 0), 2) as total_score,
      count(c.points)::integer as prediction_count,
      count(*) filter (where c.in_window)::integer as scored_count,
      count(*) filter (where c.in_window and c.raw_move > 0)::integer as correct_count,
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

create or replace function public.get_predictor_daily_calls(
  p_user_id uuid,
  p_day date default (timezone('UTC', now()))::date
)
returns table (
  id uuid,
  symbol text,
  direction text,
  entry_price numeric,
  mark_price numeric,
  price_change_percent numeric,
  points numeric,
  predicted_at timestamptz,
  evaluation_ends_at timestamptz,
  is_resolved boolean
)
language sql
stable
security definer
set search_path = public
as $$
  select c.id, c.symbol, c.direction, c.entry_price, c.mark_price,
    round(((c.mark_price / c.entry_price) - 1) * 100, 2),
    round(c.points, 2),
    c.predicted_at, c.evaluation_ends_at, c.is_resolved
  from public.predictor_call_scores(p_user_id) c
  where c.prediction_day = p_day
  order by c.predicted_at desc;
$$;

revoke all on function public.get_predictor_daily_calls(uuid, date) from public;
grant execute on function public.get_predictor_daily_calls(uuid, date) to authenticated;

commit;
