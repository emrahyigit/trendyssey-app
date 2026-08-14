-- One current, model-independent market state per symbol/timeframe. The app
-- reads this table; it does not present the internal observation history as a
-- journey. History exists only to validate and recalibrate the scoring model.

create table if not exists public.market_state_current (
  symbol_id uuid not null references public.symbols(id) on delete cascade,
  timeframe text not null check (timeframe in ('15m', '1h', '4h', '1d')),
  state text not null check (state in (
    'neutral',
    'selling_dominant',
    'seller_impact_fading',
    'buy_side_absorption',
    'bounce_attempt',
    'bullish_confirmation',
    'breakdown_risk'
  )),
  state_score smallint not null check (state_score between 0 and 100),
  selling_pressure smallint not null check (selling_pressure between 0 and 100),
  downside_response smallint not null check (downside_response between 0 and 100),
  seller_efficiency smallint not null check (seller_efficiency between 0 and 100),
  efficiency_change smallint not null check (efficiency_change between -100 and 100),
  absorption smallint not null check (absorption between 0 and 100),
  price_resilience smallint not null check (price_resilience between 0 and 100),
  bounce_readiness smallint not null check (bounce_readiness between 0 and 100),
  confirmation smallint not null check (confirmation between 0 and 100),
  state_since timestamptz not null,
  candle_close_time timestamptz not null,
  scoring_version text not null,
  raw_features jsonb not null default '{}'::jsonb,
  updated_at timestamptz not null default now(),
  primary key (symbol_id, timeframe)
);

comment on table public.market_state_current is
  'Latest closed-candle market state per symbol/timeframe. Product-facing snapshot, not a journey.';

create index if not exists market_state_current_rank_idx
  on public.market_state_current (timeframe, state, state_score desc);

alter table public.market_state_current enable row level security;
drop policy if exists market_state_current_read on public.market_state_current;
create policy market_state_current_read
  on public.market_state_current for select to authenticated using (true);
grant select on public.market_state_current to authenticated;

create table if not exists public.market_state_history (
  symbol_id uuid not null references public.symbols(id) on delete cascade,
  timeframe text not null check (timeframe in ('15m', '1h', '4h', '1d')),
  candle_close_time timestamptz not null,
  scoring_version text not null,
  state text not null check (state in (
    'neutral',
    'selling_dominant',
    'seller_impact_fading',
    'buy_side_absorption',
    'bounce_attempt',
    'bullish_confirmation',
    'breakdown_risk'
  )),
  state_score smallint not null check (state_score between 0 and 100),
  selling_pressure smallint not null check (selling_pressure between 0 and 100),
  downside_response smallint not null check (downside_response between 0 and 100),
  seller_efficiency smallint not null check (seller_efficiency between 0 and 100),
  efficiency_change smallint not null check (efficiency_change between -100 and 100),
  absorption smallint not null check (absorption between 0 and 100),
  price_resilience smallint not null check (price_resilience between 0 and 100),
  bounce_readiness smallint not null check (bounce_readiness between 0 and 100),
  confirmation smallint not null check (confirmation between 0 and 100),
  raw_features jsonb not null default '{}'::jsonb,
  observed_at timestamptz not null default now(),
  primary key (symbol_id, timeframe, candle_close_time, scoring_version)
);

comment on table public.market_state_history is
  'Closed-candle observations retained for out-of-sample validation and calibration; not exposed as a user journey.';

create index if not exists market_state_history_state_idx
  on public.market_state_history (timeframe, state, candle_close_time desc);

alter table public.market_state_history enable row level security;
-- No client policy by design. scan-market uses the service role and bypasses
-- RLS; validation should run through trusted backend/database code.

