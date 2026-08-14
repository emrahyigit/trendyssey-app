// Market-state engine.
//
// This deliberately does not model a journey. It answers one question from
// the latest closed-candle window: what is the market doing now? Historical
// rows exist for validation, but the product consumes one current state per
// symbol and timeframe.
//
// The product hunts reversals. A coin that is already advancing is not a
// reversal candidate, so continuation is deliberately not a declared state —
// sustained upside with nothing left to turn around resolves to neutral.

import { atr, ema, type MarketCandle } from "./indicators.ts";

export const MARKET_STATE_SCORING_VERSION = "market-state-v4-reversal";

// Short timeframes need a wider sample to suppress single-candle noise, while
// long timeframes need a tighter sample so the declared state does not lag by
// weeks. Each window is compared with the immediately preceding equal window.
export const MARKET_STATE_WINDOWS = {
  "15m": 12, // 3 hours
  "1h": 8, // 8 hours
  "4h": 6, // 24 hours
  "1d": 5, // 5 days
} as const;

export type MarketStateTimeframe = keyof typeof MARKET_STATE_WINDOWS;

export function marketStateWindow(timeframe: string): number {
  return MARKET_STATE_WINDOWS[timeframe as MarketStateTimeframe] ??
    MARKET_STATE_WINDOWS["4h"];
}
const BASELINE_WINDOWS = 120;

export type MarketState =
  | "neutral"
  | "selling_dominant"
  | "seller_impact_fading"
  | "buy_side_absorption"
  | "bounce_attempt"
  | "bullish_confirmation"
  | "breakdown_risk";

export interface MarketStateObservation {
  state: MarketState;
  stateScore: number;
  sellingPressure: number;
  downsideResponse: number;
  sellerEfficiency: number;
  efficiencyChange: number;
  absorption: number;
  priceResilience: number;
  bounceReadiness: number;
  confirmation: number;
  candleCloseTime: number;
  scoringVersion: string;
  features: {
    windowCandles: number;
    sellRatio: number;
    sellIntensity: number;
    negativeCvdRatio: number;
    downsideAtr: number;
    newLowProgressAtr: number;
    bearishCloseFraction: number;
    bullishCloseFraction: number;
    upsideAtr: number;
    lowerWickRejection: number;
    priceCvdDivergence: number;
    nearLow: number;
    nearHigh: number;
    compression: number;
    volumeExpansion: number;
    buyParticipation: number;
    swingHighBreak: boolean;
    positiveDeltaTurn: boolean;
    bullishBody: number;
    ema7Reclaim: boolean;
  };
}

interface RawWindow {
  sellRatio: number;
  sellIntensity: number;
  negativeCvdRatio: number;
  pressureRaw: number;
  responseRaw: number;
  downsideAtr: number;
  newLowProgressAtr: number;
  bearishCloseFraction: number;
  bullishCloseFraction: number;
  upsideAtr: number;
  impactRaw: number;
  lowerWickRejection: number;
  priceCvdDivergence: number;
  nearLow: number;
  nearHigh: number;
  compression: number;
  volumeExpansion: number;
  buyParticipation: number;
  swingHighBreak: boolean;
  positiveDeltaTurn: boolean;
  bullishBody: number;
  ema7Reclaim: boolean;
}

const clamp = (value: number, minimum = 0, maximum = 1) =>
  Math.min(maximum, Math.max(minimum, value));
const average = (values: number[]) =>
  values.length === 0
    ? 0
    : values.reduce((sum, value) => sum + value, 0) / values.length;
const median = (values: number[]) => {
  if (values.length === 0) return 0;
  const ordered = [...values].sort((left, right) => left - right);
  const middle = Math.floor(ordered.length / 2);
  return ordered.length % 2 === 0
    ? (ordered[middle - 1] + ordered[middle]) / 2
    : ordered[middle];
};
const score = (value: number) => Math.round(clamp(value) * 100);
const round = (value: number, digits = 4) => Number(value.toFixed(digits));

/** Percentile rank against history only. Ties share the middle of their band. */
function percentileRank(history: number[], value: number): number {
  if (history.length === 0) return 0.5;
  let below = 0;
  let equal = 0;
  for (const historical of history) {
    if (historical < value) below += 1;
    else if (historical === value) equal += 1;
  }
  return clamp((below + equal * 0.5) / history.length);
}

function quoteDelta(candle: MarketCandle): number {
  return 2 * candle.takerBuyQuote - candle.quoteVolume;
}

function lowerWickRatio(candle: MarketCandle): number {
  const range = Math.max(candle.high - candle.low, Number.EPSILON);
  return clamp((Math.min(candle.open, candle.close) - candle.low) / range);
}

