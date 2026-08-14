// Trend score — the tournament winner of Aug 2026.
//
// Seven entry methods and four exit rules were backtested on the top-100
// universe across all four timeframes (~10,000 trades per combination,
// 0.2% round-trip fees). The strongest combination on every timeframe:
//
//   entry  — a close above the prior 55-candle high (Donchian-55 breakout),
//            while EMA25 > EMA99 with price above EMA99 (regime), and the
//            coin's 20-candle return beats BTC's (momentum);
//   exit   — a 3×ATR chandelier trailing stop, no fixed target.
//
// Net expectancy per trade: 1h +0.78% (pf 1.38), 4h +1.38% (pf 1.42),
// 1d +3.64% (pf 1.48); 15m barely clears fees (+0.11%). Removing any one
// ingredient lowered expectancy on every timeframe, so all three are scored.
//
// This module turns those exact ingredients into one 0–100 score. The four
// components always sum to the score, so a detail page can explain it the
// same way the unified EMA score is explained today.
import { atr, type MarketCandle } from "./indicators.ts";

export const TREND_BREAKOUT_PERIOD = 55;
export const TREND_MOMENTUM_CANDLES = 20;
export const CHANDELIER_ATR_MULTIPLIER = 3.0;
/** Highest-high lookback feeding the chandelier stop, current candle included. */
export const CHANDELIER_LOOKBACK = 22;
/** The exit horizon the backtest validated: 3× the journey horizon. */
export const TREND_HORIZON_MULTIPLIER = 3;

export const TREND_WEIGHTS = {
  breakout: 40,
  regime: 25,
  momentum: 20,
  health: 15,
} as const;

export interface TrendScoreObservation {
  /** 0–100; always the exact sum of the four components. */
  score: number;
  /** The backtested A+ entry: fresh 55-high breakout + regime + momentum. */
  entrySignal: boolean;
  components: {
    breakout: number;
    regime: number;
    momentum: number;
    health: number;
  };
  /** Highest high of the prior 55 candles (current candle excluded). */
  breakoutLevel: number;
  /** (close − breakoutLevel) / ATR; negative below the level. */
  clearanceAtr: number;
  /** True only on the candle whose close first clears the 55-high. */
  freshBreakout: boolean;
  regimeAligned: boolean;
  /** 20-candle return minus BTC's, aligned by closeTime; null when BTC data
   * could not be aligned (scores the neutral midpoint). BTC itself reads 0. */
  momentumExcess: number | null;
  /** Suggested trailing invalidation: highest high of the last 22 candles
   * minus 3×ATR. Price closing below it zeroes the health component. */
  chandelierStop: number;
}

const clamp = (value: number, minimum = 0, maximum = 1) =>
  Math.min(maximum, Math.max(minimum, value));

function emaSeries(values: number[], period: number): number[] {
  if (values.length === 0) return [];
  const multiplier = 2 / (period + 1);
  const result = [values[0]];
  for (const value of values.slice(1)) {
    result.push(value * multiplier + result.at(-1)! * (1 - multiplier));
  }
  return result;
}

/** Coin return minus BTC return over the last TREND_MOMENTUM_CANDLES candles,
 * matched by closeTime so a lagging BTC fetch cannot skew the read. */
export function momentumExcessVsBTC(
  coin: MarketCandle[],
  btc: MarketCandle[],
): number | null {
  if (coin.length < TREND_MOMENTUM_CANDLES + 1) return null;
  const last = coin.at(-1)!;
  const base = coin.at(-(TREND_MOMENTUM_CANDLES + 1))!;
  if (base.close <= 0) return null;
  const coinReturn = last.close / base.close - 1;
  const btcByClose = new Map(btc.map((candle) => [candle.closeTime, candle.close]));
  const btcLast = btcByClose.get(last.closeTime);
  const btcBase = btcByClose.get(base.closeTime);
  if (btcLast === undefined || btcBase === undefined || btcBase <= 0) return null;
  return coinReturn - (btcLast / btcBase - 1);
}

/** Minimum history: EMA99 needs seasoning and the 55-high needs 55 closed
 * candles of context. Matches the EMA engine's practical floor. */
export const TREND_MINIMUM_CANDLES = 121;

export function trendScoreObservation(
  candles: MarketCandle[],
  btcCandles: MarketCandle[],
  options: { isBTC?: boolean } = {},
): TrendScoreObservation | null {
  if (candles.length < TREND_MINIMUM_CANDLES) return null;
  const current = candles.at(-1)!;
  const previous = candles.at(-2)!;
  const closes = candles.map((candle) => candle.close);
  const currentATR = Math.max(atr(candles), Number.EPSILON);

  // Breakout — a close above the prior 55-candle high (current candle
  // excluded, same convention as the Donchian engine).
  const history = candles.slice(0, -1).slice(-TREND_BREAKOUT_PERIOD);
  const breakoutLevel = Math.max(...history.map((candle) => candle.high));
  const clearanceAtr = (current.close - breakoutLevel) / currentATR;
  // "Fresh" compares the previous close against ITS OWN prior-55 window: in a
  // steady climb every candle clears the level that includes its predecessor's
  // high, so comparing against the current window would flag them all.
  const previousWindow = candles.slice(0, -2).slice(-TREND_BREAKOUT_PERIOD);
  const previousLevel = previousWindow.length > 0
    ? Math.max(...previousWindow.map((candle) => candle.high))
    : breakoutLevel;
  const freshBreakout = previous.close <= previousLevel &&
    current.close > breakoutLevel;
  const breakout = current.close > breakoutLevel
    ? Math.round(25 + 15 * clamp(clearanceAtr / 1))
    : Math.round(15 * clamp(1 + clearanceAtr / 1));

  // Regime — the EMA25/EMA99 structure that filtered out bear-market traps.
  const ema25 = emaSeries(closes, 25).at(-1)!;
  const ema99 = emaSeries(closes, 99).at(-1)!;
  const stackAligned = ema25 > ema99;
  const aboveLong = current.close > ema99;
  const regimeAligned = stackAligned && aboveLong;
  const regime = (stackAligned ? 15 : 0) + (aboveLong ? 10 : 0);

  // Momentum — 20-candle return vs BTC. BTC itself and unalignable data score
  // the neutral midpoint; only measured strength moves the needle.
  const momentumExcess = options.isBTC ? 0 : momentumExcessVsBTC(candles, btcCandles);
  const momentum = momentumExcess === null || options.isBTC
    ? Math.round(TREND_WEIGHTS.momentum / 2)
    : Math.round(TREND_WEIGHTS.momentum * clamp((momentumExcess + 0.02) / 0.06));

  // Health — distance above the chandelier stop, the exit that won the
  // tournament. Full points with price at the recent high, zero at the stop.
  const recent = candles.slice(-CHANDELIER_LOOKBACK);
  const recentHigh = Math.max(...recent.map((candle) => candle.high));
  const chandelierStop = recentHigh - CHANDELIER_ATR_MULTIPLIER * currentATR;
  const health = Math.round(
    TREND_WEIGHTS.health *
      clamp((current.close - chandelierStop) / currentATR / CHANDELIER_ATR_MULTIPLIER),
  );

  const components = { breakout, regime, momentum, health };
  return {
    score: breakout + regime + momentum + health,
    entrySignal: freshBreakout && regimeAligned &&
      momentumExcess !== null && momentumExcess > 0,
    components,
    breakoutLevel,
    clearanceAtr,
    freshBreakout,
    regimeAligned,
    momentumExcess,
    chandelierStop,
  };
}
