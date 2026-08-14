begin;

create table if not exists public.daily_predictions (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles(id) on delete cascade,
  symbol_id uuid not null references public.symbols(id) on delete cascade,
  prediction_day date not null default (timezone('UTC', now())::date),
  direction text not null check (direction in ('up', 'down')),
  entry_price numeric not null check (entry_price > 0),
  predicted_at timestamptz not null default now(),
  evaluation_ends_at timestamptz not null default (now() + interval '24 hours'),
  unique (user_id, symbol_id, prediction_day)
);

comment on table public.daily_predictions is
  'Immutable daily directional calls. Each call scores its first 24 hours and contributes at most +/-5 points.';

create index if not exists daily_predictions_user_day_idx
  on public.daily_predictions (user_id, prediction_day desc, predicted_at desc);
create index if not exists daily_predictions_symbol_end_idx
  on public.daily_predictions (symbol_id, evaluation_ends_at);

alter table public.daily_predictions enable row level security;
drop policy if exists daily_predictions_read_own on public.daily_predictions;
create policy daily_predictions_read_own
  on public.daily_predictions for select to authenticated
  using (user_id = auth.uid());
grant select on public.daily_predictions to authenticated;

-- The scorer freezes a call at the first closed 15m price at or after its
-- 24-hour deadline. Until then it follows the scanner's current symbol price.
-- Every call is independently capped to -5...+5, then added to the user's
-- default 100-point balance.
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
    select m.user_id, m.predicted_at,
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
         r.total_score, r.prediction_count, r.user_id = auth.uid()
  from ranked r
  where r.rank_position <= greatest(1, least(coalesce(p_limit, 10), 50))
     or r.user_id = auth.uid()
  order by r.rank_position;
$$;

revoke all on function public.get_daily_predictor_leaderboard(integer) from public;
grant execute on function public.get_daily_predictor_leaderboard(integer) to authenticated;

create or replace function public.get_predictor_daily_calls(
  p_user_id uuid,
  p_day date default (timezone('UTC', now())::date)
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
  with marked as (
    select d.id, s.symbol, d.direction, d.entry_price,
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
      d.predicted_at, d.evaluation_ends_at
    from public.daily_predictions d
    join public.symbols s on s.id = d.symbol_id
    where d.user_id = p_user_id and d.prediction_day = p_day
  )
  select m.id, m.symbol, m.direction, m.entry_price, m.mark_price,
    round(((m.mark_price / m.entry_price) - 1) * 100, 2),
    round(greatest(-5::numeric, least(5::numeric,
      ((m.mark_price / m.entry_price) - 1) * 100
      * case when m.direction = 'up' then 1 else -1 end
    )), 2),
    m.predicted_at, m.evaluation_ends_at, now() >= m.evaluation_ends_at
  from marked m
  order by m.predicted_at desc;
$$;

revoke all on function public.get_predictor_daily_calls(uuid, date) from public;
grant execute on function public.get_predictor_daily_calls(uuid, date) to authenticated;

-- The exact analyzed universe is the current 15m Market State universe, not a
-- second independently-maintained coin list.
create or replace function public.get_daily_prediction_symbols(
  p_limit integer default 100
)
returns table (
  symbol_id uuid,
  symbol text,
  current_price numeric,
  quote_volume_24h numeric
)
language sql
stable
security definer
set search_path = public
as $$
  with active_version as (
    select c.scoring_version
    from public.market_state_current c
    group by c.scoring_version
    order by max(c.updated_at) desc
    limit 1
  )
  select s.id, s.symbol, s.current_price, coalesce(s.quote_volume_24h, 0)
  from public.market_state_current c
  join active_version v on v.scoring_version = c.scoring_version
  join public.symbols s on s.id = c.symbol_id
  where c.timeframe = '15m' and s.is_enabled and s.current_price > 0
  order by coalesce(s.quote_volume_24h, 0) desc
  limit greatest(1, least(coalesce(p_limit, 100), 100));
$$;

revoke all on function public.get_daily_prediction_symbols(integer) from public;
grant execute on function public.get_daily_prediction_symbols(integer) to authenticated;

commit;
