begin;

-- Chandelier trailing exit for the auto trader — the exit half of the Aug
-- 2026 tournament winner (see _shared/trend_score.ts). Instead of the fixed
-- target/stop OCO, the executor keeps a single stop-limit SELL that ratchets
-- up with the trade's high watermark: stop = highest high since entry minus
-- multiplier × ATR-at-entry. No target caps the winners; the time limit still
-- applies. Ships OFF so deploying changes nothing until the app enables it.

alter table public.trade_config
  add column if not exists use_chandelier_exit boolean not null default false,
  add column if not exists chandelier_atr_multiplier numeric not null default 3.0
    check (chandelier_atr_multiplier between 1 and 6);

comment on column public.trade_config.use_chandelier_exit is
  'When true, exits use a ratcheting stop at high-watermark − multiplier×ATR instead of the fixed target/stop OCO. The backtested multiplier is 3.0.';

alter table public.live_trades
  add column if not exists exit_order_id text,
  add column if not exists high_watermark numeric,
  add column if not exists atr_at_entry numeric;

comment on column public.live_trades.exit_order_id is
  'Current trailing stop-limit order (chandelier mode). OCO exits keep using oco_order_list_id.';
comment on column public.live_trades.high_watermark is
  'Highest closed-candle high seen since entry; the stop only ever rises with it.';
comment on column public.live_trades.atr_at_entry is
  'ATR(14) on the config timeframe at entry, frozen so the trail width cannot breathe with later volatility.';

-- New overload carrying the chandelier switches. The 10- and 12-argument
-- signatures stay callable so older app builds keep working; they simply
-- leave the new columns untouched.
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
  p_use_chandelier_exit boolean,
  p_chandelier_atr_multiplier numeric,
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
    use_chandelier_exit = p_use_chandelier_exit,
    chandelier_atr_multiplier = p_chandelier_atr_multiplier,
    timeframe = p_timeframe,
    model_slug = p_model_slug,
    updated_at = now()
  where id;
$$;

revoke all on function public.update_trade_config(numeric, numeric, numeric, integer, integer, integer, integer, numeric, integer, boolean, boolean, numeric, text, text) from public, anon;
grant execute on function public.update_trade_config(numeric, numeric, numeric, integer, integer, integer, integer, numeric, integer, boolean, boolean, numeric, text, text) to authenticated;

commit;
