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
