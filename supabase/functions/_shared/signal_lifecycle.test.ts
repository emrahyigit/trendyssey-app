import {
  JOURNEY_HORIZON_CANDLES,
  nextHighWatermark,
  nextSignalState,
  SUCCESS_ATR,
  successTier,
} from "./signal_lifecycle.ts";
import type { TrendScoreObservation } from "./trend_score.ts";

function observation(overrides: Partial<TrendScoreObservation>): TrendScoreObservation {
  return {
    score: 50,
    entrySignal: false,
    components: { breakout: 20, regime: 15, momentum: 10, health: 5 },
    breakoutLevel: 100,
    clearanceAtr: -2,
    freshBreakout: false,
    regimeAligned: true,
    momentumExcess: 0.01,
    chandelierStop: 95,
    ...overrides,
  };
}

const noJourney = { entryPrice: 0, entryAtr: 0, highWatermark: 0 };

Deno.test("a fresh 55-high breakout starts the journey from any idle state", () => {
  const trend = observation({ freshBreakout: true, clearanceAtr: 0.4 });
  for (const state of ["watching", "pre_breakout", "failed", "expired"]) {
    const next = nextSignalState(state, trend, noJourney, { high: 101, low: 99 }, 0, true, 288);
    if (next !== "breakout_detected") throw new Error(`${state} -> ${next}, expected breakout_detected.`);
  }
});

Deno.test("the trail counts before the hold inside one candle", () => {
  // Entry 100, ATR 2: trail at 94, hold line at 103. A candle spanning both
  // must fail — never more optimistic than reality could prove.
  const facts = { entryPrice: 100, entryAtr: 2, highWatermark: 100 };
  const next = nextSignalState("breakout_detected", null, facts, { high: 104, low: 93 }, 1, true, 288);
  if (next !== "failed") throw new Error(`Expected failed, got ${next}.`);
});

Deno.test("touching entry + 1.5×ATR banks a permanent hold", () => {
  const facts = { entryPrice: 100, entryAtr: 2, highWatermark: 100 };
  const held = nextSignalState("breakout_detected", null, facts, { high: 100 + SUCCESS_ATR * 2, low: 99 }, 1, true, 288);
  if (held !== "confirmed") throw new Error(`Expected confirmed, got ${held}.`);
  const later = nextSignalState("confirmed", null, facts, { high: 90, low: 80 }, 2, true, 288);
  if (later !== "confirmed") throw new Error("A banked hold must survive any later drop.");
});

Deno.test("the watermark ratchets the trail up scan by scan", () => {
  // Watermark 110 -> trail 104: a low of 105 survives, and only then may the
  // candle's high of 112 raise the watermark for the next scan.
  const facts = { entryPrice: 100, entryAtr: 2, highWatermark: 110 };
  const next = nextSignalState("confirmed", null, facts, { high: 112, low: 105 }, 3, true, 288);
  if (next !== "confirmed") throw new Error(`Expected confirmed, got ${next}.`);
  if (nextHighWatermark(facts, { high: 112 }) !== 112) throw new Error("Watermark must rise to the surviving candle's high.");
  const stopped = nextSignalState("breakout_detected", null, { ...facts, highWatermark: 112 }, { high: 109, low: 105.9 }, 4, true, 288);
  if (stopped !== "failed") throw new Error("The raised trail (106) must catch the next dip.");
});

Deno.test("legacy journeys without ATR facts reset quietly instead of crashing", () => {
  const trend = observation({});
  const next = nextSignalState("breakout_detected", trend, noJourney, { high: 101, low: 99 }, 5, true, 288);
  if (next !== "watching") throw new Error(`Expected a quiet reset to watching, got ${next}.`);
});

Deno.test("pre-breakout uses ATR proximity with hysteresis", () => {
  const near = observation({ clearanceAtr: -0.3 });
  if (nextSignalState("watching", near, noJourney, { high: 1, low: 1 }, 0, true, 288) !== "pre_breakout") {
    throw new Error("Within half an ATR below the high must wait for breakout.");
  }
  const drifting = observation({ clearanceAtr: -0.7 });
  if (nextSignalState("pre_breakout", drifting, noJourney, { high: 1, low: 1 }, 0, true, 288) !== "pre_breakout") {
    throw new Error("Hysteresis: leaving requires falling past 0.8 ATR.");
  }
  if (nextSignalState("watching", drifting, noJourney, { high: 1, low: 1 }, 0, true, 288) !== "watching") {
    throw new Error("Entering requires half an ATR, not 0.8.");
  }
});

Deno.test("success tier upgrades at +3×ATR and the horizon tripled", () => {
  const facts = { entryPrice: 100, entryAtr: 2, highWatermark: 100 };
  if (successTier({ high: 103 }, facts, 0) !== 5) throw new Error("+1.5×ATR must bank tier 5.");
  if (successTier({ high: 106 }, facts, 5) !== 10) throw new Error("+3×ATR must upgrade to tier 10.");
  if (JOURNEY_HORIZON_CANDLES["1h"] !== 72) throw new Error("The 1h horizon must be 72 candles (3×24h).");
});
