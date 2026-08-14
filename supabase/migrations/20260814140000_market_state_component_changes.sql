begin;

-- Each visible component gets its own close-to-close delta. Keeping these in
-- product data makes the colored badges deterministic across every client.
alter table public.market_state_current
  add column if not exists selling_pressure_change smallint,
  add column if not exists downside_response_change smallint,
  add column if not exists seller_efficiency_change smallint,
  add column if not exists absorption_change smallint,
  add column if not exists price_resilience_change smallint,
  add column if not exists bounce_readiness_change smallint,
  add column if not exists confirmation_change smallint;

alter table public.market_state_history
  add column if not exists selling_pressure_change smallint,
  add column if not exists downside_response_change smallint,
  add column if not exists seller_efficiency_change smallint,
  add column if not exists absorption_change smallint,
  add column if not exists price_resilience_change smallint,
  add column if not exists bounce_readiness_change smallint,
  add column if not exists confirmation_change smallint;

alter table public.market_state_current
  add constraint market_state_current_selling_pressure_change_check check (selling_pressure_change is null or selling_pressure_change between -100 and 100),
  add constraint market_state_current_downside_response_change_check check (downside_response_change is null or downside_response_change between -100 and 100),
  add constraint market_state_current_seller_efficiency_change_check check (seller_efficiency_change is null or seller_efficiency_change between -100 and 100),
  add constraint market_state_current_absorption_change_check check (absorption_change is null or absorption_change between -100 and 100),
  add constraint market_state_current_price_resilience_change_check check (price_resilience_change is null or price_resilience_change between -100 and 100),
  add constraint market_state_current_bounce_readiness_change_check check (bounce_readiness_change is null or bounce_readiness_change between -100 and 100),
  add constraint market_state_current_confirmation_change_check check (confirmation_change is null or confirmation_change between -100 and 100);

alter table public.market_state_history
  add constraint market_state_history_selling_pressure_change_check check (selling_pressure_change is null or selling_pressure_change between -100 and 100),
  add constraint market_state_history_downside_response_change_check check (downside_response_change is null or downside_response_change between -100 and 100),
  add constraint market_state_history_seller_efficiency_change_check check (seller_efficiency_change is null or seller_efficiency_change between -100 and 100),
  add constraint market_state_history_absorption_change_check check (absorption_change is null or absorption_change between -100 and 100),
  add constraint market_state_history_price_resilience_change_check check (price_resilience_change is null or price_resilience_change between -100 and 100),
  add constraint market_state_history_bounce_readiness_change_check check (bounce_readiness_change is null or bounce_readiness_change between -100 and 100),
  add constraint market_state_history_confirmation_change_check check (confirmation_change is null or confirmation_change between -100 and 100);

with ranked as (
  select
    symbol_id,
    timeframe,
    candle_close_time,
    scoring_version,
    lag(selling_pressure) over state_window as previous_selling_pressure,
    lag(downside_response) over state_window as previous_downside_response,
    lag(seller_efficiency) over state_window as previous_seller_efficiency,
    lag(absorption) over state_window as previous_absorption,
    lag(price_resilience) over state_window as previous_price_resilience,
    lag(bounce_readiness) over state_window as previous_bounce_readiness,
    lag(confirmation) over state_window as previous_confirmation
  from public.market_state_history
  window state_window as (
    partition by symbol_id, timeframe, scoring_version
    order by candle_close_time
  )
)
update public.market_state_history h
set selling_pressure_change = h.selling_pressure - r.previous_selling_pressure,
    downside_response_change = h.downside_response - r.previous_downside_response,
    seller_efficiency_change = h.seller_efficiency - r.previous_seller_efficiency,
    absorption_change = h.absorption - r.previous_absorption,
    price_resilience_change = h.price_resilience - r.previous_price_resilience,
    bounce_readiness_change = h.bounce_readiness - r.previous_bounce_readiness,
    confirmation_change = h.confirmation - r.previous_confirmation
from ranked r
where r.symbol_id = h.symbol_id
  and r.timeframe = h.timeframe
  and r.candle_close_time = h.candle_close_time
  and r.scoring_version = h.scoring_version;

with previous as (
  select
    c.symbol_id,
    c.timeframe,
    p.selling_pressure,
    p.downside_response,
    p.seller_efficiency,
    p.absorption,
    p.price_resilience,
    p.bounce_readiness,
    p.confirmation
  from public.market_state_current c
  left join lateral (
    select
      h.selling_pressure,
      h.downside_response,
      h.seller_efficiency,
      h.absorption,
      h.price_resilience,
      h.bounce_readiness,
      h.confirmation
    from public.market_state_history h
    where h.symbol_id = c.symbol_id
      and h.timeframe = c.timeframe
      and h.scoring_version = c.scoring_version
      and h.candle_close_time < c.candle_close_time
    order by h.candle_close_time desc
    limit 1
  ) p on true
)
update public.market_state_current c
set selling_pressure_change = c.selling_pressure - p.selling_pressure,
    downside_response_change = c.downside_response - p.downside_response,
    seller_efficiency_change = c.seller_efficiency - p.seller_efficiency,
    absorption_change = c.absorption - p.absorption,
    price_resilience_change = c.price_resilience - p.price_resilience,
    bounce_readiness_change = c.bounce_readiness - p.bounce_readiness,
    confirmation_change = c.confirmation - p.confirmation
from previous p
where p.symbol_id = c.symbol_id and p.timeframe = c.timeframe;

commit;