function rawWindowAt(
  candles: MarketCandle[],
  index: number,
  window: number,
): RawWindow | null {
  if (index < window * 2 || index >= candles.length) return null;

  const recent = candles.slice(index - window + 1, index + 1);
  const prior = candles.slice(index - window * 2 + 1, index - window + 1);
  const current = candles[index];
  const previous = candles[index - 1];
  const base = candles[index - window];
  const currentAtr = Math.max(atr(candles.slice(0, index + 1)), Number.EPSILON);
  const recentQuote = recent.reduce(
    (sum, candle) => sum + candle.quoteVolume,
    0,
  );
  const recentSell = recent.reduce(
    (sum, candle) =>
      sum + Math.max(0, candle.quoteVolume - candle.takerBuyQuote),
    0,
  );
  const priorSellPerCandle = prior.map((candle) =>
    Math.max(0, candle.quoteVolume - candle.takerBuyQuote)
  );
  const baselineSell = Math.max(
    median(priorSellPerCandle) * window,
    Number.EPSILON,
  );
  const sellRatio = recentQuote > 0 ? recentSell / recentQuote : 0.5;
  const sellIntensity = recentSell / baselineSell;
  const recentDelta = recent.reduce(
    (sum, candle) => sum + quoteDelta(candle),
    0,
  );
  const negativeCvdRatio = recentQuote > 0
    ? clamp(-recentDelta / recentQuote)
    : 0;
  const negativeDeltaPersistence =
    recent.filter((candle) => quoteDelta(candle) < 0).length / window;

  // Pressure has an intuitive raw scale. The final score is its historical
  // percentile, so a large and a small coin remain comparable.
  const pressureRaw = 0.45 * clamp((sellRatio - 0.45) / 0.25) +
    0.35 * clamp((sellIntensity - 0.70) / 1.80) +
    0.20 * negativeDeltaPersistence;

  const recentLow = Math.min(...recent.map((candle) => candle.low));
  const priorLow = Math.min(...prior.map((candle) => candle.low));
  const downsideAtr = Math.max(0, base.close - current.close) / currentAtr;
  const newLowProgressAtr = Math.max(0, priorLow - recentLow) / currentAtr;
  const bearishCloseFraction = recent.filter((candle, offset) => {
    const previousClose = offset === 0 ? base.close : recent[offset - 1].close;
    return candle.close < previousClose;
  }).length / window;
  const bullishCloseFraction = recent.filter((candle, offset) => {
    const previousClose = offset === 0 ? base.close : recent[offset - 1].close;
    return candle.close > previousClose;
  }).length / window;
  const upsideAtr = Math.max(0, current.close - base.close) / currentAtr;
  const responseRaw = 0.50 * downsideAtr +
    0.35 * newLowProgressAtr +
    0.15 * bearishCloseFraction;
  const impactRaw = responseRaw / Math.max(pressureRaw, 0.15);

  const lowerWickRejection = average(recent.slice(-3).map(lowerWickRatio));
  const firstHalf = recent.slice(0, Math.floor(window / 2));
  const secondHalf = recent.slice(Math.floor(window / 2));
  const firstQuote = Math.max(
    firstHalf.reduce((sum, candle) => sum + candle.quoteVolume, 0),
    Number.EPSILON,
  );
  const secondQuote = Math.max(
    secondHalf.reduce((sum, candle) => sum + candle.quoteVolume, 0),
    Number.EPSILON,
  );
  const firstCvdRatio =
    firstHalf.reduce((sum, candle) => sum + quoteDelta(candle), 0) / firstQuote;
  const secondCvdRatio =
    secondHalf.reduce((sum, candle) => sum + quoteDelta(candle), 0) /
    secondQuote;
  const firstLow = Math.min(...firstHalf.map((candle) => candle.low));
  const secondLow = Math.min(...secondHalf.map((candle) => candle.low));
  const cvdStillNegative = clamp(-secondCvdRatio / 0.25);
  const sellingNotImproving = clamp(
    (firstCvdRatio - secondCvdRatio + 0.03) / 0.16,
  );
  const priceHolding = clamp(1 + (secondLow - firstLow) / currentAtr / 0.75);
  const priceCvdDivergence = cvdStillNegative *
    Math.max(sellingNotImproving, 0.5) * priceHolding;

  const locationWindow = candles.slice(Math.max(0, index - 19), index + 1);
  const locationLow = Math.min(...locationWindow.map((candle) => candle.low));
  const locationHigh = Math.max(...locationWindow.map((candle) => candle.high));
  const nearLow = 1 - clamp((current.close - locationLow) / currentAtr / 1.5);
  const nearHigh = 1 - clamp((locationHigh - current.close) / currentAtr / 1.5);
  const priorQuote = Math.max(
    prior.reduce((sum, candle) => sum + candle.quoteVolume, 0),
    Number.EPSILON,
  );
  const volumeExpansion = recentQuote / priorQuote;
  const recentBuy = recent.reduce(
    (sum, candle) => sum + candle.takerBuyQuote,
    0,
  );
  const buyParticipation = recentQuote > 0 ? recentBuy / recentQuote : 0.5;
  const recentRange = Math.max(...recent.map((candle) => candle.high)) -
    recentLow;
  const priorRange = Math.max(...prior.map((candle) => candle.high)) - priorLow;
  const compression = priorRange > 0
    ? 1 - clamp(recentRange / priorRange / 1.25)
    : 0;

  const priorSwingHigh = Math.max(
    ...candles.slice(index - 3, index).map((candle) => candle.high),
  );
  const swingHighBreak = current.close > priorSwingHigh;
  const positiveDeltaTurn = quoteDelta(current) > 0 &&
    quoteDelta(current) > quoteDelta(previous);
  const currentRange = Math.max(current.high - current.low, Number.EPSILON);
  const bullishBody = current.close > current.open
    ? clamp((current.close - current.open) / currentRange / 0.65)
    : 0;
  const currentEma7 = ema(
    candles.slice(0, index + 1).map((candle) => candle.close),
    7,
  );
  const previousEma7 = ema(
    candles.slice(0, index).map((candle) => candle.close),
    7,
  );
  const ema7Reclaim = previous.close <= previousEma7 &&
    current.close > currentEma7;

  return {
    sellRatio,
    sellIntensity,
    negativeCvdRatio,
    pressureRaw,
    responseRaw,
    downsideAtr,
    newLowProgressAtr,
    bearishCloseFraction,
    bullishCloseFraction,
    upsideAtr,
    impactRaw,
    lowerWickRejection,
    priceCvdDivergence,
    nearLow,
    nearHigh,
    compression,
    volumeExpansion,
    buyParticipation,
    swingHighBreak,
    positiveDeltaTurn,
    bullishBody,
    ema7Reclaim,
  };
}

