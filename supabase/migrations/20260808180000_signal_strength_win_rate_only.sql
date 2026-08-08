begin;

-- Product decision: signal strength ranks on the candle win rate alone — the
-- share of ~24h candles whose return beat BTC's. A single pump candle can
-- move it by at most 1/96. The excess-return scalar stays recorded for
-- analysis but no longer feeds the score.
create or replace function public.refresh_relative_strength(p_timeframe text)
returns integer
language sql
security definer
set search_path = public
as $$
with fresh as (
  select distinct on (bs.symbol_id)
         bs.symbol_id, bs.relative_strength_win_rate
    from public.breakout_signals bs
   where bs.timeframe = p_timeframe
     and bs.relative_strength_win_rate is not null
     and bs.candle_close_time >= now() - (case p_timeframe
           when '15m' then interval '2 hours'
           when '1h' then interval '8 hours'
           when '4h' then interval '1 day'
           else interval '4 days'
         end)
   order by bs.symbol_id, bs.candle_close_time desc
),
ranked as (
  select symbol_id,
         round(100 * percent_rank() over (order by relative_strength_win_rate))::integer as pct
    from fresh
),
updated as (
  update public.breakout_signals bs
     set relative_strength_score = ranked.pct
    from ranked
   where bs.symbol_id = ranked.symbol_id
     and bs.timeframe = p_timeframe
     and bs.relative_strength_score is distinct from ranked.pct
  returning 1
)
select count(*)::integer from updated;
$$;

commit;
