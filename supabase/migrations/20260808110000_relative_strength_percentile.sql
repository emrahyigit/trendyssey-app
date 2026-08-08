begin;

-- Relative strength, stage two. The first cut mapped the excess return to
-- 0-100 with fixed thresholds, which saturated pumping coins at 100 and wore
-- 50 as both "neutral" and "unmeasured". The corrected design:
--
--   scalar    — breakout_signals.relative_strength_raw: the coin's ~24h excess
--               log return vs BTC, written by every scan. Signed; exactly 0
--               for BTC itself and for a coin moving one-to-one with it.
--   percentile — relative_strength_score becomes the scalar's percent rank
--               across the freshest scalar per symbol on that timeframe,
--               recomputed by refresh_relative_strength() after each scan.
--               "80" now literally means "stronger than 80% of the universe".

alter table public.breakout_signals
  add column if not exists relative_strength_raw double precision;

comment on column public.breakout_signals.relative_strength_raw is
  'Excess log return vs BTC over ~24h of candles. 0 = moved with BTC (BTC itself scores 0). Ranked into relative_strength_score by refresh_relative_strength().';

comment on column public.breakout_signals.relative_strength_score is
  '0-100 percent rank of relative_strength_raw across the scanned universe on this timeframe. Null until the symbol''s first scored scan.';

alter table public.signal_journey_events
  add column if not exists relative_strength_raw double precision;

comment on column public.signal_journey_events.relative_strength_raw is
  'The signal''s relative_strength_raw when the event was recorded.';

-- Same function as 20260808090000, additionally carrying the raw scalar.
create or replace function public.record_signal_journey_event()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  event_id uuid;
  horizon smallint;
  candle_interval interval;
begin
  if tg_op = 'UPDATE'
    and old.status is not distinct from new.status
    and old.journey_id is not distinct from new.journey_id then
    return new;
  end if;

  insert into public.signal_journey_events(
    analysis_model_id, journey_id, breakout_signal_id, symbol_id, timeframe,
    status, candle_close_time, price, breakout_level, confidence,
    false_breakout_risk, volume_ratio,
    regime_score, readiness_score, breakout_quality_score,
    confirmation_score, relative_strength_score, relative_strength_raw,
    breakout_triggered, scoring_version, quote_volume_24h
  ) values (
    new.analysis_model_id, new.journey_id, new.id, new.symbol_id, new.timeframe,
    new.status, new.candle_close_time, new.signal_price, new.breakout_level,
    new.breakout_confidence_score, new.false_breakout_risk, new.volume_ratio,
    new.regime_score, new.readiness_score, new.breakout_quality_score,
    new.confirmation_score, new.relative_strength_score, new.relative_strength_raw,
    new.breakout_triggered, new.scoring_version,
    (select s.quote_volume_24h from public.symbols s where s.id = new.symbol_id)
  )
  on conflict (breakout_signal_id, journey_id, status, candle_close_time) do nothing
  returning id into event_id;

  if event_id is not null and new.status = 'breakout_detected' then
    candle_interval := case new.timeframe
      when '15m' then interval '15 minutes'
      when '30m' then interval '30 minutes'
      when '1h' then interval '1 hour'
      when '2h' then interval '2 hours'
      when '4h' then interval '4 hours'
      when '6h' then interval '6 hours'
      when '1d' then interval '1 day'
      else interval '15 minutes'
    end;

    foreach horizon in array array[1, 4, 12]::smallint[] loop
      insert into public.signal_outcome_snapshots(
        analysis_model_id, journey_id, breakout_signal_id, origin_event_id,
        symbol_id, timeframe, horizon_candles, entry_price, entry_close_time,
        breakout_level, due_at
      ) values (
        new.analysis_model_id, new.journey_id, new.id, event_id,
        new.symbol_id, new.timeframe, horizon, new.signal_price,
        new.candle_close_time, new.breakout_level,
        new.candle_close_time + candle_interval * horizon
      )
      on conflict (journey_id, horizon_candles) do nothing;
    end loop;
  end if;
  return new;
end;
$$;

-- Ranks the freshest scalar per symbol into a 0-100 percentile and stamps it
-- on every current row of the timeframe. Called by scan-market after each
-- batch; running it several times in a row is harmless. Stale symbols (no
-- scan within a few candles) drop out of the ranking instead of freezing it.
create or replace function public.refresh_relative_strength(p_timeframe text)
returns integer
language sql
security definer
set search_path = public
as $$
with fresh as (
  select distinct on (bs.symbol_id)
         bs.symbol_id, bs.relative_strength_raw
    from public.breakout_signals bs
   where bs.timeframe = p_timeframe
     and bs.relative_strength_raw is not null
     and bs.candle_close_time >= now() - (case p_timeframe
           when '15m' then interval '2 hours'
           when '1h' then interval '8 hours'
           when '4h' then interval '1 day'
           else interval '4 days'
         end)
   order by bs.symbol_id, bs.candle_close_time desc
),
ranked as (
  select symbol_id,
         round(100 * percent_rank() over (order by relative_strength_raw))::integer as pct
    from fresh
),
updated as (
  update public.breakout_signals bs
     set relative_strength_score = ranked.pct
    from ranked
   where bs.symbol_id = ranked.symbol_id
     and bs.timeframe = p_timeframe
     and bs.relative_strength_score is distinct from ranked.pct
  returning 1
)
select count(*)::integer from updated;
$$;

revoke all on function public.refresh_relative_strength(text) from public;

-- The linear-mapped scores from the first cut mean something different from
-- the percentile that replaces them; clear them so the next refresh rewrites
-- every row under one definition.
update public.breakout_signals set relative_strength_score = null
 where relative_strength_score is not null;

commit;

-- Verify (after the next scan):
-- select s.symbol, bs.relative_strength_raw, bs.relative_strength_score
--   from public.breakout_signals bs join public.symbols s on s.id = bs.symbol_id
--  where bs.timeframe = '15m' and s.symbol = 'BTCUSDT' limit 1;  -- raw ~0
