/**
 * Strength against BTC — the classic relative-strength read, scored as one
 * confidence ingredient. Two things are measured over the last 12 closed
 * candles of the scanned timeframe:
 *
 *   - excess return: the coin's return minus BTC's return over the window;
 *   - resilience: on the candles BTC closed red, how often the coin still
 *     closed flat or green. A coin that holds while BTC drops has demand of
 *     its own, so its breakout is less likely to be a BTC-tide artifact.
 *
 * BTC itself (and any window without enough aligned candles) scores the
 * neutral midpoint instead of being punished for missing data.
 */

export const BTC_STRENGTH_WINDOW = 12;
export const BTC_STRENGTH_MAX_SCORE = 15;
export const NEUTRAL_BTC_STRENGTH = 7;
/**
 * At or below this score the coin is measurably weaker than BTC, and the
 * engines cap the total confidence at 69: a breakout that only exists because
 * BTC is pulling the market can never present as high-confidence.
 */
export const WEAK_BTC_STRENGTH = 3;
/** The confidence ceiling applied while strength vs BTC is weak. */
export const WEAK_BTC_CONFIDENCE_CAP = 69;
/** Below this many aligned candles the read is noise, not a measurement. */
const MINIMUM_SAMPLES = 6;

interface CandleLike {
  closeTime: number;
  open: number;
  close: number;
}

export interface BTCStrengthObservation {
  score: number;
  coinReturn: number;
  btcReturn: number;
  excessReturn: number;
  /** Null when BTC printed no red candle inside the window. */
  resilience: number | null;
  samples: number;
}

/**
 * The standalone relative-strength layer, independent from the small
 * btcStrength confidence ingredient above. Two stages:
 *
 *   1. Here: the raw SCALAR — the coin's excess log return vs BTC over ~24h
 *      of candles. Signed, unbounded, and exactly 0 for a coin that moved
 *      one-to-one with BTC (BTC itself is written as 0 by the scanner).
 *      "BTC fell 1% while the coin rose 2%" scores +3% here.
 *   2. In the database (refresh_relative_strength): once every coin's scalar
 *      is stored, it is ranked into a 0-100 percentile across the scanned
 *      universe. That percentile is what users see.
 *
 * Validated on 30 days of 15m breakouts (Aug 2026, 864 entries): entries with
 * a positive 24h excess return hit +2%-before--2% at 51-53% vs 43-46% for
 * negative ones; the split held on the +5%/-3% rule (40% vs 29-36%). Only the
 * 15m window is validated; the others use proportional windows.
 */
// Product decision (Aug 2026): a uniform 16-candle window on every
// timeframe — 4h of context on 15m candles. Reacts to fresh strength much
// faster than the earlier ~24h window.
export const RELATIVE_STRENGTH_WINDOWS: Record<string, number> = {
  "15m": 16,
  "1h": 16,
  "4h": 16,
  "1d": 16,
};

export interface RelativeStrengthObservation {
  coinReturn: number;
  btcReturn: number;
  excessReturn: number;
  /** Share of DECISIVE candles the coin's return beat BTC's by more than the
   * dead zone. Differences under ±1% are treated as dead candles — they count
   * for neither side. Neutral 0.5 when no candle was decisive. */
  winRate: number;
  windowCandles: number;
  samples: number;
}

export function relativeStrengthObservation(
  coin: CandleLike[],
  btc: CandleLike[],
  timeframe: string,
): RelativeStrengthObservation | null {
  const windowCandles = RELATIVE_STRENGTH_WINDOWS[timeframe] ?? 24;
  if (coin.length === 0 || btc.length === 0) return null;
  const btcByClose = new Map(btc.map((candle) => [candle.closeTime, candle]));
  const aligned = coin
    .slice(-(windowCandles + 1))
    .map((candle) => ({ coin: candle, btc: btcByClose.get(candle.closeTime) }))
    .filter((pair): pair is { coin: CandleLike; btc: CandleLike } => pair.btc !== undefined);
  // Below half the window the read compares different spans of time.
  if (aligned.length < Math.max(4, Math.floor(windowCandles / 2))) return null;
  const first = aligned[0];
  const last = aligned[aligned.length - 1];
  if (first.coin.close <= 0 || first.btc.close <= 0) return null;
  const coinReturn = Math.log(last.coin.close / first.coin.close);
  const btcReturn = Math.log(last.btc.close / first.btc.close);
  const DEAD_ZONE = 0.01; // ±1% per candle: anything smaller is a dead candle
  let wins = 0;
  let decisive = 0;
  for (let i = 1; i < aligned.length; i += 1) {
    const coinStep = Math.log(aligned[i].coin.close / aligned[i - 1].coin.close);
    const btcStep = Math.log(aligned[i].btc.close / aligned[i - 1].btc.close);
    const difference = coinStep - btcStep;
    if (Math.abs(difference) < DEAD_ZONE) continue;
    decisive += 1;
    if (difference > 0) wins += 1;
  }
  return {
    coinReturn,
    btcReturn,
    excessReturn: coinReturn - btcReturn,
    winRate: decisive > 0 ? wins / decisive : 0.5,
    windowCandles,
    samples: aligned.length,
  };
}

export function btcStrengthObservation(
  coin: CandleLike[],
  btc: CandleLike[],
): BTCStrengthObservation | null {
  if (coin.length === 0 || btc.length === 0) return null;
  const btcByClose = new Map(btc.map((candle) => [candle.closeTime, candle]));
  const aligned = coin
    .slice(-BTC_STRENGTH_WINDOW)
    .map((candle) => ({ coin: candle, btc: btcByClose.get(candle.closeTime) }))
    .filter((pair): pair is { coin: CandleLike; btc: CandleLike } => pair.btc !== undefined);
  if (aligned.length < MINIMUM_SAMPLES) return null;

  const first = aligned[0];
  const last = aligned[aligned.length - 1];
  const coinReturn = first.coin.open > 0 ? last.coin.close / first.coin.open - 1 : 0;
  const btcReturn = first.btc.open > 0 ? last.btc.close / first.btc.open - 1 : 0;
  const excessReturn = coinReturn - btcReturn;

  const redCandles = aligned.filter((pair) => pair.btc.close < pair.btc.open);
  const heldOnRed = redCandles.filter((pair) => pair.coin.close >= pair.coin.open).length;
  const resilience = redCandles.length > 0 ? heldOnRed / redCandles.length : null;

  // 0-9 from the excess return, 0-6 from red-candle resilience; a quiet BTC
  // window (no red candles) scores the resilience part neutrally.
  const excessScore = excessReturn >= 0.05
    ? 9
    : excessReturn >= 0.02
    ? 7
    : excessReturn >= 0.005
    ? 6
    : excessReturn >= -0.005
    ? 4
    : excessReturn >= -0.02
    ? 3
    : excessReturn >= -0.05
    ? 1
    : 0;
  const resilienceScore = resilience === null
    ? 3
    : resilience >= 0.75
    ? 6
    : resilience >= 0.5
    ? 4
    : resilience >= 0.25
    ? 2
    : 0;

  return {
    score: excessScore + resilienceScore,
    coinReturn,
    btcReturn,
    excessReturn,
    resilience,
    samples: aligned.length,
  };
}
