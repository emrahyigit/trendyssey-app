begin;

-- The scanner now writes relative_strength_raw as a WINSORIZED cumulative
-- excess return: per-candle (coin − BTC) log-return differences summed after
-- clamping each candle's contribution to ±2%. One pump candle can no longer
-- monopolize the ranking; sustained quiet strength accumulates past it. The
-- ranking function is unchanged — it still percent_ranks this scalar.
comment on column public.breakout_signals.relative_strength_raw is
  'Winsorized cumulative excess log return vs BTC over the 16-candle window: per-candle differences summed after clamping each to ±2%. 0 = moved with BTC (BTC itself scores 0). Ranked into relative_strength_score by refresh_relative_strength().';

commit;
