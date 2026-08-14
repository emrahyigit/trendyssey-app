begin;

-- Aug 2026 cleanup: everything the candle-store retirement and the scan-market
-- consolidation left behind. Each item was verified against the app, every
-- edge function (downloaded sources included) and every SQL definition —
-- nothing below has a living reader or writer after this migration's partner
-- deploys (scan-market no longer writes the audit tables).

-- 1) Cron jobs that still invoke the retired edge functions, whatever their
--    names are. The functions themselves are deleted via the CLI.
select cron.unschedule(jobname) from cron.job
 where command like '%evaluate-outcomes%'
    or command like '%derive-journeys%'
    or command like '%detect-double-patterns%'
    or command like '%sync-candles%';

-- 2) The outcome-snapshot chain. Its only consumers were an app service no
--    screen ever instantiated and the rankings RPC below, which nothing calls.
--    The journey-event trigger must stop feeding it first — this is the
--    20260811090000 definition with the snapshot loop removed.
create or replace function public.record_signal_journey_event()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
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
  on conflict (breakout_signal_id, journey_id, status, candle_close_time) do nothing;
  return new;
end;
$$;

drop function if exists public.get_market_character_rankings(text, text, integer, integer);
drop table if exists public.signal_outcome_snapshots cascade;

-- 3) Write-only audit tables: 42k+ rows nobody ever read. The detail page
--    explains every score from explanation_facts on the signal row.
drop table if exists public.indicator_snapshots cascade;
drop table if exists public.signal_score_components cascade;

-- 4) Tables with zero code references anywhere (all empty except the single
--    runtime_settings row, which nothing reads).
drop table if exists public.alert_rules cascade;
drop table if exists public.scan_jobs cascade;
drop table if exists public.scan_job_errors cascade;
drop table if exists public.runtime_settings cascade;

-- 5) A helper whose subject no longer exists: the candle store was dropped in
--    July. (rls_auto_enable is deliberately kept — its definition predates the
--    repo and it may back an event trigger that protects future tables.)
drop function if exists public.prune_candles(integer);

commit;
