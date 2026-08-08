begin;

-- The dashboard hides coins whose breakouts mostly trap: when more than half
-- of a coin's resolved journeys invalidated, it leaves Featured Breakouts and
-- Waiting for Breakout (it stays visible in search, watchlists and the
-- Misleader ranking, so the exclusion is observable, not silent).
--
-- One call returns every symbol's counts so the app filters lists locally
-- instead of asking per coin. Fate rules are identical to
-- get_symbol_journey_stats: first milestone wins — 'confirmed' before any
-- 'failed' counts as confirmed, 'failed' without a prior confirmation counts
-- as invalidated, neither means the journey is still open.
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
    min(milestone.candle_close_time) filter (where milestone.status = 'confirmed') as confirmed_at,
    min(milestone.candle_close_time) filter (where milestone.status = 'failed') as failed_at
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
from journey_fates fate
join public.symbols market on market.id = fate.symbol_id
group by market.symbol;
$$;

comment on function public.get_journey_invalidation_stats(text, text, integer) is
  'Per-symbol confirmed/invalidated journey counts for one model+timeframe, so the dashboard can hide coins whose breakouts mostly invalidate.';

revoke all on function public.get_journey_invalidation_stats(text, text, integer) from public;
grant execute on function public.get_journey_invalidation_stats(text, text, integer) to authenticated;

commit;

-- Verify:
-- select * from public.get_journey_invalidation_stats('donchian-20-v1', '15m', 30)
--  order by invalidated_count desc limit 20;
