import {
  analyzeLevelBreakout,
  applyBreakoutStateScores,
  nextLevelSignalState,
} from "./breakout-engine.ts";
import type { MarketCandle } from "./indicators.ts";

function candles(count: number, breakout = false): MarketCandle[] {
  const result: MarketCandle[] = [];
  for (let index = 0; index < count; index += 1) {
    const base = 100 + index * 0.015;
    const isLast = index === count - 1;
    const close = isLast && breakout ? 105 : base + 0.08;
    result.push({
      openTime: index * 3_600_000,
      closeTime: (index + 1) * 3_600_000 - 1,
      open: isLast && breakout ? 104.1 : base,
      high: isLast && breakout ? 105.2 : base + 0.35,
      low: base - 0.25,
      close,
      volume: isLast && breakout ? 2_000 : 1_000,
      quoteVolume: isLast && breakout ? 206_000 : 100_000,
      trades: isLast && breakout ? 2_000 : 1_000,
      takerBuyBase: 500,
      takerBuyQuote: isLast && breakout ? 135_000 : 52_000,
    });
  }
  return result;
}

Deno.test("Donchian excludes the current candle from its level", () => {
  const input = candles(260, true);
  const result = analyzeLevelBreakout(input, "donchian", {}, "1h", {
    period: 20,
  });
  if (!(result.level < input.at(-1)!.close)) {
    throw new Error("Current breakout candle leaked into the channel.");
  }
  if (!result.priceBrokeOut) {
    throw new Error("Expected the last close to clear the prior channel.");
  }
});

Deno.test("the four scores stay on their declared scales", () => {
  const result = analyzeLevelBreakout(
    candles(260, true),
    "donchian",
    {},
    "1h",
    {
      period: 20,
      btcScore: 12,
      status: "breakout_detected",
    },
  );
  for (const [name, value] of Object.entries(result.scores)) {
    if (typeof value === "number" && (value < 0 || value > 100)) {
      throw new Error(`${name} escaped 0...100: ${value}`);
    }
  }
});

Deno.test("level lifecycle requires a closed-candle cross", () => {
  const input = candles(260, true);
  const result = analyzeLevelBreakout(input, "donchian", {}, "1h", {
    period: 20,
  });
  const state = nextLevelSignalState("watching", result, result.level, 0, true);
  if (state !== "breakout_detected") {
    throw new Error(`Unexpected state: ${state}`);
  }
});

Deno.test("horizontal and consolidation engines produce explicit levels", () => {
  const input = candles(260, false);
  for (const engine of ["horizontal_level", "consolidation"] as const) {
    const result = analyzeLevelBreakout(input, engine, {}, "1h", {
      period: 20,
    });
    if (!Number.isFinite(result.level) || result.level <= 0) {
      throw new Error(`${engine} did not produce a valid level.`);
    }
    if (result.engineKind !== engine) {
      throw new Error(`${engine} was dispatched as ${result.engineKind}.`);
    }
  }
});

Deno.test("an active level journey expires after its configured window", () => {
  const result = analyzeLevelBreakout(
    candles(260, true),
    "donchian",
    {},
    "1h",
    {
      period: 20,
    },
  );
  const state = nextLevelSignalState(
    "confirmed",
    result,
    result.level,
    99,
    true,
  );
  if (state !== "expired") {
    throw new Error(`Unexpected terminal state: ${state}`);
  }
});

Deno.test("retest preserves the quality of the candle that triggered the breakout", () => {
  const initial = analyzeLevelBreakout(
    candles(260, true),
    "donchian",
    {},
    "1h",
    { period: 20 },
  );
  const retestCandle = {
    ...initial,
    priceBrokeOut: false,
  };
  const rescored = applyBreakoutStateScores(retestCandle, "retest", 12, 64);
  if (rescored.scores.breakoutQualityScore !== 64) {
    throw new Error(
      `Trigger quality was not preserved: ${rescored.scores.breakoutQualityScore}`,
    );
  }
  if (rescored.scores.confirmationScore <= 0) {
    throw new Error("Retest confirmation must still be calculated dynamically.");
  }
});
