-- One rule for saving a prediction: one call per coin per UTC day.
--
-- The chat prediction was gated by guard_prediction_window, which accepted a
-- vote only while the coin's newest breakout_signals row still read
-- 'pre_breakout'. That lifecycle was retired with the Market State rework, so
-- the gate silently closed the feature: only 20 of 723 signals still carry the
-- status and no prediction has been saved since 2026-08-09. The gate goes, and
-- uniqueness moves off the journey and onto (user, coin, UTC day) so both
-- prediction surfaces enforce the same rule.

begin;

drop trigger if exists guard_prediction_window on public.signal_predictions;
drop function if exists public.guard_prediction_window();

alter table public.signal_predictions
  add column if not exists prediction_day date not null
    default (timezone('UTC', now())::date);

-- Backfill predates the column default, so derive each existing row's day from
-- when it was actually cast.
update public.signal_predictions
set prediction_day = (timezone('UTC', predicted_at))::date
where prediction_day is distinct from (timezone('UTC', predicted_at))::date;

-- Symbols are written uppercase by the client; fold anything legacy so the
-- uniqueness rule cannot be sidestepped by casing.
update public.signal_predictions
set symbol = upper(symbol)
where symbol <> upper(symbol);

alter table public.signal_predictions
  drop constraint if exists signal_predictions_user_id_journey_id_key;

create unique index if not exists signal_predictions_user_symbol_day_key
  on public.signal_predictions (user_id, symbol, prediction_day);

comment on table public.signal_predictions is
  'Directional calls on a coin. One call per user per coin per UTC day; the journey only records which setup was live when the call was cast.';

commit;
