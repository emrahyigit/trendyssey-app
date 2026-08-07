import {
  applyDirectionalAdjustment,
  directionalAdjustment,
  directionalFactors,
} from "./directional-factors.ts";
import type { MarketCandle } from "./indicators.ts";

function candle(
  index: number,
  open: number,
  close: number,
  options: { high?: number; low?: number; volume?: number } = {},
): MarketCandle {
  const high = options.high ?? Math.max(open, close) * 1.002;
  const low = options.low ?? Math.min(open, close) * 0.998;
  const volume = options.volume ?? 100;
  return {
    openTime: index * 60_000,
    closeTime: (index + 1) * 60_000 - 1,
    open,
    close,
    high,
    low,
    volume,
    quoteVolume: volume * close,
    trades: 100,
    takerBuyBase: volume / 2,
    takerBuyQuote: volume * close / 2,
  };
}

/** Flat drift with mild noise so ATR stays small and stable. */
function drift(count: number, level: number, startIndex = 0): MarketCandle[] {
  return Array.from({ length: count }, (_, offset) => {
    const wobble = level * 0.001 * (offset % 3 - 1);
    return candle(startIndex + offset, level + wobble, level - wobble);
  });
}

function ramp(
  count: number,
  from: number,
  to: number,
  startIndex = 0,
  volume = 100,
): MarketCandle[] {
  return Array.from({ length: count }, (_, offset) => {
    const open = from + (to - from) * (offset / count);
    const close = from + (to - from) * ((offset + 1) / count);
    return candle(startIndex + offset, open, close, { volume });
  });
}

function severity(candles: MarketCandle[], key: string): number {
  const factor = directionalFactors(candles).find((f) => f.key === key)!;
  return factor.maxScore - factor.score;
}

Deno.test("structural warnings stay quiet on flat drift", () => {
  const candles = drift(120, 100);
  for (const key of ["doubleTop", "headShoulders", "risingWedge", "sellVolume", "ema99Rejection"]) {
    if (severity(candles, key) > 0) throw new Error(`${key} fired on flat drift`);
  }
});

Deno.test("a rising wedge fires when an ascent contracts", () => {
  const base = drift(60, 100);
  // Grinding higher: rising highs and lows with shrinking candle ranges.
  const wedge = Array.from({ length: 18 }, (_, offset) => {
    const level = 100 + offset * 0.35;
    const range = 1.4 * (1 - offset / 24);
    return candle(60 + offset, level, level + 0.1, {
      high: level + range / 2,
      low: level - range / 2,
    });
  });
  if (severity([...base, ...wedge], "risingWedge") <= 0) {
    throw new Error("rising wedge not detected");
  }
});

Deno.test("low volume on the last closed candle is a deduction", () => {
  const candles = [...drift(60, 100), candle(60, 100, 100.4, { volume: 30 })];
  if (severity(candles, "lowVolume") <= 0) throw new Error("low volume did not fire");
});

Deno.test("heavy selling volume fires the warning", () => {
  const candles = [
    ...drift(60, 100),
    ...ramp(10, 100, 88, 60, 400), // falling closes on heavy volume
  ];
  if (severity(candles, "sellVolume") <= 0) throw new Error("sell volume did not fire");
});

Deno.test("a rejection at EMA 99 fires while price stays below it", () => {
  const candles = [
    ...drift(100, 100),
    ...ramp(12, 100, 90, 100),
    candle(112, 90, 89.4, { high: 99.6 }),
    candle(113, 89.4, 89, {}),
  ];
  if (severity(candles, "ema99Rejection") <= 0) throw new Error("EMA99 rejection did not fire");
});

Deno.test("a falling market reads as a weak trend", () => {
  const candles = [...drift(80, 100), ...ramp(30, 100, 84, 80)];
  if (severity(candles, "weakTrend") <= 0) throw new Error("weak trend did not fire");
});

Deno.test("resistance right overhead is a deduction, cleared resistance is not", () => {
  const capped = [...drift(80, 100), ...ramp(10, 100, 100.2, 80)];
  if (severity(capped, "nearbyResistance") <= 0) {
    throw new Error("nearby resistance did not fire under the ceiling");
  }
  const cleared = [...drift(80, 100), ...ramp(15, 100, 115, 80)];
  if (severity(cleared, "nearbyResistance") > 0) {
    throw new Error("nearby resistance fired after price left the zone behind");
  }
});

Deno.test("deductions only subtract, and never resurrect a zero quality", () => {
  const factors = [
    { key: "doubleTop", score: 3, maxScore: 8, direction: "bearish" as const },
    { key: "lowVolume", score: 7, maxScore: 7, direction: "bearish" as const },
  ];
  if (directionalAdjustment(factors) !== -5) throw new Error("adjustment math wrong");
  if (applyDirectionalAdjustment(80, factors) !== 75) throw new Error("apply wrong");
  if (applyDirectionalAdjustment(0, factors) !== 0) throw new Error("must not resurrect quality");
  if (applyDirectionalAdjustment(3, factors) !== 1) throw new Error("must floor at 1");
});
