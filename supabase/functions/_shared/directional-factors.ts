/**
 * Quality deductions for spot-long journeys. The breakout quality score is
 * earned by the trigger candle itself; the bearish evidence below can only
 * SUBTRACT from it — there are no bullish bonuses, so a high score stays hard
 * to reach and never inflates:
 *
 *   Quality (base)
 *     − Double Top            (max 8)
 *     − Head & Shoulders      (max 12)
 *     − Rising Wedge          (max 6)
 *     − Low volume            (max 7)
 *     − Weak trend            (max 10)
 *     − Nearby resistance     (max 5)
 *     − High volatility       (max 4)
 *     − Heavy selling volume  (max 4)
 *     − EMA 99 rejection      (max 4)
 *   = Final quality
 *
 * Wire encoding: every factor is stored with score = maxScore − severity, so
 * a full score means "no warning" and 0 means the warning fully fired. The
 * app renders only fired warnings, as signed deductions.
 */

import { atr, type MarketCandle } from "./indicators.ts";
import { type Candle as PatternCandle, patterns } from "./double-pattern.ts";

export interface DirectionalFactor {
  key: string;
  score: number;
  maxScore: number;
  direction: "bearish";
}

const clamp = (value: number, lo = 0, hi = 1) =>
  Math.min(hi, Math.max(lo, value));

function toPatternCandles(candles: MarketCandle[]): PatternCandle[] {
  return candles.map((candle) => ({
    openTime: new Date(candle.openTime),
    closeTime: new Date(candle.closeTime),
    open: candle.open,
    high: candle.high,
    low: candle.low,
    close: candle.close,
    volume: candle.volume,
  }));
}

function emaSeries(values: number[], period: number): number[] {
  const smoothing = 2 / (period + 1);
  const series: number[] = [];
  let current = values[0] ?? 0;
  for (const [index, value] of values.entries()) {
    current = index === 0 ? value : value * smoothing + current * (1 - smoothing);
    series.push(current);
  }
  return series;
}

function pivotIndices(
  candles: MarketCandle[],
  kind: "high" | "low",
  window = 3,
): number[] {
  const indices: number[] = [];
  for (let index = window; index < candles.length - window; index += 1) {
    const price = kind === "high" ? candles[index].high : candles[index].low;
    let isPivot = true;
    for (let other = index - window; other <= index + window; other += 1) {
      if (other === index) continue;
      const otherPrice = kind === "high" ? candles[other].high : candles[other].low;
      if (kind === "high" ? otherPrice > price : otherPrice < price) {
        isPivot = false;
        break;
      }
    }
    if (isPivot) indices.push(index);
  }
  return indices;
}

/** 1 when the anchor candle is recent, fading to 0 at `horizon` candles back. */
function freshness(lastIndex: number, anchorIndex: number, horizon: number): number {
  return clamp(1 - Math.max(0, lastIndex - anchorIndex) / horizon);
}

/** A recent double top argues against upward follow-through. */
function doubleTopSeverity(candles: MarketCandle[]): number {
  const shapes = patterns(toPatternCandles(candles), "bearish");
  const latest = shapes[shapes.length - 1];
  if (!latest) return 0;
  return 8 * freshness(candles.length - 1, latest.secondIndex, 30);
}

/** Three peaks with a higher middle: a topping structure overhead. */
function headShouldersSeverity(candles: MarketCandle[]): number {
  const pivots = pivotIndices(candles, "high");
  if (pivots.length < 3) return 0;
  const [left, head, right] = pivots.slice(-3).map((index) => ({
    index,
    price: candles[index].high,
  }));
  const headStands = head.price > left.price * 1.01 && head.price > right.price * 1.01;
  const shouldersLevel = Math.abs(right.price - left.price) / left.price <= 0.03;
  if (!headStands || !shouldersLevel) return 0;
  return 12 * freshness(candles.length - 1, right.index, 30);
}

/**
 * Rising wedge: price grinding higher while the candle ranges contract — an
 * ascent running out of room rather than a healthy trend.
 */
function risingWedgeSeverity(candles: MarketCandle[], currentATR: number): number {
  const window = candles.slice(-18);
  if (window.length < 18) return 0;
  const early = window.slice(0, 6);
  const late = window.slice(-6);
  const earlyHigh = Math.max(...early.map((candle) => candle.high));
  const earlyLow = Math.min(...early.map((candle) => candle.low));
  const lateHigh = Math.max(...late.map((candle) => candle.high));
  const lateLow = Math.min(...late.map((candle) => candle.low));
  const rising = lateHigh > earlyHigh && lateLow > earlyLow &&
    lateLow - earlyLow >= currentATR * 1.5;
  if (!rising) return 0;
  const earlyRange = early.reduce((sum, candle) => sum + (candle.high - candle.low), 0) / early.length;
  const lateRange = late.reduce((sum, candle) => sum + (candle.high - candle.low), 0) / late.length;
  if (earlyRange <= 0) return 0;
  const contraction = lateRange / earlyRange;
  if (contraction >= 0.7) return 0;
  return 6 * clamp((0.7 - contraction) / 0.4);
}

