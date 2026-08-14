begin;

-- The ledger gains the decision-time snapshot: what the signal looked like at
-- the moment the executor acted. The app joins current prices client-side for
-- unrealized PnL; these columns freeze the entry context forever.
alter table public.live_trades
  add column if not exists signal_price numeric,
  add column if not exists entry_strength integer,
  add column if not exists entry_success_rate integer,
  add column if not exists entry_quote_volume numeric;

commit;
