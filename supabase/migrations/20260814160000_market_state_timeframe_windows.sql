begin;

-- Scenario must follow the scoring version currently active for each symbol.
-- This prevents old and new window policies from producing duplicate state
-- transitions after a scoring-version rollout.
create or replace function public.market_state_scenario_entries(
  p_timeframe text,
  p_since timestamptz,
  p_limit integer default 800
)
returns table (
  symbol_id uuid,
  symbol text,
  state text,
  state_score smallint,
  state_score_change smallint,
  candle_close_time timestamptz,
  close_price numeric,
  quote_volume_24h numeric
)
language sql
stable
security definer
set search_path = public
as $$
  with active_history as (
    select h.*
    from public.market_state_history h
    join public.market_state_current c
      on c.symbol_id = h.symbol_id
     and c.timeframe = h.timeframe
     and c.scoring_version = h.scoring_version
    where h.timeframe = p_timeframe
  ), ordered as (
    select h.symbol_id, h.timeframe, h.state, h.state_score,
           h.state_score_change, h.candle_close_time, h.close_price,
           h.quote_volume_24h,
           lag(h.state) over (
             partition by h.symbol_id, h.timeframe
             order by h.candle_close_time
           ) as previous_state
    from active_history h
  )
  select o.symbol_id, s.symbol, o.state, o.state_score,
         o.state_score_change, o.candle_close_time, o.close_price,
         coalesce(o.quote_volume_24h, s.quote_volume_24h, 0)
  from ordered o
  join public.symbols s on s.id = o.symbol_id
  where o.candle_close_time >= p_since
    and o.state is distinct from o.previous_state
  order by o.candle_close_time desc,
           coalesce(o.quote_volume_24h, s.quote_volume_24h, 0) desc
  limit greatest(1, least(coalesce(p_limit, 800), 2000));
$$;

revoke all on function public.market_state_scenario_entries(text, timestamptz, integer)
  from public, anon;
grant execute on function public.market_state_scenario_entries(text, timestamptz, integer)
  to authenticated;

-- A same-candle re-score during a model rollout is not a fresh market event
-- and must not enqueue a notification even when its newly calculated state is
-- different. The next genuinely closed candle remains eligible.
drop trigger if exists market_state_notification_matcher_update
  on public.market_state_current;

create trigger market_state_notification_matcher_update
  after update of state on public.market_state_current
  for each row when (
    old.state is distinct from new.state
    and old.candle_close_time is distinct from new.candle_close_time
  )
  execute function public.enqueue_market_state_notifications();

commit;
