begin;

-- Only the globally active scoring version belongs in Scenario. Symbols that
-- have fallen outside today's top-100 universe may retain an older current row
-- for audit purposes, but must not leak that retired model into product data.
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
  with active_version as (
    select c.scoring_version
    from public.market_state_current c
    group by c.scoring_version
    order by max(c.updated_at) desc
    limit 1
  ), active_history as (
    select h.*
    from public.market_state_history h
    join public.market_state_current c
      on c.symbol_id = h.symbol_id
     and c.timeframe = h.timeframe
     and c.scoring_version = h.scoring_version
    join active_version v on v.scoring_version = h.scoring_version
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

commit;
