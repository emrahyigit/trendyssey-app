begin;

-- The scenario screen filters entries by 24h volume, but events only knew the
-- coin's *current* volume through the symbols join — so a coin whose volume
-- fell overnight retroactively deleted its past trades from the replay. Store
-- the volume that was true when the event happened instead.
alter table public.signal_journey_events
  add column if not exists quote_volume_24h double precision;

comment on column public.signal_journey_events.quote_volume_24h is
  'The symbol''s 24h quote volume when the event was recorded, so scenario replays judge entries by what was true at entry time.';

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
    confirmation_score, breakout_triggered, scoring_version, quote_volume_24h
  ) values (
    new.analysis_model_id, new.journey_id, new.id, new.symbol_id, new.timeframe,
    new.status, new.candle_close_time, new.signal_price, new.breakout_level,
    new.breakout_confidence_score, new.false_breakout_risk, new.volume_ratio,
    new.regime_score, new.readiness_score, new.breakout_quality_score,
    new.confirmation_score, new.breakout_triggered, new.scoring_version,
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

-- Existing events predate the snapshot; the coin's current volume is the only
-- approximation available for them.
update public.signal_journey_events e
   set quote_volume_24h = s.quote_volume_24h
  from public.symbols s
 where s.id = e.symbol_id
   and e.quote_volume_24h is null;

commit;
