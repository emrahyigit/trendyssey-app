begin;

-- Trend filters for the auto trader (see _shared/trend_score.ts). The Aug
-- 2026 tournament's strongest entry on every timeframe was the A+ setup: a
-- fresh 55-high breakout with regime and momentum aligned. The executor can
-- now require that setup and/or a minimum live trend score at entry. Both
-- default off, so deploying this changes nothing until the app applies them.

alter table public.trade_config
  add column if not exists minimum_trend_score smallint not null default 0,
  add column if not exists require_trend_entry boolean not null default false;

comment on column public.trade_config.minimum_trend_score is
  'Minimum breakout_signals.trend_score at entry; 0 disables the filter. Null scores pass (unmeasured is not a measurement).';
comment on column public.trade_config.require_trend_entry is
  'When true, only journeys whose breakout candle carried trend_entry (the backtested A+ setup) are traded.';

alter table public.live_trades
  add column if not exists entry_trend_score smallint;

comment on column public.live_trades.entry_trend_score is
  'Decision-time snapshot of the signal''s trend_score, frozen by the executor like entry_strength.';

-- New overload with the trend parameters. The previous 10-argument signature
-- stays callable so app builds that predate the trend filters keep working;
-- they simply leave the trend columns untouched.
create or replace function public.update_trade_config(
  p_entry_trigger_percent numeric,
  p_profit_target_percent numeric,
  p_stop_loss_percent numeric,
  p_max_open_hours integer,
  p_max_slots integer,
  p_minimum_signal_strength integer,
  p_minimum_success_rate integer,
  p_minimum_quote_volume numeric,
  p_minimum_trend_score integer,
  p_require_trend_entry boolean,
  p_timeframe text,
  p_model_slug text
) returns void
language sql
security definer
set search_path = public
as $$
  update public.trade_config set
    entry_trigger_percent = p_entry_trigger_percent,
    profit_target_percent = p_profit_target_percent,
    stop_loss_percent = p_stop_loss_percent,
    max_open_hours = p_max_open_hours,
    max_slots = p_max_slots,
    minimum_signal_strength = p_minimum_signal_strength,
    minimum_success_rate = p_minimum_success_rate,
    minimum_quote_volume = p_minimum_quote_volume,
    minimum_trend_score = p_minimum_trend_score,
    require_trend_entry = p_require_trend_entry,
    timeframe = p_timeframe,
    model_slug = p_model_slug,
    updated_at = now()
  where id;
$$;

revoke all on function public.update_trade_config(numeric, numeric, numeric, integer, integer, integer, integer, numeric, integer, boolean, text, text) from public, anon;
grant execute on function public.update_trade_config(numeric, numeric, numeric, integer, integer, integer, integer, numeric, integer, boolean, text, text) to authenticated;

commit;
