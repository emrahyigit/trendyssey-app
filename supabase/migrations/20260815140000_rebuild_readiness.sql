-- Readiness returns, rebuilt out of ingredients absorption does not carry.
--
-- The dropped version weighted absorption at 0.55 and measured 0.87 correlated
-- with it. Its distinctive parts were never the problem: against absorption,
-- lower-wick rejection measures -0.01, location -0.17 and compression -0.40.
-- The new score is those three alone, so it says something absorption cannot —
-- above all it survives after absorption fades, which is when a base is
-- actually forming.
--
-- Price resilience returns as a shorthand rather than a new fact: it stays
-- pressure x (1 - response), both of which the card already shows.

begin;

do $$
declare
  target text;
begin
  foreach target in array array['market_state_current', 'market_state_history'] loop
    execute format($f$
      alter table public.%I
        add column if not exists bounce_readiness smallint not null default 0,
        add column if not exists bounce_readiness_change smallint,
        add column if not exists rollover_readiness smallint not null default 0,
        add column if not exists rollover_readiness_change smallint,
        add column if not exists buyer_resilience smallint not null default 0,
        add column if not exists buyer_resilience_change smallint,
        add column if not exists seller_resilience smallint not null default 0,
        add column if not exists seller_resilience_change smallint
    $f$, target);
  end loop;
end $$;

commit;
