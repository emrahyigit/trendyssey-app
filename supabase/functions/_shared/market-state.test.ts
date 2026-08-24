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

/** Every metric the classifier reads, at a deliberately inert midpoint. */
function inertMetrics(overrides: Record<string, number> = {}) {
  return {
    sellerPressure: 20,
    buyerPressure: 20,
    sellerEfficiency: 20,
    buyerEfficiency: 20,
    downsideResponse: 20,
    upsideResponse: 20,
    buySideAbsorption: 10,
    sellSideAbsorption: 10,
    sellerEfficiencyTrend: 0,
    buyerEfficiencyTrend: 0,
    sellerPressureTrend: 0,
    buyerPressureTrend: 0,
    bullishConfirmation: 0,
    bearishConfirmation: 0,
    ...overrides,
  };
}

Deno.test("efficient selling reads as seller dominance", () => {
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
  assert(result.sellerPressure >= 70);
  assert(result.downsideResponse >= 70);
  assertEquals(result.state, "seller_dominance");
});

Deno.test("efficient buying reads as buyer dominance", () => {
  const candles = baseline();
  let close = candles.at(-1)!.close;
  for (let offset = 0; offset < 8; offset += 1) {
    close += 0.9;
    candles.push(candle(candles.length, close, {
      open: close - 0.65,
      high: close + 0.25,
      low: close - 0.8,
      quote: 2_400_000,
      buyRatio: 0.75,
    }));
  }
  const result = marketStateObservation(candles, "4h");
  assert(result);
  assert(result.buyerPressure >= 70);
  assert(result.upsideResponse >= 70);
  assertEquals(result.state, "buyer_dominance");
});

Deno.test("both sides can press hard at once", () => {
  // Share of volume is a complement, so a share-based pair could never do
  // this. Intensity against each side's own baseline can.
  const candles = baseline();
  let close = candles.at(-1)!.close;
  for (let offset = 0; offset < 8; offset += 1) {
    close += offset % 2 === 0 ? -0.15 : 0.15;
    candles.push(candle(candles.length, close, {
      open: close - 0.1,
      high: close + 1.6,
      low: close - 1.6,
      quote: 6_000_000,
      buyRatio: 0.5,
    }));
  }
  const result = marketStateObservation(candles, "4h");
  assert(result);
  assert(
    result.sellerPressure >= 60 && result.buyerPressure >= 60,
    `expected both sides high, got seller=${result.sellerPressure} buyer=${result.buyerPressure}`,
  );
});

Deno.test("heavy selling with price holding raises buy-side absorption", () => {
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
  assert(absorbedResult.sellerPressure >= 70);
  assert(absorbedResult.sellerEfficiency < efficientResult.sellerEfficiency);
  assert(absorbedResult.buySideAbsorption > efficientResult.buySideAbsorption);
});

Deno.test("same closed candles produce an identical observation", () => {
  const candles = baseline(170);
  const first = marketStateObservation(candles, "4h");
  const second = marketStateObservation(candles, "4h");
  assertEquals(first, second);
});

