-- Resilience is a defence, so it belongs to the side that did not press.
-- Buyers earn it when heavy selling fails to move price down; sellers earn it
-- when heavy buying fails to move price up. The single price_resilience column
-- only ever described the buyers' half, so it is renamed and given its mirror.

begin;

do $$
declare
  target text;
begin
  foreach target in array array['market_state_current', 'market_state_history'] loop
    execute format('alter table public.%I rename column price_resilience to buyer_resilience', target);
    execute format('alter table public.%I rename column price_resilience_change to buyer_resilience_change', target);
    execute format($f$
      alter table public.%I
        add column if not exists seller_resilience smallint,
        add column if not exists seller_resilience_change smallint
    $f$, target);
  end loop;
end $$;

commit;
