-- Readiness and resilience were restatements of numbers already on screen.
--
-- Measured across 3,500 recorded observations:
--   rollover_readiness vs sell_side_absorption   r = 0.92
--   bounce_readiness   vs buy_side_absorption    r = 0.87
--   buyer_resilience   vs (100 - downside_response) r = 0.78
--
-- Readiness carries 0.55 weight on the absorption it sits next to, and
-- resilience is literally pressure x (1 - response), both of which the card
-- already shows. Four rows of a six-row card were spending space to repeat two
-- of the other rows, so the derived pair goes and the four core dimensions
-- stay.

begin;

do $$
declare
  target text;
begin
  foreach target in array array['market_state_current', 'market_state_history'] loop
    execute format($f$
      alter table public.%I
        drop column if exists bounce_readiness,
        drop column if exists bounce_readiness_change,
        drop column if exists rollover_readiness,
        drop column if exists rollover_readiness_change,
        drop column if exists buyer_resilience,
        drop column if exists buyer_resilience_change,
        drop column if exists seller_resilience,
        drop column if exists seller_resilience_change
    $f$, target);
  end loop;
end $$;

commit;