Deno.test("forming candle is outside the engine contract", () => {
  // The engine is deterministic and has no wall-clock dependency. Closed-only
  // filtering belongs to scan-market; this test locks the scoring version and
  // timestamp to the exact last candle supplied by that caller.
  const candles = baseline(170);
  const result = marketStateObservation(candles, "4h")!;
  assertEquals(result.candleCloseTime, candles.at(-1)!.closeTime);
  assertEquals(result.scoringVersion, "market-state-v6-evidence");
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

Deno.test("absorption gives way once the other side has moved price", () => {
  // Heavy selling, sellers getting nowhere, buyers already 90 on the response:
  // a stalemate this is not, whatever the absorption score says.
  const metrics = inertMetrics({
    sellerPressure: 99,
    sellerEfficiency: 5,
    buySideAbsorption: 80,
    buyerPressure: 95,
    buyerEfficiency: 81,
    upsideResponse: 90,
  });
  assertEquals(
    classifyMarketState(metrics, "buy_side_absorption").state,
    "buyer_dominance",
  );

  // With price pinned instead, the same absorption reading still holds.
  const pinned = { ...metrics, upsideResponse: 20, buyerEfficiency: 20 };
  assertEquals(
    classifyMarketState(pinned, "buy_side_absorption").state,
    "buy_side_absorption",
  );
});

Deno.test("readiness reads location and coiling, not the absorption beside it", () => {
  // A sell-off that then goes quiet and tightens right on its low: absorption
  // has nothing left to feed on, but the ground for a turn is exactly here.
  const coiled = baseline();
  let close = coiled.at(-1)!.close;
  for (let offset = 0; offset < 8; offset += 1) {
    close -= 0.9;
    coiled.push(candle(coiled.length, close, {
      open: close + 0.65,
      low: close - 0.25,
      quote: 2_400_000,
      buyRatio: 0.25,
    }));
  }
  for (let offset = 0; offset < 6; offset += 1) {
    coiled.push(candle(coiled.length, close + 0.02, {
      open: close,
      high: close + 0.08,
      low: close - 0.30,
      quote: 400_000,
      buyRatio: 0.5,
    }));
  }
  const settled = marketStateObservation(coiled, "4h")!;
  assert(
    settled.bounceReadiness > settled.buySideAbsorption,
    `readiness ${settled.bounceReadiness} should outlive absorption ${settled.buySideAbsorption}`,
  );

  // Mid-range drift gives neither side a floor to turn from.
  const drifting = marketStateObservation(baseline(170), "4h")!;
  assert(drifting.bounceReadiness < 60);
});

Deno.test("an empty market is low participation, not balanced", () => {
  assertEquals(
    classifyMarketState(inertMetrics()).state,
    "low_participation",
  );
});

Deno.test("an active market with no clear claim is balanced, not neutral", () => {
  const metrics = inertMetrics({ sellerPressure: 58, buyerPressure: 54 });
  assertEquals(
    classifyMarketState(metrics).state,
    "balanced",
  );
});

Deno.test("selling that stops landing reads as impact fading", () => {
  const metrics = inertMetrics({
    sellerPressure: 68,
    sellerEfficiency: 30,
    sellerEfficiencyTrend: -18,
    downsideResponse: 25,
  });
  assertEquals(
    classifyMarketState(metrics, "seller_dominance").state,
    "seller_impact_fading",
  );
});

Deno.test("buying that stops landing mirrors it", () => {
  const metrics = inertMetrics({
    buyerPressure: 68,
    buyerEfficiency: 30,
    buyerEfficiencyTrend: -18,
    upsideResponse: 25,
  });
  assertEquals(
    classifyMarketState(metrics, "buyer_dominance").state,
    "buyer_impact_fading",
  );
});

Deno.test("intensity dying after a sell-off reads as seller exhaustion", () => {
  const metrics = inertMetrics({
    sellerPressure: 30,
    sellerPressureTrend: -25,
    downsideResponse: 20,
  });
  assertEquals(
    classifyMarketState(metrics, "seller_impact_fading").state,
    "seller_exhaustion",
  );
  // Without a preceding sell-off there is nothing to be exhausted from.
  assertEquals(
    classifyMarketState(metrics, "buyer_dominance").state,
    "low_participation",
  );
});

Deno.test("control changing hands outranks the absorption it grew out of", () => {
  const metrics = inertMetrics({
    sellerPressure: 62,
    sellerEfficiency: 30,
    sellerEfficiencyTrend: -12,
    buySideAbsorption: 70,
    buyerEfficiency: 62,
    buyerEfficiencyTrend: 14,
    upsideResponse: 55,
    bullishConfirmation: 70,
  });
  assertEquals(
    classifyMarketState(metrics, "buy_side_absorption").state,
    "buyer_takeover",
  );
});

Deno.test("a takeover needs closed-candle evidence, not just a rising trend", () => {
  const metrics = inertMetrics({
    sellerPressure: 62,
    sellerEfficiency: 30,
    sellerEfficiencyTrend: -12,
    buySideAbsorption: 70,
    buyerEfficiency: 62,
    buyerEfficiencyTrend: 14,
    upsideResponse: 55,
    bullishConfirmation: 20,
  });
  assertEquals(
    classifyMarketState(metrics, "buy_side_absorption").state,
    "buy_side_absorption",
  );
});

Deno.test("sellers retaking control after a rally mirrors the buyer path", () => {
  const metrics = inertMetrics({
    buyerPressure: 62,
    buyerEfficiency: 30,
    buyerEfficiencyTrend: -12,
    sellSideAbsorption: 70,
    sellerEfficiency: 62,
    sellerEfficiencyTrend: 14,
    downsideResponse: 55,
    bearishConfirmation: 70,
  });
  assertEquals(
    classifyMarketState(metrics, "sell_side_absorption").state,
    "seller_takeover",
  );
});

Deno.test("absorption holds through a weaker reading once it is established", () => {
  const metrics = inertMetrics({
    sellerPressure: 60,
    sellerEfficiency: 35,
    buySideAbsorption: 58,
  });
  assertEquals(
    classifyMarketState(metrics, "buy_side_absorption").state,
    "buy_side_absorption",
  );
  // The same reading is not strong enough to declare absorption from scratch.
  assertEquals(
    classifyMarketState(metrics, "balanced").state,
    "balanced",
  );
});

Deno.test("every state scores on the same scale", () => {
  // A reading that only just clears its bar sits at the bottom of the band,
  // and one that clears every condition outright sits at the top — whichever
  // state it is. Before this, dominance averaged 90 and absorption could not
  // pass 93, so one threshold could never mean the same thing twice.
  const barelyDominant = inertMetrics({
    sellerPressure: 60, downsideResponse: 50, sellerEfficiency: 50,
  });
  const barelyAbsorbing = inertMetrics({
    sellerPressure: 55, sellerEfficiency: 45, buySideAbsorption: 55,
  });
  for (const metrics of [barelyDominant, barelyAbsorbing]) {
    const { stateScore } = classifyMarketState(metrics, "buy_side_absorption");
    assert(
      stateScore >= 45 && stateScore <= 60,
      `a bare qualification should sit near 50, got ${stateScore}`,
    );
  }

  const emphatic = classifyMarketState(inertMetrics({
    sellerPressure: 100, downsideResponse: 100, sellerEfficiency: 100,
  }));
  assertEquals(emphatic.state, "seller_dominance");
  assertEquals(emphatic.stateScore, 100);
});

Deno.test("a thin market that still moves price is not quiet", () => {
  // PROM on 15m: barely any flow on either side, yet price had travelled and
  // buyers were converting it efficiently. Flow alone called that asleep.
  const thinButMoving = inertMetrics({
    sellerPressure: 14,
    buyerPressure: 31,
    buyerEfficiency: 61,
    upsideResponse: 48,
    buyerEfficiencyTrend: 30,
  });
  assert(classifyMarketState(thinButMoving).state !== "low_participation");

  const genuinelyAsleep = inertMetrics({ sellerPressure: 14, buyerPressure: 31 });
  assertEquals(
    classifyMarketState(genuinelyAsleep).state,
    "low_participation",
  );
});