/** The last closed candle traded well below its 20-candle average volume. */
function lowVolumeSeverity(candles: MarketCandle[]): number {
  const current = candles[candles.length - 1];
  const history = candles.slice(-21, -1);
  if (!current || history.length < 10) return 0;
  const average = history.reduce((sum, candle) => sum + candle.volume, 0) / history.length;
  if (average <= 0) return 0;
  return 7 * clamp((0.85 - current.volume / average) / 0.5);
}

/** EMA stack and slope argue against a sustained upward move. */
function weakTrendSeverity(candles: MarketCandle[]): number {
  if (candles.length < 100) return 0;
  const closes = candles.map((candle) => candle.close);
  const ema7 = emaSeries(closes, 7);
  const ema25 = emaSeries(closes, 25);
  const ema99 = emaSeries(closes, 99);
  const last = candles.length - 1;
  const alignment = (closes[last] > ema25[last] ? 0.40 : 0) +
    (ema25[last] > ema99[last] ? 0.35 : 0) +
    (ema7[last] > ema7[Math.max(0, last - 3)] ? 0.25 : 0);
  return 10 * clamp(1 - alignment);
}

/** A tested resistance sits close overhead, capping the room to run. */
function nearbyResistanceSeverity(candles: MarketCandle[], currentATR: number): number {
  const current = candles[candles.length - 1];
  if (!current) return 0;
  const overhead = pivotIndices(candles, "high")
    .map((index) => candles[index].high)
    .filter((price) => price > current.close);
  if (overhead.length === 0) return 0;
  const nearest = Math.min(...overhead);
  const distance = nearest - current.close;
  if (distance > currentATR * 2.5) return 0;
  return 5 * clamp(1 - distance / (currentATR * 2.5));
}

/** The candle ranges expanded sharply — moves are getting erratic. */
function highVolatilitySeverity(candles: MarketCandle[]): number {
  if (candles.length < 40) return 0;
  const recent = atr(candles);
  const prior = atr(candles.slice(0, -10));
  if (prior <= 0) return 0;
  return 4 * clamp((recent / prior - 1.25) / 0.75);
}

/** Recent volume is elevated and concentrated on falling candles. */
function sellVolumeSeverity(candles: MarketCandle[]): number {
  const recent = candles.slice(-10);
  const baseline = candles.slice(-30);
  if (recent.length < 10 || baseline.length < 20) return 0;
  const total = recent.reduce((sum, candle) => sum + candle.volume, 0);
  if (total <= 0) return 0;
  const downShare = recent
    .filter((candle) => candle.close < candle.open)
    .reduce((sum, candle) => sum + candle.volume, 0) / total;
  const baselineAverage = baseline.reduce((sum, candle) => sum + candle.volume, 0) / baseline.length;
  const elevated = total / recent.length >= baselineAverage * 1.1;
  if (downShare < 0.6 || !elevated) return 0;
  return 4 * clamp((downShare - 0.5) / 0.4);
}

/** Price reached up to EMA 99 and was rejected, staying clearly below it. */
function ema99RejectionSeverity(candles: MarketCandle[]): number {
  if (candles.length < 100) return 0;
  const ema99 = emaSeries(candles.map((candle) => candle.close), 99);
  const currentATR = Math.max(atr(candles), Number.EPSILON);
  const lastIndex = candles.length - 1;
  if (candles[lastIndex].close >= ema99[lastIndex] - currentATR * 0.5) return 0;
  for (let back = 0; back < 5; back += 1) {
    const index = lastIndex - back;
    if (index < 0) break;
    const reachedUp = candles[index].high >= ema99[index] * 0.999;
    const closedRejected = candles[index].close <= ema99[index] - currentATR * 0.3;
    if (reachedUp && closedRejected) return 4 * clamp(1 - back / 5);
  }
  return 0;
}

/** All nine deductions, computed on closed candles. */
export function directionalFactors(candles: MarketCandle[]): DirectionalFactor[] {
  const currentATR = Math.max(atr(candles), Number.EPSILON);
  const deductions: Array<[string, number, number]> = [
    ["doubleTop", doubleTopSeverity(candles), 8],
    ["headShoulders", headShouldersSeverity(candles), 12],
    ["risingWedge", risingWedgeSeverity(candles, currentATR), 6],
    ["lowVolume", lowVolumeSeverity(candles), 7],
    ["weakTrend", weakTrendSeverity(candles), 10],
    ["nearbyResistance", nearbyResistanceSeverity(candles, currentATR), 5],
    ["highVolatility", highVolatilitySeverity(candles), 4],
    ["sellVolume", sellVolumeSeverity(candles), 4],
    ["ema99Rejection", ema99RejectionSeverity(candles), 4],
  ];
  return deductions.map(([key, severity, maxScore]) => ({
    key,
    score: maxScore - Math.round(clamp(severity, 0, maxScore)),
    maxScore,
    direction: "bearish" as const,
  }));
}

/** Signed quality adjustment: 0 when nothing fired, negative otherwise. */
export function directionalAdjustment(factors: DirectionalFactor[]): number {
  return factors.reduce((sum, factor) => sum + factor.score - factor.maxScore, 0);
}

/**
 * Subtracts the fired deductions from a quality score. A score of 0 means no
 * breakout is being scored, and deductions must not resurrect one.
 */
export function applyDirectionalAdjustment(
  quality: number,
  factors: DirectionalFactor[],
): number {
  if (quality <= 0) return quality;
  return Math.max(1, Math.min(100, Math.round(quality + directionalAdjustment(factors))));
}
