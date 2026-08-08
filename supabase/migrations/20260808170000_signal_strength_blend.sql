begin;

-- Signal strength becomes a 50/50 blend of two percentiles, so a single-candle
-- pump cannot carry the score alone:
--   - excess return (relative_strength_raw): total ~24h move vs BTC
--   - win rate (relative_strength_win_rate): share of candles that beat BTC —
--     one pump candle moves this by only 1/96
-- Backtest (864 entries, 30d): endpoint alone separated +11.2/+3.9 points on
-- the +2/-2 and +5/-3 rules; win rate alone +7.8/+11.5; the blend +10.3/+7.6 —
-- the only variant strong on both.

alter table public.breakout_signals
  add column if not exists relative_strength_win_rate double precision;

comment on column public.breakout_signals.relative_strength_win_rate is
  'Share of ~24h candles whose return beat BTC''s (0-1). Blended with relative_strength_raw into relative_strength_score.';

create or replace function public.refresh_relative_strength(p_timeframe text)
returns integer
language sql
security definer
set search_path = public
as $$
with fresh as (
  select distinct on (bs.symbol_id)
         bs.symbol_id, bs.relative_strength_raw, bs.relative_strength_win_rate
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
         round(
           50 * percent_rank() over (order by relative_strength_raw)
           -- Rows scanned before the win-rate column shipped rank neutrally
           -- on that half instead of dropping out.
           + 50 * percent_rank() over (order by coalesce(relative_strength_win_rate, 0.5))
         )::integer as pct
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
