begin;

-- The app gains two safe write paths into the executor, both as security-
-- definer RPCs so the tables themselves stay service-role-only:
--   update_trade_config     — apply the Breakout Scenario parameters
--   request_auto_trader_reset — ask the executor to unwind and wipe its ledger
-- The reset is a FLAG, not a delete: only the executor talks to the exchange,
-- so it cancels every live order, sells holdings back to quote, then clears
-- the ledger and the flag on its next minute tick.

alter table public.trade_config
  add column if not exists reset_requested boolean not null default false;

create or replace function public.update_trade_config(
  p_entry_trigger_percent numeric,
  p_profit_target_percent numeric,
  p_stop_loss_percent numeric,
  p_max_open_hours integer,
  p_max_slots integer,
  p_minimum_signal_strength integer,
  p_minimum_success_rate integer,
  p_minimum_quote_volume numeric,
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
    timeframe = p_timeframe,
    model_slug = p_model_slug,
    updated_at = now()
  where id;
$$;

create or replace function public.request_auto_trader_reset()
returns void
language sql
security definer
set search_path = public
as $$
  update public.trade_config set reset_requested = true, updated_at = now() where id;
$$;

revoke all on function public.update_trade_config(numeric, numeric, numeric, integer, integer, integer, integer, numeric, text, text) from public, anon;
grant execute on function public.update_trade_config(numeric, numeric, numeric, integer, integer, integer, integer, numeric, text, text) to authenticated;
revoke all on function public.request_auto_trader_reset() from public, anon;
grant execute on function public.request_auto_trader_reset() to authenticated;

commit;
