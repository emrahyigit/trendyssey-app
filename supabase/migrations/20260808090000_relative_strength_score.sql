begin;

-- Fifth score layer: relative strength — the coin's 24h-window excess return
-- against BTC, mapped to 0-100 (50 = moving with BTC). Validated on 30 days of
-- 15m breakouts: positive-excess entries hit +2% before -2% at 51-53% vs
-- 43-46% for negative-excess ones. Computed by scan-market from the candles it
-- already fetches; events inherit the value through the recording trigger, so
-- history stays immutable and replays see what was true at entry.

alter table public.breakout_signals
  add column if not exists relative_strength_score integer;

comment on column public.breakout_signals.relative_strength_score is
  '0-100. Excess log return vs BTC over ~24h of candles, 50 = neutral. Null when BTC candles were unavailable at scan time.';

alter table public.signal_journey_events
  add column if not exists relative_strength_score integer;

comment on column public.signal_journey_events.relative_strength_score is
  'The signal''s relative_strength_score when the event was recorded.';

-- Same function as 20260803090000, with the new column carried into events.
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
    confirmation_score, relative_strength_score,
    breakout_triggered, scoring_version, quote_volume_24h
  ) values (
    new.analysis_model_id, new.journey_id, new.id, new.symbol_id, new.timeframe,
    new.status, new.candle_close_time, new.signal_price, new.breakout_level,
    new.breakout_confidence_score, new.false_breakout_risk, new.volume_ratio,
    new.regime_score, new.readiness_score, new.breakout_quality_score,
    new.confirmation_score, new.relative_strength_score,
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

commit;

-- Verify (fills in as scans run after the function deploy):
-- select count(*) filter (where relative_strength_score is not null) scored, count(*) total
--   from public.breakout_signals;