export function classifyMarketState(
  metrics: Omit<
    MarketStateObservation,
    "state" | "stateScore" | "candleCloseTime" | "scoringVersion" | "features"
  >,
  previousState?: MarketState | null,
): { state: MarketState; stateScore: number } {
  // Seller impact fading is only an early warning: weak selling does not prove
  // that buyers absorbed supply or established a response. A confirmation may
  // inherit context only from an actual absorption or bounce state; otherwise
  // current bounce readiness must independently clear the strong threshold.
  const activeAbsorptionContext = previousState === "buy_side_absorption" ||
    previousState === "bounce_attempt";

  if (
    metrics.sellingPressure >= 70 && metrics.downsideResponse >= 70 &&
    metrics.sellerEfficiency >= 65
  ) {
    return {
      state: "breakdown_risk",
      stateScore: Math.max(metrics.downsideResponse, metrics.sellerEfficiency),
    };
  }
  if (
    (activeAbsorptionContext || metrics.bounceReadiness >= 65) &&
    metrics.confirmation >= 65
  ) {
    return { state: "bullish_confirmation", stateScore: metrics.confirmation };
  }
  if (metrics.bounceReadiness >= 60 && metrics.confirmation >= 35) {
    return { state: "bounce_attempt", stateScore: metrics.bounceReadiness };
  }
  if (metrics.absorption >= 65) {
    return { state: "buy_side_absorption", stateScore: metrics.absorption };
  }
  // Exit hysteresis: retain absorption while its evidence remains meaningful.
  if (previousState === "buy_side_absorption" && metrics.absorption >= 55) {
    return { state: "buy_side_absorption", stateScore: metrics.absorption };
  }
  if (previousState === "bounce_attempt" && metrics.bounceReadiness >= 50) {
    return { state: "bounce_attempt", stateScore: metrics.bounceReadiness };
  }
  if (
    metrics.sellingPressure >= 60 && metrics.sellerEfficiency <= 45 &&
    metrics.efficiencyChange <= -8
  ) {
    return {
      state: "seller_impact_fading",
      stateScore: Math.max(
        metrics.sellingPressure,
        100 - metrics.sellerEfficiency,
      ),
    };
  }
  if (
    metrics.sellingPressure >= 60 && metrics.downsideResponse >= 50 &&
    metrics.sellerEfficiency >= 50
  ) {
    return {
      state: "selling_dominant",
      stateScore: Math.max(metrics.sellingPressure, metrics.downsideResponse),
    };
  }
  // Neutral means no declared state, so it must never outrank an active state
  // merely because pressure happens to sit near the middle of the scale.
  return { state: "neutral", stateScore: 0 };
}

