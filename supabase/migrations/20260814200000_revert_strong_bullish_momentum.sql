-- Revert "Strong Bullish Momentum" (commit b333d92) on the live database.
--
-- The product returns to the pre-market-state pipeline: scan-market writes
-- breakout_signals, the breakout_signal_notification_matcher triggers enqueue
-- pushes, and the app reads the signal lifecycle. Everything the market-state
-- rebuild created is dropped; every definition it replaced is restored to the
-- last pre-rebuild version (source migration noted above each).
--
-- Data notes (accepted, unrecoverable):
--   * market_state_*, daily_predictions, live_trades and trade_config rows are
--     deleted with their tables (testnet trading only).
--   * signal_outcome_snapshots, indicator_snapshots and signal_score_components
--     were dropped by the rebuild; they are recreated empty with columns
--     reconstructed from the code that reads and writes them.
--   * profiles.notification_statuses user selections were overwritten by the
--     rebuild and stay as they are now; they remain valid for the old pipeline.

begin;

-- 1) Auto-trader cron.
select cron.unschedule(jobname) from cron.job where jobname = 'trade-executor';

-- 2) Market-state product tables (their triggers and policies die with them).
drop table if exists public.daily_predictions cascade;
drop table if exists public.live_trades cascade;
drop table if exists public.trade_config cascade;
drop table if exists public.market_state_history cascade;
drop table if exists public.market_state_current cascade;

-- 3) Functions that exist only in the rebuild, every overload.
do $cleanup$
declare r record;
begin
  for r in
    select p.oid::regprocedure as sig
      from pg_proc p
      join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public'
       and p.proname in (
         'enqueue_market_state_notifications',
         'market_state_scenario_entries',
         'get_daily_prediction_symbols',
         'get_daily_predictor_leaderboard',
         'get_predictor_daily_calls',
         'get_top_predictors_with_recent_votes',
         'update_trade_market_states',
         'update_trade_market_state_rules',
         'update_trade_config',
         'request_auto_trader_reset',
         'live_signal_strength'
       )
  loop
    execute 'drop function ' || r.sig || ' cascade';
  end loop;
end
$cleanup$;

-- 4) Columns and constraints the rebuild added to surviving tables.
alter table public.breakout_signals
  drop column if exists trend_score cascade,
  drop column if exists trend_entry cascade;

alter table public.signal_journey_events
  drop constraint if exists signal_journey_events_market_state_check,
  drop column if exists trend_score cascade,
  drop column if exists trend_entry cascade,
  drop column if exists market_state cascade,
  drop column if exists market_state_score cascade,
  drop column if exists market_state_change cascade;

alter table public.journey_state
  drop column if exists trend_score cascade,
  drop column if exists trend_entry cascade;

alter table public.profiles
  drop constraint if exists profiles_notification_market_states_check,
  drop constraint if exists profiles_minimum_state_score_check,
  drop column if exists notification_market_states cascade,
  drop column if exists minimum_state_score cascade,
  drop column if exists aplus_entries_only cascade;

alter table public.notifications
  drop constraint if exists notifications_market_state_check,
  drop column if exists symbol_id cascade,
  drop column if exists timeframe cascade,
  drop column if exists market_state cascade,
  drop column if exists market_state_score cascade,
  drop column if exists market_state_change cascade;

-- 5) Audit tables the rebuild dropped. scan-market treats the indicator
-- snapshot write as fatal and the journey trigger feeds outcome snapshots,
-- so these must exist before the old definitions return.
create table if not exists public.indicator_snapshots (
  id uuid primary key default gen_random_uuid(),
  analysis_model_id uuid not null references public.analysis_models(id) on delete cascade,
  symbol_id uuid not null references public.symbols(id) on delete cascade,
  timeframe text not null,
  candle_open_time timestamptz not null,
  candle_close_time timestamptz not null,
  close_price double precision,
  volume double precision,
  quote_volume double precision,
  volume_ratio double precision,
  volume_contraction_ratio double precision,
  retest_volume_ratio double precision,
  rsi double precision,
  rsi_delta_3 double precision,
  atr double precision,
  atr_change_percent double precision,
  ema_fast double precision,
  ema_slow double precision,
  ema_long double precision,
  ema_fast_slope double precision,
  ema_slow_slope double precision,
  ema_cross_age integer,
  ema_retest boolean,
  ema_retest_age integer,
  adx double precision,
  adx_delta_3 double precision,
  plus_di double precision,
  minus_di double precision,
  setup_type text,
  setup_score double precision,
  breakout_qualified boolean,
  bollinger_band_width double precision,
  donchian_high double precision,
  estimated_volume_delta double precision,
  taker_buy_ratio double precision,
  created_at timestamptz not null default now(),
  unique (analysis_model_id, symbol_id, timeframe, candle_close_time)
);
alter table public.indicator_snapshots enable row level security;

create table if not exists public.signal_score_components (
  id uuid primary key default gen_random_uuid(),
  breakout_signal_id uuid not null references public.breakout_signals(id) on delete cascade,
  component_key text not null,
  component_name text,
  raw_value double precision,
  normalized_value double precision,
  score_contribution double precision,
  maximum_score double precision,
  explanation text,
  created_at timestamptz not null default now(),
  unique (breakout_signal_id, component_key)
);
alter table public.signal_score_components enable row level security;

