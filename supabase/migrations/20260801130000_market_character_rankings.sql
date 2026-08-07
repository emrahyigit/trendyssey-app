begin;

-- Dashboard rankings are calculated from closed-candle journey history. The
-- adjusted score is used only for ordering so a coin with one journey cannot
-- outrank a coin with a meaningful sample by accident; the UI receives and
-- displays the raw, easy-to-audit rate as `score`.
create or replace function public.get_market_character_rankings(
  p_model_slug text,
  p_timeframe text default '15m',
  p_lookback_days integer default 30,
  p_limit integer default 20
)
returns table (
  category text,
  symbol text,
  base_asset text,
  icon_url text,
  current_price numeric,
  price_change_percent_24h numeric,
  quote_volume_24h numeric,
  score numeric,
  rank_score numeric,
  sample_count integer,
  success_count integer,
  failure_count integer,
  median_return_percent numeric,
  rsi numeric,
  atr_distance numeric
)
language sql
stable
security definer
set search_path = public
as $$
with selected_model as (
  select id
  from public.analysis_models
  where slug = p_model_slug
  limit 1
),
started_journeys as (
  select
    event.symbol_id,
    event.analysis_model_id,
    event.journey_id,
    min(event.candle_close_time) as started_at
  from public.signal_journey_events event
  join selected_model model on model.id = event.analysis_model_id
  where event.timeframe = p_timeframe
    and event.status = 'breakout_detected'
    and event.candle_close_time >= now() - make_interval(days => greatest(7, least(coalesce(p_lookback_days, 30), 365)))
  group by event.symbol_id, event.analysis_model_id, event.journey_id
),
journey_results as (
  select
    started.symbol_id,
    started.journey_id,
    exists (
      select 1
      from public.signal_journey_events failed
      where failed.analysis_model_id = started.analysis_model_id
        and failed.symbol_id = started.symbol_id
        and failed.journey_id = started.journey_id
        and failed.status = 'failed'
        and failed.candle_close_time >= started.started_at
    ) as failed,
    outcome.status = 'evaluated' as evaluated,
    outcome.outcome_label = 'win'
      and coalesce(outcome.held_above_breakout, true)
      and coalesce(outcome.return_percent, 0) > 0 as successful,
    case when outcome.status = 'evaluated' then outcome.return_percent end as return_percent
  from started_journeys started
  left join public.signal_outcome_snapshots outcome
    on outcome.analysis_model_id = started.analysis_model_id
   and outcome.symbol_id = started.symbol_id
   and outcome.journey_id = started.journey_id
   and outcome.horizon_candles = 12
),
historical_stats as (
  select
    result.symbol_id,
    count(*) filter (where result.failed or result.evaluated)::integer as resolved_count,
    count(*) filter (where result.failed)::integer as failures,
    count(*) filter (where result.evaluated)::integer as evaluated_count,
    count(*) filter (where result.successful)::integer as successes,
    percentile_cont(0.5) within group (order by result.return_percent)
      filter (where result.evaluated and result.return_percent is not null)::numeric as median_return
  from journey_results result
  group by result.symbol_id
),
historical_rows as (
  select
    'disappointing'::text as category,
    market.symbol,
    market.base_asset,
    market.icon_url,
    market.current_price,
    market.price_change_percent_24h,
    market.quote_volume_24h,
    round(100.0 * stats.failures / nullif(stats.resolved_count, 0), 1) as score,
    round(100.0 * (stats.failures + 1.0) / (stats.resolved_count + 2.0), 4) as rank_score,
    stats.resolved_count as sample_count,
    stats.successes as success_count,
    stats.failures as failure_count,
    stats.median_return as median_return_percent,
    null::numeric as rsi,
    null::numeric as atr_distance
  from historical_stats stats
  join public.symbols market on market.id = stats.symbol_id
  where stats.resolved_count > 0

  union all

  select
    'successful'::text,
    market.symbol,
    market.base_asset,
    market.icon_url,
    market.current_price,
    market.price_change_percent_24h,
    market.quote_volume_24h,
    round(100.0 * stats.successes / nullif(stats.evaluated_count, 0), 1),
    round(100.0 * (stats.successes + 1.0) / (stats.evaluated_count + 2.0), 4),
    stats.evaluated_count,
    stats.successes,
    stats.failures,
    stats.median_return,
    null::numeric,
    null::numeric
  from historical_stats stats
  join public.symbols market on market.id = stats.symbol_id
  where stats.evaluated_count > 0
),
technical_inputs as (
  select
    market.symbol,
    market.base_asset,
    market.icon_url,
    market.current_price,
    market.price_change_percent_24h,
    market.quote_volume_24h,
    coalesce(signal.rsi::numeric, nullif(signal.explanation_facts ->> 'rsi', '')::numeric) as rsi,
    case
      when nullif(signal.explanation_facts ->> 'atr', '')::numeric > 0
       and nullif(signal.explanation_facts ->> 'emaFast', '')::numeric > 0
      then (
        coalesce(market.current_price, signal.signal_price)
        - nullif(signal.explanation_facts ->> 'emaFast', '')::numeric
      ) / nullif(signal.explanation_facts ->> 'atr', '')::numeric
    end as atr_distance
  from public.breakout_signals signal
  join selected_model model on model.id = signal.analysis_model_id
  join public.symbols market on market.id = signal.symbol_id
  where signal.timeframe = p_timeframe
    and market.is_enabled
    and market.quote_asset = 'USDT'
),
technical_scores as (
  select
    input.*,
    round(100 * (
      0.40 * least(1, greatest(0, (input.rsi - 55) / 25))
      + 0.35 * least(1, greatest(0, (input.atr_distance - 0.5) / 2.5))
      + 0.25 * least(1, greatest(0, coalesce(input.price_change_percent_24h, 0) / 10))
    ), 1) as heat_score,
    round(100 * (
      0.40 * least(1, greatest(0, (45 - input.rsi) / 25))
      + 0.35 * least(1, greatest(0, (-input.atr_distance - 0.5) / 2.5))
      + 0.25 * least(1, greatest(0, -coalesce(input.price_change_percent_24h, 0) / 10))
    ), 1) as pressure_score
  from technical_inputs input
  where input.rsi is not null and input.atr_distance is not null
),
technical_rows as (
  select
    'overheated'::text as category,
    scored.symbol,
    scored.base_asset,
    scored.icon_url,
    scored.current_price,
    scored.price_change_percent_24h,
    scored.quote_volume_24h,
    scored.heat_score as score,
    scored.heat_score as rank_score,
    1::integer as sample_count,
    0::integer as success_count,
    0::integer as failure_count,
    null::numeric as median_return_percent,
    scored.rsi,
    scored.atr_distance
  from technical_scores scored
  where scored.heat_score >= 30

  union all

  select
    'depressed'::text,
    scored.symbol,
    scored.base_asset,
    scored.icon_url,
    scored.current_price,
    scored.price_change_percent_24h,
    scored.quote_volume_24h,
    scored.pressure_score,
    scored.pressure_score,
    1::integer,
    0::integer,
    0::integer,
    null::numeric,
    scored.rsi,
    scored.atr_distance
  from technical_scores scored
  where scored.pressure_score >= 30
),
all_rows as (
  select * from historical_rows
  union all
  select * from technical_rows
),
ranked as (
  select
    row.*,
    row_number() over (
      partition by row.category
      order by row.rank_score desc, row.quote_volume_24h desc nulls last, row.symbol
    ) as position
  from all_rows row
)
select
  ranked.category,
  ranked.symbol,
  ranked.base_asset,
  ranked.icon_url,
  ranked.current_price,
  ranked.price_change_percent_24h,
  ranked.quote_volume_24h,
  ranked.score,
  ranked.rank_score,
  ranked.sample_count,
  ranked.success_count,
  ranked.failure_count,
  ranked.median_return_percent,
  ranked.rsi,
  ranked.atr_distance
from ranked
where ranked.position <= greatest(1, least(coalesce(p_limit, 20), 100))
order by ranked.category, ranked.position;
$$;

revoke all on function public.get_market_character_rankings(text, text, integer, integer) from public;
grant execute on function public.get_market_character_rankings(text, text, integer, integer) to authenticated;

create index if not exists signal_journey_events_market_character_idx
  on public.signal_journey_events
  (analysis_model_id, timeframe, status, candle_close_time desc, journey_id, symbol_id);

commit;
