begin;

-- Cycle-over-cycle delta for the signal-strength badge. The scanner copies
-- the row's stored score into this column before overwriting it, once per
-- candle cycle — deliberately NOT maintained by refresh_relative_strength,
-- which runs four times per cycle (once per batch slot) and would reduce the
-- delta to intra-cycle ranking jitter.
alter table public.breakout_signals
  add column if not exists previous_relative_strength_score integer;

comment on column public.breakout_signals.previous_relative_strength_score is
  'Signal strength from the previous scan cycle; the app renders the delta badge from score minus this.';

commit;
