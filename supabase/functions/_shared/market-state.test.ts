import {
  assert,
  assertEquals,
} from "https://deno.land/std@0.224.0/assert/mod.ts";
import type { MarketCandle } from "./indicators.ts";
import {
  classifyMarketState,
  marketStateObservation,
  marketStateWindow,
} from "./market-state.ts";

function candle(
  index: number,
  close: number,
  options: {
    open?: number;
    high?: number;
    low?: number;
    quote?: number;
    buyRatio?: number;
  } = {},
): MarketCandle {
  const open = options.open ?? close;
  const high = options.high ?? Math.max(open, close) + 0.35;
  const low = options.low ?? Math.min(open, close) - 0.35;
  const quoteVolume = options.quote ?? 1_000_000;
  const buyRatio = options.buyRatio ?? 0.5;
  return {
    openTime: index * 900_000,
    open,
    high,
    low,
    close,
    volume: quoteVolume / Math.max(close, 1),
    closeTime: (index + 1) * 900_000 - 1,
    quoteVolume,
    trades: 1_000,
    takerBuyBase: quoteVolume * buyRatio / Math.max(close, 1),
    takerBuyQuote: quoteVolume * buyRatio,
  };
}

function baseline(count = 150): MarketCandle[] {
  return Array.from({ length: count }, (_, index) => {
    const close = 100 + Math.sin(index / 5) * 0.8;
    const buyRatio = 0.48 + (index % 5) * 0.01;
    return candle(index, close, {
      quote: 900_000 + (index % 7) * 25_000,
      buyRatio,
    });
  });
}

Deno.test("efficient selling reads as dominant or breakdown risk", () => {
  const candles = baseline();
  let close = candles.at(-1)!.close;
  for (let offset = 0; offset < 8; offset += 1) {
    close -= 0.9;
    candles.push(candle(candles.length, close, {
      open: close + 0.65,
      high: close + 0.8,
      low: close - 0.25,
      quote: 2_400_000,
      buyRatio: 0.25,
    }));
  }
  const result = marketStateObservation(candles, "4h");
  assert(result);
  assert(result.sellingPressure >= 70);
  assert(result.downsideResponse >= 70);
  assert(result.sellerEfficiency >= 50);
  assert(["selling_dominant", "breakdown_risk"].includes(result.state));
});

Deno.test("heavy selling with price holding raises absorption above efficient-selling case", () => {
  const efficient = baseline();
  let falling = efficient.at(-1)!.close;
  for (let offset = 0; offset < 8; offset += 1) {
    falling -= 0.9;
    efficient.push(candle(efficient.length, falling, {
      open: falling + 0.65,
      low: falling - 0.25,
      quote: 2_400_000,
      buyRatio: 0.25,
    }));
  }

  const absorbed = baseline();
  const held = absorbed.at(-1)!.close;
  for (let offset = 0; offset < 8; offset += 1) {
    const close = held + (offset % 2 === 0 ? -0.08 : 0.06);
    absorbed.push(candle(absorbed.length, close, {
      open: close + 0.12,
      high: close + 0.25,
      low: close - 1.15,
      quote: 2_400_000,
      buyRatio: 0.25,
    }));
  }

  const efficientResult = marketStateObservation(efficient, "4h")!;
  const absorbedResult = marketStateObservation(absorbed, "4h")!;
  assert(absorbedResult.sellingPressure >= 70);
  assert(absorbedResult.sellerEfficiency < efficientResult.sellerEfficiency);
  assert(absorbedResult.priceResilience > efficientResult.priceResilience);
  assert(absorbedResult.absorption > efficientResult.absorption);
});

Deno.test("same closed candles produce an identical observation", () => {
  const candles = baseline(170);
  const first = marketStateObservation(candles, "4h");
  const second = marketStateObservation(candles, "4h");
  assertEquals(first, second);
});

Deno.test("neutral has no state strength", () => {
  const result = marketStateObservation(baseline(170), "4h");
  assert(result);
  if (result.state === "neutral") assertEquals(result.stateScore, 0);
});

Deno.test("forming candle is outside the engine contract", () => {
  // The engine is deterministic and has no wall-clock dependency. Closed-only
  // filtering belongs to scan-market; this test locks the scoring version and
  // timestamp to the exact last candle supplied by that caller.
  const candles = baseline(170);
  const result = marketStateObservation(candles, "4h")!;
  assertEquals(result.candleCloseTime, candles.at(-1)!.closeTime);
  assertEquals(result.scoringVersion, "market-state-v4-reversal");
});

Deno.test("market-state window adapts to every supported timeframe", () => {
  const expected = { "15m": 12, "1h": 8, "4h": 6, "1d": 5 } as const;
  const candles = baseline(170);

  for (const [timeframe, window] of Object.entries(expected)) {
    assertEquals(marketStateWindow(timeframe), window);
    assertEquals(
      marketStateObservation(candles, timeframe)?.features.windowCandles,
      window,
    );
  }
});

Deno.test("seller impact fading alone cannot promote weak context to confirmation", () => {
  const metrics = {
    sellingPressure: 54,
    downsideResponse: 17,
    sellerEfficiency: 9,
    efficiencyChange: -4,
    absorption: 12,
    priceResilience: 45,
    bounceReadiness: 10,
    confirmation: 76,
  };

  assertEquals(
    classifyMarketState(metrics, "seller_impact_fading"),
    { state: "neutral", stateScore: 0 },
  );
  assertEquals(
    classifyMarketState(metrics, "buy_side_absorption"),
    { state: "bullish_confirmation", stateScore: 76 },
  );
});

// A coin already trending up has nothing left to reverse. Strong confirmation
// on its own — no absorption context, no bounce readiness — must stay neutral
// rather than earning a continuation state of its own.
Deno.test("pure continuation without reversal context stays neutral", () => {
  const metrics = {
    sellingPressure: 56,
    downsideResponse: 0,
    sellerEfficiency: 0,
    efficiencyChange: -2,
    absorption: 15,
    priceResilience: 56,
    bounceReadiness: 11,
    confirmation: 78,
  };

  assertEquals(
    classifyMarketState(metrics, "neutral"),
    { state: "neutral", stateScore: 0 },
  );
  assertEquals(
    classifyMarketState(metrics, "bullish_confirmation"),
    { state: "neutral", stateScore: 0 },
  );
});
