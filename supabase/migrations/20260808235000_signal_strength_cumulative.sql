begin;

-- Product decision: signal strength ranks on the CUMULATIVE excess return —
-- the sum of per-candle (coin − BTC) log-return differences over the 16-candle
-- window, stored as relative_strength_raw. The signed scalar is normalized to
-- 0-100 with percent_rank across the scanned universe rather than by dividing
-- by the maximum: the percentile is outlier-proof (one pump coin cannot crush
-- everyone else's score) and needs no separate shift to make negatives
-- positive. Supersedes the win-rate-only scoring of 20260808180000; the win
-- rate stays recorded for analysis.
create or replace function public.refresh_relative_strength(p_timeframe text)
returns integer
language sql
security definer
set search_path = public
as $$
with fresh as (
  select distinct on (bs.symbol_id)
         bs.symbol_id, bs.relative_strength_raw
    from public.breakout_signals bs
   where bs.timeframe = p_timeframe
     and bs.relative_strength_raw is not null
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
         round(100 * percent_rank() over (order by relative_strength_raw))::integer as pct
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
