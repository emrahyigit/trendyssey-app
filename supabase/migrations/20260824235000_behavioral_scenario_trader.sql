-- Move Scenario and Auto Trader from the legacy named-state gate to the
-- behavioral signal engine. Existing state columns remain for audit/context,
-- but a new position is selected by a concrete behavior and its evidence.

begin;

alter table public.trade_config
  add column if not exists allowed_behavior_signals text[] not null
    default array['buyer_takeover']::text[],
  add column if not exists minimum_behavior_score smallint not null default 60,
  add column if not exists require_behavior_confirmed boolean not null default true;

alter table public.trade_config
  drop constraint if exists trade_config_allowed_behavior_signals_check,
  add constraint trade_config_allowed_behavior_signals_check check (
    cardinality(allowed_behavior_signals) > 0 and allowed_behavior_signals <@ array[
      'lower_low_failure', 'downside_progress_weakening',
      'sell_pressure_downside_divergence', 'failed_breakdown',
      'buyer_recovery_strengthening', 'seller_exhaustion', 'buyer_takeover'
    ]::text[]
  ),
  drop constraint if exists trade_config_minimum_behavior_score_check,
  add constraint trade_config_minimum_behavior_score_check
    check (minimum_behavior_score between 0 and 100);

alter table public.live_trades
  add column if not exists entry_behavior_kind text,
  add column if not exists entry_behavior_score smallint,
  add column if not exists entry_behavior_direction text,
  add column if not exists entry_behavior_status text,
  add column if not exists entry_behavior_evidence jsonb not null default '[]'::jsonb;

create or replace function public.update_trade_behavior_rules(
  p_allowed_behavior_signals text[],
  p_minimum_behavior_score integer,
  p_require_behavior_confirmed boolean
) returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if p_allowed_behavior_signals is null
    or cardinality(p_allowed_behavior_signals) = 0
    or exists (
      select 1 from unnest(p_allowed_behavior_signals) signal
      where signal <> all(array[
        'lower_low_failure', 'downside_progress_weakening',
        'sell_pressure_downside_divergence', 'failed_breakdown',
        'buyer_recovery_strengthening', 'seller_exhaustion', 'buyer_takeover'
      ]::text[])
    ) then
    raise exception 'Invalid behavioral-signal filter';
  end if;
  if p_minimum_behavior_score is null or p_minimum_behavior_score not between 0 and 100 then
    raise exception 'Invalid minimum behavior score';
  end if;

  update public.trade_config
  set allowed_behavior_signals = array(select distinct unnest(p_allowed_behavior_signals)),
      minimum_behavior_score = p_minimum_behavior_score,
      require_behavior_confirmed = coalesce(p_require_behavior_confirmed, true),
      updated_at = now()
  where id;
end;
$$;

revoke all on function public.update_trade_behavior_rules(text[], integer, boolean)
  from public, anon;
grant execute on function public.update_trade_behavior_rules(text[], integer, boolean)
  to authenticated;

-- One row is emitted when a bullish behavior first appears or graduates from
-- developing to confirmed. Repeated candles carrying the same read are not
-- counted as fresh entries, so the replay cannot pyramid one observation.
create or replace function public.behavioral_scenario_entries(
  p_timeframe text,
  p_since timestamptz,
  p_limit integer default 800
)
returns table (
  symbol_id uuid,
  symbol text,
  behavior_kind text,
  behavior_score smallint,
  behavior_direction text,
  behavior_status text,
  behavior_trend text,
  behavior_evidence jsonb,
  state text,
  state_score smallint,
  candle_close_time timestamptz,
  close_price numeric,
  quote_volume_24h numeric
)
language sql
stable
security definer
set search_path = public
as $$
  with active_version as (
    select c.scoring_version
    from public.market_state_current c
    group by c.scoring_version
    order by max(c.updated_at) desc
    limit 1
  ), active_history as (
    select h.*
    from public.market_state_history h
    join public.market_state_current c
      on c.symbol_id = h.symbol_id
     and c.timeframe = h.timeframe
     and c.scoring_version = h.scoring_version
    join active_version v on v.scoring_version = h.scoring_version
    where h.timeframe = p_timeframe
  ), with_previous as (
    select h.*,
           lag(h.behavioral_signals) over (
             partition by h.symbol_id, h.timeframe
             order by h.candle_close_time
           ) as previous_behavioral_signals
    from active_history h
  ), expanded as (
    select h.*, signal.value as behavior
    from with_previous h
    cross join lateral jsonb_array_elements(coalesce(h.behavioral_signals, '[]'::jsonb)) signal
    where signal.value->>'direction' = 'bullish'
  )
  select e.symbol_id, s.symbol,
         e.behavior->>'kind',
         greatest(0, least(100, coalesce((e.behavior->>'score')::integer, 0)))::smallint,
         e.behavior->>'direction', e.behavior->>'status', e.behavior->>'trend',
         coalesce(e.behavior->'evidence', '[]'::jsonb),
         e.state, e.state_score, e.candle_close_time, e.close_price,
         coalesce(e.quote_volume_24h, s.quote_volume_24h, 0)
  from expanded e
  join public.symbols s on s.id = e.symbol_id
  where e.candle_close_time >= p_since
    and not exists (
      select 1
      from jsonb_array_elements(coalesce(e.previous_behavioral_signals, '[]'::jsonb)) previous
      where previous->>'kind' = e.behavior->>'kind'
        and previous->>'status' = e.behavior->>'status'
    )
  order by e.candle_close_time desc,
           greatest(0, least(100, coalesce((e.behavior->>'score')::integer, 0))) desc
  limit greatest(1, least(coalesce(p_limit, 800), 2000));
$$;

revoke all on function public.behavioral_scenario_entries(text, timestamptz, integer)
  from public, anon;
grant execute on function public.behavioral_scenario_entries(text, timestamptz, integer)
  to authenticated;

commit;
