import { momentumExcessVsBTC, TREND_MINIMUM_CANDLES, trendScoreObservation } from "./trend_score.ts";
import type { MarketCandle } from "./indicators.ts";

/** Builds a series whose closes follow `path(i)`; highs/lows hug the close. */
function series(count: number, path: (index: number) => number): MarketCandle[] {
  const result: MarketCandle[] = [];
  for (let index = 0; index < count; index += 1) {
    const close = path(index);
    result.push({
      openTime: index * 60_000,
      open: close * 0.998,
      high: close * 1.004,
      low: close * 0.994,
      close,
      volume: 1_000,
      closeTime: index * 60_000 + 59_999,
      quoteVolume: close * 1_000,
      trades: 500,
      takerBuyBase: 500,
      takerBuyQuote: close * 520,
    });
  }
  return result;
}

const flat = (base: number) => (index: number) => base + Math.sin(index) * base * 0.001;

Deno.test("a regime-aligned breakout that outruns BTC scores high and fires the entry", () => {
  // Long quiet base, then a steady climb that clears the 55-high on the last candle.
  const coin = series(200, (i) => i < 170 ? 100 + Math.sin(i) * 0.4 : 100 + (i - 169) * 0.35);
  // Force a decisive final breakout close above every prior high.
  coin.at(-1)!.close = 115;
  coin.at(-1)!.high = 115.2;
  const btc = series(200, flat(50_000));
  const observation = trendScoreObservation(coin, btc)!;
  if (!observation.freshBreakout) throw new Error("Expected the last close to clear the 55-high for the first time.");
  if (!observation.regimeAligned) throw new Error("Expected EMA25 > EMA99 with price above EMA99.");
  if (!(observation.momentumExcess! > 0)) throw new Error("Expected the coin to outrun a flat BTC.");
  if (!observation.entrySignal) throw new Error("All three ingredients aligned — the entry must fire.");
  if (observation.score < 80) throw new Error(`Expected a high score, got ${observation.score}.`);
});

Deno.test("a downtrend scores low and never fires the entry", () => {
  const coin = series(200, (i) => 200 - i * 0.5);
  const btc = series(200, flat(50_000));
  const observation = trendScoreObservation(coin, btc)!;
  if (observation.entrySignal) throw new Error("A falling coin must not present an entry.");
  if (observation.score > 35) throw new Error(`Expected a weak score, got ${observation.score}.`);
  if (observation.components.regime !== 0) throw new Error("EMA25 under EMA99 must zero the regime component.");
});

Deno.test("the components always sum to the score", () => {
  for (const path of [flat(10), (i: number) => 10 + i * 0.01, (i: number) => 30 - i * 0.05]) {
    const observation = trendScoreObservation(series(150, path), series(150, flat(50_000)))!;
    const sum = observation.components.breakout + observation.components.regime +
      observation.components.momentum + observation.components.health;
    if (sum !== observation.score) throw new Error(`Components sum to ${sum}, score says ${observation.score}.`);
  }
});

Deno.test("missing BTC data scores the neutral momentum midpoint", () => {
  const coin = series(150, (i) => 100 + i * 0.2);
  const observation = trendScoreObservation(coin, [])!;
  if (observation.momentumExcess !== null) throw new Error("Unalignable BTC data must read as null.");
  if (observation.components.momentum !== 10) throw new Error("Null momentum must score the midpoint 10/20.");
  if (observation.entrySignal) throw new Error("Without a measured momentum edge the A+ entry must not fire.");
});

Deno.test("BTC itself reads exactly neutral", () => {
  const btc = series(150, (i) => 50_000 + i * 25);
  const observation = trendScoreObservation(btc, btc, { isBTC: true })!;
  if (observation.momentumExcess !== 0) throw new Error("BTC's excess vs itself must be 0.");
  if (observation.components.momentum !== 10) throw new Error("BTC must score the neutral midpoint 10/20.");
});

Deno.test("freshBreakout is true only on the crossing candle", () => {
  const coin = series(200, (i) => i < 195 ? 100 + Math.sin(i) * 0.3 : 104 + (i - 194) * 1.5);
  const observation = trendScoreObservation(coin, series(200, flat(50_000)))!;
  if (observation.freshBreakout) throw new Error("The 55-high was already cleared on an earlier candle.");
  if (!(observation.clearanceAtr > 0)) throw new Error("Price should still sit above the level.");
});

Deno.test("too little history returns null instead of a fabricated score", () => {
  const coin = series(TREND_MINIMUM_CANDLES - 1, flat(10));
  if (trendScoreObservation(coin, []) !== null) throw new Error("Short history must not be scored.");
});

Deno.test("momentum alignment matches candles by closeTime, not by index", () => {
  const coin = series(150, (i) => 100 + i * 0.1);
  // BTC series shifted by half a candle: no closeTime overlaps, so no read.
  const btc = series(150, flat(50_000)).map((candle) => ({
    ...candle,
    closeTime: candle.closeTime + 30_000,
  }));
  if (momentumExcessVsBTC(coin, btc) !== null) throw new Error("Misaligned closeTimes must yield null, not a bogus excess.");
});
