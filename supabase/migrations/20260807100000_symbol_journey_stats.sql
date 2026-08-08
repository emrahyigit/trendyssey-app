begin;

-- Every signal detail page should answer "how often did this coin's breakouts
-- actually confirm?" — not only the top-20 extremes that the character
-- rankings surface. Same event log and the same journey definition as
-- get_market_character_rankings, restricted to a single symbol.
--
-- Fate of a journey, decided by which milestone came first:
--   confirmed   — reached 'confirmed' before any 'failed' (a later failure
--                 does not retract the confirmation the user acted on)
--   invalidated — reached 'failed' without ever confirming first
--   in progress — neither milestone recorded yet
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
    min(milestone.candle_close_time) filter (where milestone.status = 'confirmed') as confirmed_at,
    min(milestone.candle_close_time) filter (where milestone.status = 'failed') as failed_at
  from started_journeys started
  left join journey_events milestone
    on milestone.journey_id = started.journey_id
   and milestone.candle_close_time >= started.started_at
  group by started.journey_id
)
select
  count(*)::integer as started_count,
  count(*) filter (
    where fate.confirmed_at is not null
      and (fate.failed_at is null or fate.confirmed_at <= fate.failed_at)
  )::integer as confirmed_count,
  count(*) filter (
    where fate.failed_at is not null
      and (fate.confirmed_at is null or fate.failed_at < fate.confirmed_at)
  )::integer as invalidated_count,
  count(*) filter (
    where fate.confirmed_at is null and fate.failed_at is null
  )::integer as in_progress_count
from journey_fates fate;
$$;

comment on function public.get_symbol_journey_stats(text, text, text, integer) is
  'Confirmed vs invalidated breakout counts for one symbol/model/timeframe, so the signal detail page can set expectations from the same journey history the character rankings use.';

revoke all on function public.get_symbol_journey_stats(text, text, text, integer) from public;
grant execute on function public.get_symbol_journey_stats(text, text, text, integer) to authenticated;

commit;

-- Verify:
-- select * from public.get_symbol_journey_stats('<model-slug>', 'BTCUSDT', '15m', 30);
