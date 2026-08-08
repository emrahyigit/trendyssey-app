begin;

-- Counting change, decided after watching real notifications: users experience
-- every 'failed' transition as an invalidation — including the ones that came
-- after a confirmation, because on short timeframes a confirmation that dies
-- two candles later is still a trap. So the earlier "first milestone wins"
-- reading is gone. From now on:
--
--   invalidated — the journey recorded a 'failed' event at any point
--   confirmed   — reached 'confirmed' and has never failed (still standing)
--   in progress — never failed, not confirmed yet
--
-- started = invalidated + confirmed + in_progress still holds, and the app's
-- success rate is simply the not-(yet)-failed share of started journeys.

create or replace function public.get_symbol_journey_stats(
  p_model_slug text,
  p_symbol text,
  p_timeframe text default '15m',
  p_lookback_days integer default 30
)
returns table (
  started_count integer,
  confirmed_count integer,
  invalidated_count integer,
  in_progress_count integer
)
language sql
stable
security definer
set search_path = public
as $$
with selected_model as (
  select id from public.analysis_models where slug = p_model_slug limit 1
),
selected_symbol as (
  select id from public.symbols where symbol = p_symbol limit 1
),
journey_events as (
  select event.journey_id, event.status, event.candle_close_time
  from public.signal_journey_events event
  join selected_model model on model.id = event.analysis_model_id
  join selected_symbol market on market.id = event.symbol_id
  where event.timeframe = p_timeframe
    and event.status in ('breakout_detected', 'confirmed', 'failed')
),
started_journeys as (
  select journey_id, min(candle_close_time) as started_at
  from journey_events
  where status = 'breakout_detected'
    and candle_close_time >= now() - make_interval(days => greatest(7, least(coalesce(p_lookback_days, 30), 365)))
  group by journey_id
),
journey_fates as (
  select
    started.journey_id,
    bool_or(milestone.status = 'confirmed') as ever_confirmed,
    bool_or(milestone.status = 'failed') as ever_failed
  from started_journeys started
  left join journey_events milestone
    on milestone.journey_id = started.journey_id
   and milestone.candle_close_time >= started.started_at
  group by started.journey_id
)
select
  count(*)::integer as started_count,
  count(*) filter (where not fate.ever_failed and fate.ever_confirmed)::integer as confirmed_count,
  count(*) filter (where fate.ever_failed)::integer as invalidated_count,
  count(*) filter (where not fate.ever_failed and not fate.ever_confirmed)::integer as in_progress_count
from journey_fates fate;
$$;

create or replace function public.get_journey_invalidation_stats(
  p_model_slug text,
  p_timeframe text default '15m',
  p_lookback_days integer default 30
)
returns table (
  symbol text,
  started_count integer,
  confirmed_count integer,
  invalidated_count integer,
  in_progress_count integer
)
language sql
stable
security definer
set search_path = public
as $$
with selected_model as (
  select id from public.analysis_models where slug = p_model_slug limit 1
),
journey_events as (
  select event.symbol_id, event.journey_id, event.status, event.candle_close_time
  from public.signal_journey_events event
  join selected_model model on model.id = event.analysis_model_id
  where event.timeframe = p_timeframe
    and event.status in ('breakout_detected', 'confirmed', 'failed')
),
started_journeys as (
  select symbol_id, journey_id, min(candle_close_time) as started_at
  from journey_events
  where status = 'breakout_detected'
    and candle_close_time >= now() - make_interval(days => greatest(7, least(coalesce(p_lookback_days, 30), 365)))
  group by symbol_id, journey_id
),
journey_fates as (
  select
    started.symbol_id,
    started.journey_id,
    bool_or(milestone.status = 'confirmed') as ever_confirmed,
    bool_or(milestone.status = 'failed') as ever_failed
  from started_journeys started
  left join journey_events milestone
    on milestone.symbol_id = started.symbol_id
   and milestone.journey_id = started.journey_id
   and milestone.candle_close_time >= started.started_at
  group by started.symbol_id, started.journey_id
)
select
  market.symbol,
  count(*)::integer as started_count,
  count(*) filter (where not fate.ever_failed and fate.ever_confirmed)::integer as confirmed_count,
  count(*) filter (where fate.ever_failed)::integer as invalidated_count,
  count(*) filter (where not fate.ever_failed and not fate.ever_confirmed)::integer as in_progress_count
from journey_fates fate
join public.symbols market on market.id = fate.symbol_id
group by market.symbol;
$$;

commit;

-- Verify (ACE should now read 8 started / 7 invalidated):
-- select * from public.get_symbol_journey_stats('donchian-20-v1', 'ACEUSDT', '15m', 30);