export function marketStateObservation(
  candles: MarketCandle[],
  timeframe: string,
  previousState?: MarketState | null,
): MarketStateObservation | null {
  const window = marketStateWindow(timeframe);
  const currentIndex = candles.length - 1;
  if (currentIndex < window * 2 + 20) return null;

  const allRaw: Array<{ index: number; value: RawWindow }> = [];
  const firstIndex = Math.max(
    window * 2,
    currentIndex - BASELINE_WINDOWS - 8,
  );
  for (let index = firstIndex; index <= currentIndex; index += 1) {
    const value = rawWindowAt(candles, index, window);
    if (value) allRaw.push({ index, value });
  }
  const current = allRaw.at(-1)?.value;
  if (!current) return null;
  const historical = allRaw.slice(0, -1).map((item) => item.value);
  if (historical.length < 20) return null;

  const sellingPressure = score(
    0.45 *
        percentileRank(
          historical.map((value) => value.sellRatio),
          current.sellRatio,
        ) +
      0.35 *
        percentileRank(
          historical.map((value) => value.sellIntensity),
          current.sellIntensity,
        ) +
      0.20 *
        percentileRank(
          historical.map((value) => value.negativeCvdRatio),
          current.negativeCvdRatio,
        ),
  );
  const downsideResponse = score(
    percentileRank(
      historical.map((value) => value.responseRaw),
      current.responseRaw,
    ),
  );
  const pressureHistory = historical.filter((value) =>
    value.pressureRaw >= 0.45
  );
  const impactHistory =
    (pressureHistory.length >= 12 ? pressureHistory : historical).map((value) =>
      value.impactRaw
    );
  const sellerEfficiency = score(
    percentileRank(impactHistory, current.impactRaw),
  );

  // Use one common historical distribution for the recent efficiency series;
  // otherwise each point moving its own denominator creates artificial slope.
  const recentEfficiency = allRaw.slice(-5).map((item) =>
    score(percentileRank(impactHistory, item.value.impactRaw))
  );
  const efficiencyChange = Math.round(
    sellerEfficiency - average(recentEfficiency.slice(0, -1)),
  );
  const deterioration = clamp(-efficiencyChange / 35);
  const pressureGate = clamp((sellingPressure - 45) / 35);
  const inefficiency = 1 - sellerEfficiency / 100;
  const priceResilience = score(
    sellingPressure / 100 * (1 - downsideResponse / 100),
  );
  const absorption = score(
    pressureGate * (
      0.35 * (sellingPressure / 100) +
      0.25 * inefficiency +
      0.20 * deterioration +
      0.12 * current.priceCvdDivergence +
      0.08 * current.lowerWickRejection
    ),
  );
  const bounceReadiness = score(
    0.55 * (absorption / 100) +
      0.15 * current.nearLow +
      0.10 * current.compression +
      0.10 * current.lowerWickRejection +
      0.10 * current.priceCvdDivergence,
  );
  const confirmation = score(
    0.35 * Number(current.swingHighBreak) +
      0.25 * Number(current.positiveDeltaTurn) +
      0.20 * current.bullishBody +
      0.20 * Number(current.ema7Reclaim),
  );
  const metrics = {
    sellingPressure,
    downsideResponse,
    sellerEfficiency,
    efficiencyChange: Math.max(-100, Math.min(100, efficiencyChange)),
    absorption,
    priceResilience,
    bounceReadiness,
    confirmation,
  };
  const classification = classifyMarketState(metrics, previousState);

  return {
    ...classification,
    ...metrics,
    candleCloseTime: candles[currentIndex].closeTime,
    scoringVersion: MARKET_STATE_SCORING_VERSION,
    features: {
      windowCandles: window,
      sellRatio: round(current.sellRatio),
      sellIntensity: round(current.sellIntensity),
      negativeCvdRatio: round(current.negativeCvdRatio),
      downsideAtr: round(current.downsideAtr),
      newLowProgressAtr: round(current.newLowProgressAtr),
      bearishCloseFraction: round(current.bearishCloseFraction),
      bullishCloseFraction: round(current.bullishCloseFraction),
      upsideAtr: round(current.upsideAtr),
      lowerWickRejection: round(current.lowerWickRejection),
      priceCvdDivergence: round(current.priceCvdDivergence),
      nearLow: round(current.nearLow),
      nearHigh: round(current.nearHigh),
      compression: round(current.compression),
      volumeExpansion: round(current.volumeExpansion),
      buyParticipation: round(current.buyParticipation),
      swingHighBreak: current.swingHighBreak,
      positiveDeltaTurn: current.positiveDeltaTurn,
      bullishBody: round(current.bullishBody),
      ema7Reclaim: current.ema7Reclaim,
    },
  };
}