create table if not exists public.signal_outcome_snapshots (
  id uuid primary key default gen_random_uuid(),
  analysis_model_id uuid references public.analysis_models(id) on delete cascade,
  journey_id uuid not null,
  breakout_signal_id uuid references public.breakout_signals(id) on delete cascade,
  origin_event_id uuid references public.signal_journey_events(id) on delete cascade,
  symbol_id uuid references public.symbols(id) on delete cascade,
  timeframe text not null,
  horizon_candles smallint not null,
  entry_price double precision,
  entry_close_time timestamptz,
  breakout_level double precision,
  due_at timestamptz,
  status text not null default 'pending',
  return_percent double precision,
  max_favorable_excursion_percent double precision,
  max_adverse_excursion_percent double precision,
  held_above_breakout boolean,
  outcome_label text,
  evaluated_at timestamptz,
  created_at timestamptz not null default now(),
  unique (journey_id, horizon_candles)
);
alter table public.signal_outcome_snapshots enable row level security;
drop policy if exists signal_outcome_snapshots_read on public.signal_outcome_snapshots;
create policy signal_outcome_snapshots_read on public.signal_outcome_snapshots
  for select to authenticated using (true);

-- 6) Last pre-rebuild definitions, verbatim.

-- from 20260801_breakout_engines_and_scores.sql
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
    confirmation_score, breakout_triggered, scoring_version
  ) values (
    new.symbol_id, new.analysis_model_id, new.timeframe, new.status,
    coalesce(new.confidence, 0), new.false_breakout_risk, new.volume_ratio, new.price,
    new.candle_close_time, now(),
    coalesce(new.regime_score, 0), coalesce(new.readiness_score, 0),
    coalesce(new.breakout_quality_score, new.confidence, 0),
    coalesce(new.confirmation_score, 0),
    coalesce(new.breakout_triggered, new.status in ('breakout_detected', 'retest', 'confirmed')),
    coalesce(new.scoring_version, 'legacy')
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
      updated_at = now()
  where public.journey_state.candle_close_time <= excluded.candle_close_time;
  return new;
end;
$$;

-- from 20260808110000_relative_strength_percentile.sql
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

-- from 20260808180000_signal_strength_win_rate_only.sql
create or replace function public.refresh_relative_strength(p_timeframe text)
returns integer
language sql
security definer
set search_path = public
as $$
with fresh as (
  select distinct on (bs.symbol_id)
         bs.symbol_id, bs.relative_strength_win_rate
    from public.breakout_signals bs
   where bs.timeframe = p_timeframe
     and bs.relative_strength_win_rate is not null
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
         round(100 * percent_rank() over (order by relative_strength_win_rate))::integer as pct
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

-- from 20260808200000_notification_success_rate.sql
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
with started as (
  select journey_id, min(candle_close_time) as started_at
  from public.signal_journey_events
  where analysis_model_id = p_model_id
    and symbol_id = p_symbol_id
    and timeframe = p_timeframe
    and status = 'breakout_detected'
    and candle_close_time >= now() - interval '30 days'
  group by journey_id
),
fates as (
  select s.journey_id,
         bool_or(e.status = 'failed') as ever_failed
  from started s
  left join public.signal_journey_events e
    on e.journey_id = s.journey_id
   and e.symbol_id = p_symbol_id
   and e.analysis_model_id = p_model_id
   and e.candle_close_time >= s.started_at
  group by s.journey_id
)
-- Null when the sample is too small to judge; callers treat null as "pass".
select case
  when count(*) < 4 then null
  else round(100.0 * count(*) filter (where not ever_failed) / count(*))::integer
end
from fates;
$$;

-- from 20260807140000_invalidated_means_failed.sql
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

-- from 20260807140000_invalidated_means_failed.sql
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

-- from 20260801113000_notification_score_filters.sql
create or replace function public.breakout_notification_text(
  p_breakout_signal_id uuid,
  p_user_id uuid,
  p_signal_status text
)
returns table (title text, body text)
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_base_asset text;
  v_regime integer;
  v_readiness integer;
  v_quality integer;
  v_confirmation integer;
  v_status text;
  v_language text;
  v_bearish boolean;
  v_phase text;
begin
  select s.base_asset,
         coalesce(bs.regime_score, 0),
         coalesce(bs.readiness_score, 0),
         coalesce(bs.breakout_quality_score, bs.breakout_confidence_score, 0),
         coalesce(bs.confirmation_score, 0),
         coalesce(p_signal_status, bs.status),
         coalesce(bs.direction = 'down' or am.slug = 'double-top-v1', false)
    into v_base_asset, v_regime, v_readiness, v_quality,
         v_confirmation, v_status, v_bearish
    from public.breakout_signals bs
    join public.symbols s on s.id = bs.symbol_id
    left join public.analysis_models am on am.id = bs.analysis_model_id
   where bs.id = p_breakout_signal_id;

  if v_base_asset is null then return; end if;

  select coalesce(pr.preferred_language, 'tr') into v_language
    from public.profiles pr where pr.id = p_user_id;
  v_language := coalesce(v_language, 'tr');

  v_phase := case v_status
    when 'pre_breakout' then
      case when v_language = 'tr'
        then case when v_bearish then 'Düşüş bekleniyor' else 'Kırılım bekleniyor' end
        else case when v_bearish then 'Waiting for breakdown' else 'Waiting for breakout' end end
    when 'breakout_detected' then
      case when v_language = 'tr'
        then case when v_bearish then 'Düşüş başladı' else 'Kırılım başladı' end
        else case when v_bearish then 'Breakdown started' else 'Breakout started' end end
    when 'confirmed' then
      case when v_language = 'tr'
        then case when v_bearish then 'Düşüş güçleniyor' else 'Kırılım güçleniyor' end
        else case when v_bearish then 'Breakdown strengthening' else 'Breakout strengthening' end end
    when 'retest' then case when v_language = 'tr' then 'Seviye test ediliyor' else 'Level being tested' end
    when 'failed' then case when v_language = 'tr' then 'Sinyal geçersiz oldu' else 'Signal invalidated' end
    when 'expired' then case when v_language = 'tr' then 'Takip tamamlandı' else 'Tracking complete' end
    else coalesce(v_status, '')
  end;

  title := v_base_asset || ' · ' || v_phase;
  body := case when v_language = 'tr'
    then 'Rejim ' || v_regime || ' · Hazırlık ' || v_readiness
      || ' · Kalite ' || v_quality || ' · Teyit ' || v_confirmation
    else 'Regime ' || v_regime || ' · Ready ' || v_readiness
      || ' · Quality ' || v_quality || ' · Confirm ' || v_confirmation
  end;
  return next;
end;
$$;

-- from 20260808220000_fix_entitlement_check.sql
create or replace function public.enqueue_matching_signal_notifications()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  matched record;
  notification_id uuid;
  dedup_key text;
  notification_title text;
  notification_body text;
  success_rate integer;
begin
  success_rate := public.symbol_success_rate(new.analysis_model_id, new.symbol_id, new.timeframe);

  for matched in
    select p.id as user_id
    from public.profiles p
    where p.notifications_enabled
      and p.preferred_analysis_model_id = new.analysis_model_id
      and exists (
        select 1 from public.subscription_entitlements e
        where e.user_id = p.id
          and e.is_active
          and e.expires_at > now()
      )
      and p.preferred_timeframe = new.timeframe
      and coalesce(new.relative_strength_score, 100) >= p.minimum_signal_strength
      and coalesce(success_rate, 100) >= p.minimum_success_rate
      and new.false_breakout_risk <= p.maximum_false_breakout_risk
      and coalesce(new.volume_ratio, 0) >= p.minimum_volume_ratio
      and new.status = any(p.notification_statuses)
      and (
        p.notification_scope = 'all'
        or exists (
          select 1
          from public.watchlists w
          join public.watchlist_items wi on wi.watchlist_id = w.id
          where w.user_id = p.id and wi.symbol_id = new.symbol_id
        )
      )
  loop
    select copy.title, copy.body
      into notification_title, notification_body
      from public.breakout_notification_text(new.id, matched.user_id, new.status) copy
      limit 1;
    if notification_title is null then continue; end if;

    dedup_key := matched.user_id::text || ':' || new.id::text || ':'
      || new.candle_close_time::text || ':' || new.status;
    insert into public.notifications(
      user_id, breakout_signal_id, title, body, notification_type,
      deduplication_key, signal_status
    ) values (
      matched.user_id, new.id, notification_title,
      notification_body, 'breakout_signal', dedup_key, new.status
    )
    on conflict (deduplication_key) where deduplication_key is not null do nothing
    returning id into notification_id;

    if notification_id is not null then
      insert into public.notification_queue(notification_id, deduplication_key)
      values (notification_id, dedup_key)
      on conflict (deduplication_key) do nothing;
    end if;
    notification_id := null;
    notification_title := null;
    notification_body := null;
  end loop;
  return new;
end;
$$;

-- get_market_character_rankings is not restored: no app screen or function
-- calls it (verified against the reverted tree), it only read the audit tables.
grant execute on function public.get_symbol_journey_stats(text, text, text, integer) to authenticated;
grant execute on function public.get_journey_invalidation_stats(text, text, integer) to authenticated;

-- 7) The breakout push triggers, exactly as 20260726_notify_on_transition_only
-- left them.
drop trigger if exists breakout_signal_notification_matcher on public.breakout_signals;
drop trigger if exists breakout_signal_notification_matcher_insert on public.breakout_signals;
drop trigger if exists breakout_signal_notification_matcher_update on public.breakout_signals;

create trigger breakout_signal_notification_matcher_insert
    after insert on public.breakout_signals
    for each row
    execute function public.enqueue_matching_signal_notifications();

create trigger breakout_signal_notification_matcher_update
    after update on public.breakout_signals
    for each row
    when (old.status is distinct from new.status)
    execute function public.enqueue_matching_signal_notifications();

commit;
