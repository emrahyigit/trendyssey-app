// Tournament-winner lifecycle (Aug 2026). The EMA 7/25 crossover journey is
// retired: entries and outcomes now follow the strongest combination in the
// ~40,000-trade backtest (see _shared/trend_score.ts).
//
//   watching         — no setup; price sits well below the 55-candle high
//   pre_breakout     — price within half an ATR below the 55-high
//   breakout_detected — a closed candle FRESHLY cleared the prior 55-candle
//                      high (its predecessor had not); entry price = that
//                      candle's close, and the candle's ATR freezes the trail
//                      width. A+ journeys are the subset where regime
//                      (EMA25>EMA99, price above) and momentum vs BTC also
//                      aligned on the entry candle.
//   confirmed        — "Breakout Hold": price TOUCHED entry + 1.5×ATR. The
//                      hold is permanent; +3×ATR upgrades the tier.
//   failed           — price touched the chandelier trail (highest high since
//                      entry minus 3×ATR, ratcheting up, never down) before
//                      any hold. When one candle spans both, the stop counts
//                      first — never more optimistic than reality could prove.
//   expired          — neither side within the horizon; neutral, not a failure.
// deno-lint-ignore-file no-explicit-any

import { CHANDELIER_ATR_MULTIPLIER, type TrendScoreObservation } from "./trend_score.ts";

/** Success touch, in entry-candle ATRs. The old +1% flat threshold treated a
 * 15m candle and a daily candle identically; ATR scales it to the market. */
export const SUCCESS_ATR = 1.5;
/** Tier-10 touch, in entry-candle ATRs. */
export const UPGRADE_ATR = 3;

/** 3× the old ~24h window — the exit horizon the backtest validated. */
export const JOURNEY_HORIZON_CANDLES: Record<string, number> = {
  "15m": 288,
  "1h": 72,
  "4h": 18,
  "1d": 21,
};

/** Hysteresis for the waiting phase: enter within 0.5 ATR below the 55-high,
 * leave only after falling 0.8 ATR below it. */
const PRE_BREAKOUT_ENTER_ATR = -0.5;
const PRE_BREAKOUT_LEAVE_ATR = -0.8;

export interface JourneyFacts {
  entryPrice: number;
  /** ATR(14) on the entry candle; freezes the trail width for the journey. */
  entryAtr: number;
  /** Highest high since entry, BEFORE the current candle. The stop the
   * current candle is judged against uses this value — an intrabar high must
   * never save the same candle's low. */
  highWatermark: number;
}

export function nextSignalState(
  previous: string,
  trend: TrendScoreObservation | null,
  facts: JourneyFacts,
  currentCandle: { high: number; low: number },
  journeyAge: number,
  isNewCandle: boolean,
  horizonCandles: number,
): string {
  if (!isNewCandle) return previous;

  if (previous === "breakout_detected" && facts.entryPrice > 0 && facts.entryAtr > 0) {
    const trail = facts.highWatermark - CHANDELIER_ATR_MULTIPLIER * facts.entryAtr;
    // Stop before target inside the same candle: the conservative rule the
    // backtest and the scenario replay share.
    if (currentCandle.low <= trail) return "failed";
    if (currentCandle.high >= facts.entryPrice + SUCCESS_ATR * facts.entryAtr) return "confirmed";
    if (journeyAge >= horizonCandles) return "expired";
    return previous;
  }

  if (previous === "confirmed") {
    // Success already banked; the journey just runs out its clock.
    return journeyAge >= horizonCandles ? "expired" : previous;
  }

  // watching / pre_breakout / failed / expired — look for the next breakout.
  if (!trend) return previous === "pre_breakout" ? "pre_breakout" : "watching";
  if (trend.freshBreakout) return "breakout_detected";
  if (trend.clearanceAtr >= PRE_BREAKOUT_ENTER_ATR && trend.clearanceAtr <= 0) return "pre_breakout";
  if (previous === "pre_breakout" && trend.clearanceAtr >= PRE_BREAKOUT_LEAVE_ATR && trend.clearanceAtr <= 0) {
    return "pre_breakout";
  }
  return "watching";
}

/** The watermark the NEXT candle's stop is judged against: only after the
 * current candle survived its own check may its high raise the trail. */
export function nextHighWatermark(facts: JourneyFacts, currentCandle: { high: number }): number {
  return Math.max(facts.highWatermark, currentCandle.high);
}

/** 10 when the +3×ATR tier was touched, 5 once the +1.5×ATR hold banked. */
export function successTier(
  current: { high: number },
  facts: JourneyFacts,
  previousTier: number,
): number {
  if (facts.entryPrice <= 0 || facts.entryAtr <= 0) return previousTier;
  if (current.high >= facts.entryPrice + UPGRADE_ATR * facts.entryAtr) return 10;
  if (previousTier >= 10) return 10;
  if (current.high >= facts.entryPrice + SUCCESS_ATR * facts.entryAtr) return Math.max(previousTier, 5);
  return previousTier;
}
