begin;

-- The push filter now judges every coin exactly like the scenario page:
-- success = reached 'confirmed' and never failed, invalidated = ever failed
-- (same fates as get_journey_invalidation_stats), and the per-coin rate is
-- shrunk toward the market average with 4 pseudo-observations (empirical
-- Bayes). One lucky breakout cannot print 100%, one failure cannot print 0%,
-- and a coin with no history scores the market average instead of a free
-- pass. The function always returns a value now — the old "null under 4
-- samples means pass" loophole is gone; whoever wants no filter sets their
-- minimum to 0.
create or replace function public.symbol_success_rate(
  p_model_id uuid,
  p_symbol_id uuid,
  p_timeframe text
) returns integer
language sql
stable
security definer
set search_path = public
as $$
with events as (
  select symbol_id, journey_id, status, candle_close_time
  from public.signal_journey_events
  where analysis_model_id = p_model_id
    and timeframe = p_timeframe
    and status in ('breakout_detected', 'confirmed', 'failed')
),
started as (
  select symbol_id, journey_id, min(candle_close_time) as started_at
  from events
  where status = 'breakout_detected'
    and candle_close_time >= now() - interval '30 days'
  group by symbol_id, journey_id
),
fates as (
  select s.symbol_id,
         bool_or(e.status = 'confirmed') as ever_confirmed,
         bool_or(e.status = 'failed') as ever_failed
  from started s
  left join events e
    on e.symbol_id = s.symbol_id
   and e.journey_id = s.journey_id
   and e.candle_close_time >= s.started_at
  group by s.symbol_id, s.journey_id
),
per_symbol as (
  select symbol_id,
         count(*) filter (where not ever_failed and ever_confirmed) as confirmed,
         count(*) filter (where ever_failed) as invalidated
  from fates
  group by symbol_id
),
market as (
  select coalesce(sum(confirmed), 0)::numeric as confirmed,
         coalesce(sum(confirmed + invalidated), 0)::numeric as resolved
  from per_symbol
),
coin as (
  select coalesce(max(confirmed), 0)::numeric as confirmed,
         coalesce(max(confirmed + invalidated), 0)::numeric as resolved
  from per_symbol
  where symbol_id = p_symbol_id
)
select round(
  100.0 * (coin.confirmed + 4 * (case when market.resolved > 0
                                      then market.confirmed / market.resolved
                                      else 0.5 end))
        / (coin.resolved + 4)
)::integer
from coin, market;
$$;

revoke all on function public.symbol_success_rate(uuid, uuid, text) from public;

commit;
