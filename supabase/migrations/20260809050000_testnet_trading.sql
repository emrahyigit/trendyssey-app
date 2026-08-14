begin;

-- Testnet trade executor: one config row mirroring the Breakout Scenario
-- parameters, one ledger of every order the executor touches, and a
-- once-a-minute cron. enabled ships FALSE and use_testnet TRUE; the live
-- exchange additionally requires the LIVE_TRADING_ENABLED env on the
-- function, so no single flag can reach real funds.

create table if not exists public.trade_config (
  id boolean primary key default true check (id),
  enabled boolean not null default false,
  use_testnet boolean not null default true,
  timeframe text not null default '15m',
  model_slug text not null default 'ema-7-25-99-v1',
  entry_trigger_percent numeric not null default 0 check (entry_trigger_percent between 0 and 20),
  profit_target_percent numeric not null default 10 check (profit_target_percent > 0),
  stop_loss_percent numeric not null default 10 check (stop_loss_percent > 0),
  max_open_hours integer not null default 24 check (max_open_hours between 1 and 168),
  max_slots integer not null default 5 check (max_slots between 1 and 20),
  quote_per_trade numeric not null default 100 check (quote_per_trade > 0),
  minimum_signal_strength integer not null default 0 check (minimum_signal_strength between 0 and 100),
  minimum_success_rate integer not null default 0 check (minimum_success_rate between 0 and 100),
  minimum_quote_volume numeric not null default 10000000 check (minimum_quote_volume >= 0),
  updated_at timestamptz not null default now()
);

insert into public.trade_config (id) values (true) on conflict (id) do nothing;

create table if not exists public.live_trades (
  id uuid primary key default gen_random_uuid(),
  breakout_signal_id uuid references public.breakout_signals(id) on delete set null,
  journey_id uuid,
  symbol text not null,
  status text not null check (status in ('pending_entry', 'open', 'closed', 'canceled', 'error')),
  entry_trigger_price numeric,
  entry_order_id text,
  entry_price numeric,
  entry_quantity numeric,
  entered_at timestamptz,
  oco_order_list_id text,
  target_price numeric,
  stop_price numeric,
  exit_price numeric,
  exit_reason text check (exit_reason in ('target', 'stop_loss', 'time_limit', 'manual', 'error')),
  exited_at timestamptz,
  realized_quote_pnl numeric,
  error_message text,
  is_testnet boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index if not exists live_trades_status_idx on public.live_trades (status, is_testnet);
create index if not exists live_trades_journey_idx on public.live_trades (journey_id, is_testnet);

-- The app may read the ledger and the config; only the service role writes.
alter table public.trade_config enable row level security;
alter table public.live_trades enable row level security;
drop policy if exists trade_config_read on public.trade_config;
create policy trade_config_read on public.trade_config
  for select to authenticated using (true);
drop policy if exists live_trades_read on public.live_trades;
create policy live_trades_read on public.live_trades
  for select to authenticated using (true);

do $$ begin
  perform cron.unschedule('trade-executor');
exception when others then null; end $$;

select cron.schedule(
  'trade-executor',
  '* * * * *',
  $cmd$select net.http_post(
    url := 'https://desdaealmbjnbokmvnsn.supabase.co/functions/v1/trade-executor',
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'x-cron-secret', (select decrypted_secret from vault.decrypted_secrets where name = 'pulse15_cron_secret')
    ),
    body := '{}'::jsonb,
    timeout_milliseconds := 55000
  );$cmd$
);

commit;
