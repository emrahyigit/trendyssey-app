begin;

-- Trend score — the Aug 2026 tournament winner (see _shared/trend_score.ts).
--
-- Seven entries x four exits were backtested on the top-100 universe across
-- all four timeframes with 0.2% round-trip fees. The strongest combination on
-- every timeframe: Donchian-55 breakout + EMA25>EMA99 regime + 20-candle
-- return beating BTC's, exited by a 3xATR chandelier trail. This migration
-- stores that model's 0-100 score and its A+ entry flag alongside the
-- existing scores; the jsonb facts carry the component breakdown.

alter table public.breakout_signals
  add column if not exists trend_score smallint,
  add column if not exists trend_entry boolean not null default false;

comment on column public.breakout_signals.trend_score is
  '0-100 trend score: Donchian-55 breakout (40) + EMA25/99 regime (25) + 20-candle momentum vs BTC (20) + chandelier trend health (15). Null until the symbol has ~121 closed candles.';
comment on column public.breakout_signals.trend_entry is
  'True on the candle that first clears the 55-high while regime and momentum both align — the backtested A+ entry.';

alter table public.signal_journey_events
  add column if not exists trend_score smallint,
  add column if not exists trend_entry boolean not null default false;

comment on column public.signal_journey_events.trend_score is
  'The signal''s trend_score when the event was recorded.';

alter table public.journey_state
  add column if not exists trend_score smallint,
  add column if not exists trend_entry boolean not null default false;

-- Same function as 20260808110000, additionally carrying the trend columns.
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
    breakout_triggered, scoring_version, quote_volume_24h,
    trend_score, trend_entry
  ) values (
    new.analysis_model_id, new.journey_id, new.id, new.symbol_id, new.timeframe,
    new.status, new.candle_close_time, new.signal_price, new.breakout_level,
    new.breakout_confidence_score, new.false_breakout_risk, new.volume_ratio,
    new.regime_score, new.readiness_score, new.breakout_quality_score,
    new.confirmation_score, new.relative_strength_score, new.relative_strength_raw,
    new.breakout_triggered, new.scoring_version,
    (select s.quote_volume_24h from public.symbols s where s.id = new.symbol_id),
    new.trend_score, new.trend_entry
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

-- Same function as 20260809010000, additionally carrying the trend columns.
create or replace function public.sync_journey_state()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.journey_state (
    symbol_id, analysis_model_id, timeframe, status,
    confidence, false_breakout_risk, volume_ratio, price,
    candle_close_time, updated_at,
    regime_score, readiness_score, breakout_quality_score,
    confirmation_score, breakout_triggered, scoring_version,
    trend_score, trend_entry
  ) values (
    new.symbol_id, new.analysis_model_id, new.timeframe, new.status,
    coalesce(new.confidence, 0), new.false_breakout_risk, new.volume_ratio, new.price,
    new.candle_close_time, now(),
    coalesce(new.regime_score, 0), coalesce(new.readiness_score, 0),
    coalesce(new.breakout_quality_score, new.confidence, 0),
    coalesce(new.confirmation_score, 0),
    coalesce(new.breakout_triggered, new.status in ('breakout_detected', 'confirmed')),
    coalesce(new.scoring_version, 'legacy'),
    new.trend_score, coalesce(new.trend_entry, false)
  )
  on conflict (symbol_id, analysis_model_id, timeframe) do update
  set status = excluded.status,
      confidence = excluded.confidence,
      false_breakout_risk = excluded.false_breakout_risk,
      volume_ratio = excluded.volume_ratio,
      price = excluded.price,
      candle_close_time = excluded.candle_close_time,
      regime_score = excluded.regime_score,
      readiness_score = excluded.readiness_score,
      breakout_quality_score = excluded.breakout_quality_score,
      confirmation_score = excluded.confirmation_score,
      breakout_triggered = excluded.breakout_triggered,
      scoring_version = excluded.scoring_version,
      trend_score = excluded.trend_score,
      trend_entry = excluded.trend_entry,
      updated_at = now()
  where public.journey_state.candle_close_time <= excluded.candle_close_time;
  return new;
end;
$$;

commit;
