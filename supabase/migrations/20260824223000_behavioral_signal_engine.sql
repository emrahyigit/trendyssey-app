-- Separate broad context, simultaneous behavioral states and confirmed signals.
-- JSONB keeps the evidence vocabulary evolvable without turning every V1
-- feature into a permanent table column. Core sortable metrics remain typed.

begin;

do $$
declare
  target text;
begin
  foreach target in array array['market_state_current', 'market_state_history'] loop
    execute format($f$
      alter table public.%I
        add column if not exists market_context jsonb not null default '{}'::jsonb,
        add column if not exists behavioral_scores jsonb not null default '{}'::jsonb,
        add column if not exists behavioral_signals jsonb not null default '[]'::jsonb
    $f$, target);
  end loop;
end $$;

create index if not exists market_state_current_behavioral_signals_gin
  on public.market_state_current using gin (behavioral_signals);

comment on column public.market_state_current.market_context is
  'Broad EMA25/EMA99 regime context; not itself a trading signal.';
comment on column public.market_state_current.behavioral_scores is
  'Simultaneous exhaustion, response and expansion scores.';
comment on column public.market_state_current.behavioral_signals is
  'Developing and confirmed trajectory/structure signals with evidence.';

commit;
