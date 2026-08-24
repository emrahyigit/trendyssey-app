// Market-control engine.
//
// This does not model a trend. It answers one question from the latest closed
// candle window: who is attacking, how hard, how much price they get for it,
// and how much of it the other side is absorbing. Trend is the outcome of that
// contest; control is the mechanism underneath it, and control is what the
// product reports.
//
// Both sides are measured independently. A side's pressure is its own taker
// flow against its own historical baseline, never its share of volume — share
// is a complement (a buyer share of 0.6 is a seller share of 0.4), so a
// share-based pair would be two views of one number and could never show both
// sides swinging hard at once. Intensity can rise on both sides together, and
// that two-sided fight is exactly the state worth naming.

import { atr, ema, type MarketCandle } from "./indicators.ts";

export const MARKET_STATE_SCORING_VERSION = "market-state-v5.2-control";

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

// The control-transfer cycle. Each side runs the same ladder: it takes
// control, its impact decays, the other side absorbs it, its intensity dies,
// and control changes hands.
export type MarketState =
  | "seller_dominance"
  | "seller_impact_fading"
  | "buy_side_absorption"
  | "seller_exhaustion"
  | "buyer_takeover"
  | "buyer_dominance"
  | "buyer_impact_fading"
  | "sell_side_absorption"
  | "buyer_exhaustion"
  | "seller_takeover"
  | "balanced"
  | "low_participation";

/** Above this the other side has moved price, so no stalemate is left to name. */
export const ABSORPTION_MAXIMUM_COUNTER_RESPONSE = 70;

/** Dominance at or above this reads as continuation risk rather than control. */
export const DOMINANCE_RISK_SCORE = 75;

export interface MarketStateObservation {
  state: MarketState;
  stateScore: number;

  // Core, one pair per dimension.
  sellerPressure: number;
  buyerPressure: number;
  sellerEfficiency: number;
  buyerEfficiency: number;
  downsideResponse: number;
  upsideResponse: number;
  buySideAbsorption: number;
  sellSideAbsorption: number;

  // Trends the ladder reads: impact decaying, then intensity dying.
  sellerEfficiencyTrend: number;
  buyerEfficiencyTrend: number;
  sellerPressureTrend: number;
  buyerPressureTrend: number;

  // Closed-candle turn evidence, used to confirm a takeover.
  bullishConfirmation: number;
  bearishConfirmation: number;

  // Where a turn would start from, built only out of ingredients absorption
  // does not already carry: location in the range, how tightly the range has
  // coiled, and the rejection wick on the last few candles. An earlier version
  // put 0.55 weight on absorption itself and ended up 0.87 correlated with it,
  // which is to say it restated the number sitting next to it.
  bounceReadiness: number;
  rolloverReadiness: number;

  // Each side's defence: how well price refused to follow the other side's
  // flow. Derived from pressure and response rather than measured separately,
  // so it is a shorthand for two numbers rather than a third fact.
  buyerResilience: number;
  sellerResilience: number;

  candleCloseTime: number;
  scoringVersion: string;
  features: {
    windowCandles: number;
    sellIntensity: number;
    buyIntensity: number;
    sellAggression: number;
    buyAggression: number;
    downsideAtr: number;
    upsideAtr: number;
    newLowProgressAtr: number;
    newHighProgressAtr: number;
    bearishCloseFraction: number;
    bullishCloseFraction: number;
    lowerWickRejection: number;
    upperWickRejection: number;
    absorptionDivergenceDown: number;
    absorptionDivergenceUp: number;
    nearLow: number;
    nearHigh: number;
    compression: number;
    volumeExpansion: number;
    swingHighBreak: boolean;
    swingLowBreak: boolean;
    positiveDeltaTurn: boolean;
    negativeDeltaTurn: boolean;
    bullishBody: number;
    bearishBody: number;
    ema7Reclaim: boolean;
    ema7Loss: boolean;
  };
}

interface RawWindow {
  sellIntensity: number;
  buyIntensity: number;
  sellAggression: number;
  buyAggression: number;
  sellPressureRaw: number;
  buyPressureRaw: number;
  downResponseRaw: number;
  upResponseRaw: number;
  sellImpactRaw: number;
  buyImpactRaw: number;
  downsideAtr: number;
  upsideAtr: number;
  newLowProgressAtr: number;
  newHighProgressAtr: number;
  bearishCloseFraction: number;
  bullishCloseFraction: number;
  lowerWickRejection: number;
  upperWickRejection: number;
  absorptionDivergenceDown: number;
  absorptionDivergenceUp: number;
  nearLow: number;
  nearHigh: number;
  compression: number;
  volumeExpansion: number;
  swingHighBreak: boolean;
  swingLowBreak: boolean;
  positiveDeltaTurn: boolean;
  negativeDeltaTurn: boolean;
  bullishBody: number;
  bearishBody: number;
  ema7Reclaim: boolean;
  ema7Loss: boolean;
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
const bounded = (value: number) => Math.max(-100, Math.min(100, value));

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

function sellQuote(candle: MarketCandle): number {
  return Math.max(0, candle.quoteVolume - candle.takerBuyQuote);
}

function lowerWickRatio(candle: MarketCandle): number {
  const range = Math.max(candle.high - candle.low, Number.EPSILON);
  return clamp((Math.min(candle.open, candle.close) - candle.low) / range);
}

function upperWickRatio(candle: MarketCandle): number {
  const range = Math.max(candle.high - candle.low, Number.EPSILON);
  return clamp((candle.high - Math.max(candle.open, candle.close)) / range);
}

/**
 * Aggression is how often a side beat its own typical candle, so both sides
 * can read high at once when total activity expands.
 */
function pressureOf(
  recentFlow: number[],
  priorFlow: number[],
  window: number,
): { intensity: number; aggression: number; raw: number } {
  const perCandleBaseline = Math.max(median(priorFlow), Number.EPSILON);
  const baseline = perCandleBaseline * window;
  const intensity = recentFlow.reduce((sum, value) => sum + value, 0) /
    Math.max(baseline, Number.EPSILON);
  const aggression =
    recentFlow.filter((value) => value > perCandleBaseline).length /
    Math.max(window, 1);
  const raw = 0.65 * clamp((intensity - 0.70) / 1.80) + 0.35 * aggression;
  return { intensity, aggression, raw };
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

  const sell = pressureOf(
    recent.map(sellQuote),
    prior.map(sellQuote),
    window,
  );
  const buy = pressureOf(
    recent.map((candle) => candle.takerBuyQuote),
    prior.map((candle) => candle.takerBuyQuote),
    window,
  );

  const recentLow = Math.min(...recent.map((candle) => candle.low));
  const recentHigh = Math.max(...recent.map((candle) => candle.high));
  const priorLow = Math.min(...prior.map((candle) => candle.low));
  const priorHigh = Math.max(...prior.map((candle) => candle.high));
  const downsideAtr = Math.max(0, base.close - current.close) / currentAtr;
  const upsideAtr = Math.max(0, current.close - base.close) / currentAtr;
  const newLowProgressAtr = Math.max(0, priorLow - recentLow) / currentAtr;
  const newHighProgressAtr = Math.max(0, recentHigh - priorHigh) / currentAtr;
  const bearishCloseFraction = recent.filter((candle, offset) => {
    const previousClose = offset === 0 ? base.close : recent[offset - 1].close;
    return candle.close < previousClose;
  }).length / window;
  const bullishCloseFraction = recent.filter((candle, offset) => {
    const previousClose = offset === 0 ? base.close : recent[offset - 1].close;
    return candle.close > previousClose;
  }).length / window;
  const downResponseRaw = 0.50 * downsideAtr +
    0.35 * newLowProgressAtr +
    0.15 * bearishCloseFraction;
  const upResponseRaw = 0.50 * upsideAtr +
    0.35 * newHighProgressAtr +
    0.15 * bullishCloseFraction;
  const sellImpactRaw = downResponseRaw / Math.max(sell.raw, 0.15);
  const buyImpactRaw = upResponseRaw / Math.max(buy.raw, 0.15);

  const lowerWickRejection = average(recent.slice(-3).map(lowerWickRatio));
  const upperWickRejection = average(recent.slice(-3).map(upperWickRatio));
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
  const firstHigh = Math.max(...firstHalf.map((candle) => candle.high));
  const secondHigh = Math.max(...secondHalf.map((candle) => candle.high));

  // Absorption is flow that keeps coming while price refuses to follow it.
  const cvdStillNegative = clamp(-secondCvdRatio / 0.25);
  const sellingNotImproving = clamp(
    (firstCvdRatio - secondCvdRatio + 0.03) / 0.16,
  );
  const priceHolding = clamp(1 + (secondLow - firstLow) / currentAtr / 0.75);
  const absorptionDivergenceDown = cvdStillNegative *
    Math.max(sellingNotImproving, 0.5) * priceHolding;

  const cvdStillPositive = clamp(secondCvdRatio / 0.25);
  const buyingNotFading = clamp(
    (secondCvdRatio - firstCvdRatio + 0.03) / 0.16,
  );
  const priceNotAdvancing = clamp(
    1 - (secondHigh - firstHigh) / currentAtr / 0.75,
  );
  const absorptionDivergenceUp = cvdStillPositive *
    Math.max(buyingNotFading, 0.5) * priceNotAdvancing;

  const locationWindow = candles.slice(Math.max(0, index - 19), index + 1);
  const locationLow = Math.min(...locationWindow.map((candle) => candle.low));
  const locationHigh = Math.max(...locationWindow.map((candle) => candle.high));
  const nearLow = 1 - clamp((current.close - locationLow) / currentAtr / 1.5);
  const nearHigh = 1 - clamp((locationHigh - current.close) / currentAtr / 1.5);
  const recentQuote = recent.reduce(
    (sum, candle) => sum + candle.quoteVolume,
    0,
  );
  const priorQuote = Math.max(
    prior.reduce((sum, candle) => sum + candle.quoteVolume, 0),
    Number.EPSILON,
  );
  const volumeExpansion = recentQuote / priorQuote;
  const recentRange = recentHigh - recentLow;
  const priorRange = priorHigh - priorLow;
  const compression = priorRange > 0
    ? 1 - clamp(recentRange / priorRange / 1.25)
    : 0;

  const priorSwingHigh = Math.max(
    ...candles.slice(index - 3, index).map((candle) => candle.high),
  );
  const priorSwingLow = Math.min(
    ...candles.slice(index - 3, index).map((candle) => candle.low),
  );
  const swingHighBreak = current.close > priorSwingHigh;
  const swingLowBreak = current.close < priorSwingLow;
  const positiveDeltaTurn = quoteDelta(current) > 0 &&
    quoteDelta(current) > quoteDelta(previous);
  const negativeDeltaTurn = quoteDelta(current) < 0 &&
    quoteDelta(current) < quoteDelta(previous);
  const currentRange = Math.max(current.high - current.low, Number.EPSILON);
  const bullishBody = current.close > current.open
    ? clamp((current.close - current.open) / currentRange / 0.65)
    : 0;
  const bearishBody = current.close < current.open
    ? clamp((current.open - current.close) / currentRange / 0.65)
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
  const ema7Loss = previous.close >= previousEma7 &&
    current.close < currentEma7;

  return {
    sellIntensity: sell.intensity,
    buyIntensity: buy.intensity,
    sellAggression: sell.aggression,
    buyAggression: buy.aggression,
    sellPressureRaw: sell.raw,
    buyPressureRaw: buy.raw,
    downResponseRaw,
    upResponseRaw,
    sellImpactRaw,
    buyImpactRaw,
    downsideAtr,
    upsideAtr,
    newLowProgressAtr,
    newHighProgressAtr,
    bearishCloseFraction,
    bullishCloseFraction,
    lowerWickRejection,
    upperWickRejection,
    absorptionDivergenceDown,
    absorptionDivergenceUp,
    nearLow,
    nearHigh,
    compression,
    volumeExpansion,
    swingHighBreak,
    swingLowBreak,
    positiveDeltaTurn,
    negativeDeltaTurn,
    bullishBody,
    bearishBody,
    ema7Reclaim,
    ema7Loss,
  };
}

type ClassifierMetrics = Pick<
  MarketStateObservation,
  | "sellerPressure"
  | "buyerPressure"
  | "sellerEfficiency"
  | "buyerEfficiency"
  | "downsideResponse"
  | "upsideResponse"
  | "buySideAbsorption"
  | "sellSideAbsorption"
  | "sellerEfficiencyTrend"
  | "buyerEfficiencyTrend"
  | "sellerPressureTrend"
  | "buyerPressureTrend"
  | "bullishConfirmation"
  | "bearishConfirmation"
>;

/** One side's view, so the ladder is written once and read twice. */
interface SideView {
  pressure: number;
  efficiency: number;
  response: number;
  efficiencyTrend: number;
  pressureTrend: number;
  /** How much the other side is absorbing this side's flow. */
  absorbedBy: number;
  /** Closed-candle evidence that the other side is taking over. */
  counterConfirmation: number;
  counterEfficiency: number;
  counterEfficiencyTrend: number;
  counterResponse: number;
  states: {
    dominance: MarketState;
    impactFading: MarketState;
    absorption: MarketState;
    exhaustion: MarketState;
    counterTakeover: MarketState;
  };
}

const SELLER_STATES = {
  dominance: "seller_dominance",
  impactFading: "seller_impact_fading",
  absorption: "buy_side_absorption",
  exhaustion: "seller_exhaustion",
  counterTakeover: "buyer_takeover",
} as const;

const BUYER_STATES = {
  dominance: "buyer_dominance",
  impactFading: "buyer_impact_fading",
  absorption: "sell_side_absorption",
  exhaustion: "buyer_exhaustion",
  counterTakeover: "seller_takeover",
} as const;

/** Which side's ladder a state belongs to, for hysteresis and exhaustion. */
function familyOf(state: MarketState | null | undefined): "sell" | "buy" | null {
  switch (state) {
    case "seller_dominance":
    case "seller_impact_fading":
    case "buy_side_absorption":
    case "seller_exhaustion":
      return "sell";
    case "buyer_dominance":
    case "buyer_impact_fading":
    case "sell_side_absorption":
    case "buyer_exhaustion":
      return "buy";
    // A takeover belongs to the side that just won, so its own ladder follows.
    case "buyer_takeover":
      return "buy";
    case "seller_takeover":
      return "sell";
    default:
      return null;
  }
}

/**
 * Ranked so that transfers outrank the states they grow out of: a takeover
 * beats absorption, and absorption beats plain control.
 *
 * Dominance outranks a fading impact across sides on purpose. When one side is
 * clearly winning, the other side is failing by definition — "sellers are
 * swinging and missing" is the shadow of "buyers are in control", and the
 * second sentence is the one worth saying.
 */
function claimFor(
  side: SideView,
  previousState: MarketState | null | undefined,
  ownFamily: "sell" | "buy",
): { state: MarketState; stateScore: number; rank: number } | null {
  const wasPressing = familyOf(previousState) === ownFamily;

  // Control changes hands: the other side is now both efficient and moving
  // price, with closed-candle evidence behind it.
  if (
    side.counterEfficiency >= 55 && side.counterResponse >= 45 &&
    side.counterEfficiencyTrend >= 8 && side.counterConfirmation >= 50
  ) {
    return {
      state: side.states.counterTakeover,
      stateScore: Math.max(side.counterEfficiency, side.counterConfirmation),
      rank: 5,
    };
  }
  // Intensity itself dies after it had been pressing.
  if (
    wasPressing && side.pressureTrend <= -12 && side.pressure <= 45 &&
    side.response <= 40
  ) {
    return {
      state: side.states.exhaustion,
      stateScore: Math.max(100 - side.pressure, -side.pressureTrend),
      rank: 4,
    };
  }
  // Absorption means flow keeps arriving and price refuses to follow it. Once
  // the other side has visibly moved price, that stalemate is over — without
  // this guard the latch outranks dominance and holds a coin in "absorbing"
  // through an entire run, which is exactly what it did to BMT on 1h.
  const stalemate = side.counterResponse < ABSORPTION_MAXIMUM_COUNTER_RESPONSE;
  if (
    stalemate &&
    (side.absorbedBy >= 65 || (wasPressing && side.absorbedBy >= 55))
  ) {
    return {
      state: side.states.absorption,
      stateScore: side.absorbedBy,
      rank: 3,
    };
  }
  // Still swinging, no longer landing.
  if (
    side.pressure >= 55 && side.efficiency <= 45 && side.efficiencyTrend <= -8
  ) {
    return {
      state: side.states.impactFading,
      stateScore: Math.max(side.pressure, 100 - side.efficiency),
      rank: 1,
    };
  }
  if (side.pressure >= 60 && side.response >= 50 && side.efficiency >= 50) {
    return {
      state: side.states.dominance,
      stateScore: Math.max(side.pressure, side.response),
      rank: 2,
    };
  }
  return null;
}

export function classifyMarketState(
  metrics: ClassifierMetrics,
  previousState?: MarketState | null,
): { state: MarketState; stateScore: number } {
  const sellerSide: SideView = {
    pressure: metrics.sellerPressure,
    efficiency: metrics.sellerEfficiency,
    response: metrics.downsideResponse,
    efficiencyTrend: metrics.sellerEfficiencyTrend,
    pressureTrend: metrics.sellerPressureTrend,
    absorbedBy: metrics.buySideAbsorption,
    counterConfirmation: metrics.bullishConfirmation,
    counterEfficiency: metrics.buyerEfficiency,
    counterEfficiencyTrend: metrics.buyerEfficiencyTrend,
    counterResponse: metrics.upsideResponse,
    states: SELLER_STATES,
  };
  const buyerSide: SideView = {
    pressure: metrics.buyerPressure,
    efficiency: metrics.buyerEfficiency,
    response: metrics.upsideResponse,
    efficiencyTrend: metrics.buyerEfficiencyTrend,
    pressureTrend: metrics.buyerPressureTrend,
    absorbedBy: metrics.sellSideAbsorption,
    counterConfirmation: metrics.bearishConfirmation,
    counterEfficiency: metrics.sellerEfficiency,
    counterEfficiencyTrend: metrics.sellerEfficiencyTrend,
    counterResponse: metrics.downsideResponse,
    states: BUYER_STATES,
  };

  const claims = [
    claimFor(sellerSide, previousState, "sell"),
    claimFor(buyerSide, previousState, "buy"),
  ].filter((claim): claim is NonNullable<typeof claim> => claim !== null);

  if (claims.length > 0) {
    // Both sides can qualify in a genuine two-sided fight. The stronger claim
    // wins, and an equal claim is broken by score, never by side.
    claims.sort((left, right) =>
      right.rank - left.rank || right.stateScore - left.stateScore
    );
    const winner = claims[0];
    return { state: winner.state, stateScore: winner.stateScore };
  }

  // Nothing was claimed. Say which kind of quiet it is instead of calling an
  // empty market balanced.
  const strongestPressure = Math.max(
    metrics.sellerPressure,
    metrics.buyerPressure,
  );
  if (strongestPressure < 40) {
    return { state: "low_participation", stateScore: strongestPressure };
  }
  return { state: "balanced", stateScore: strongestPressure };
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

  const rank = (
    pick: (value: RawWindow) => number,
    value: number,
    history = historical,
  ) => score(percentileRank(history.map(pick), value));

  const sellerPressure = rank(
    (value) => value.sellPressureRaw,
    current.sellPressureRaw,
  );
  const buyerPressure = rank(
    (value) => value.buyPressureRaw,
    current.buyPressureRaw,
  );
  const downsideResponse = rank(
    (value) => value.downResponseRaw,
    current.downResponseRaw,
  );
  const upsideResponse = rank(
    (value) => value.upResponseRaw,
    current.upResponseRaw,
  );

  // Efficiency is only meaningful against windows where the side was actually
  // pressing, so the comparison set is filtered before it is ranked.
  const efficiencyHistory = (
    pickPressure: (value: RawWindow) => number,
    pickImpact: (value: RawWindow) => number,
  ) => {
    const pressing = historical.filter((value) => pickPressure(value) >= 0.45);
    return (pressing.length >= 12 ? pressing : historical).map(pickImpact);
  };
  const sellImpactHistory = efficiencyHistory(
    (value) => value.sellPressureRaw,
    (value) => value.sellImpactRaw,
  );
  const buyImpactHistory = efficiencyHistory(
    (value) => value.buyPressureRaw,
    (value) => value.buyImpactRaw,
  );
  const sellerEfficiency = score(
    percentileRank(sellImpactHistory, current.sellImpactRaw),
  );
  const buyerEfficiency = score(
    percentileRank(buyImpactHistory, current.buyImpactRaw),
  );

  // Trends use one common historical distribution for the whole recent series;
  // otherwise each point moving its own denominator creates artificial slope.
  const trendOf = (series: number[]) =>
    Math.round(series.at(-1)! - average(series.slice(0, -1)));
  const recentTail = allRaw.slice(-5);
  const sellerEfficiencyTrend = bounded(trendOf(
    recentTail.map((item) =>
      score(percentileRank(sellImpactHistory, item.value.sellImpactRaw))
    ),
  ));
  const buyerEfficiencyTrend = bounded(trendOf(
    recentTail.map((item) =>
      score(percentileRank(buyImpactHistory, item.value.buyImpactRaw))
    ),
  ));
  const sellerPressureTrend = bounded(trendOf(
    recentTail.map((item) =>
      rank((value) => value.sellPressureRaw, item.value.sellPressureRaw)
    ),
  ));
  const buyerPressureTrend = bounded(trendOf(
    recentTail.map((item) =>
      rank((value) => value.buyPressureRaw, item.value.buyPressureRaw)
    ),
  ));

  const absorptionOf = (
    pressure: number,
    efficiency: number,
    trend: number,
    divergence: number,
    wick: number,
  ) => {
    const gate = clamp((pressure - 45) / 35);
    return score(gate * (
      0.35 * (pressure / 100) +
      0.25 * (1 - efficiency / 100) +
      0.20 * clamp(-trend / 35) +
      0.12 * divergence +
      0.08 * wick
    ));
  };
  const buySideAbsorption = absorptionOf(
    sellerPressure,
    sellerEfficiency,
    sellerEfficiencyTrend,
    current.absorptionDivergenceDown,
    current.lowerWickRejection,
  );
  const sellSideAbsorption = absorptionOf(
    buyerPressure,
    buyerEfficiency,
    buyerEfficiencyTrend,
    current.absorptionDivergenceUp,
    current.upperWickRejection,
  );

  const bullishConfirmation = score(
    0.35 * Number(current.swingHighBreak) +
      0.25 * Number(current.positiveDeltaTurn) +
      0.20 * current.bullishBody +
      0.20 * Number(current.ema7Reclaim),
  );
  const bearishConfirmation = score(
    0.35 * Number(current.swingLowBreak) +
      0.25 * Number(current.negativeDeltaTurn) +
      0.20 * current.bearishBody +
      0.20 * Number(current.ema7Loss),
  );



  // Location carries the most weight: a turn happens at an extreme, not in the
  // middle of a range. Compression and the rejection wick then say whether the
  // extreme is coiling or being defended.
  const bounceReadiness = score(
    0.40 * current.nearLow +
      0.30 * current.compression +
      0.30 * current.lowerWickRejection,
  );
  const rolloverReadiness = score(
    0.40 * current.nearHigh +
      0.30 * current.compression +
      0.30 * current.upperWickRejection,
  );
  const buyerResilience = score(
    sellerPressure / 100 * (1 - downsideResponse / 100),
  );
  const sellerResilience = score(
    buyerPressure / 100 * (1 - upsideResponse / 100),
  );

  const metrics = {
    sellerPressure,
    buyerPressure,
    sellerEfficiency,
    buyerEfficiency,
    downsideResponse,
    upsideResponse,
    buySideAbsorption,
    sellSideAbsorption,
    sellerEfficiencyTrend,
    buyerEfficiencyTrend,
    sellerPressureTrend,
    buyerPressureTrend,
    bullishConfirmation,
    bearishConfirmation,
  };
  const classification = classifyMarketState(metrics, previousState);

  return {
    ...classification,
    ...metrics,
    bounceReadiness,
    rolloverReadiness,
    buyerResilience,
    sellerResilience,
    candleCloseTime: candles[currentIndex].closeTime,
    scoringVersion: MARKET_STATE_SCORING_VERSION,
    features: {
      windowCandles: window,
      sellIntensity: round(current.sellIntensity),
      buyIntensity: round(current.buyIntensity),
      sellAggression: round(current.sellAggression),
      buyAggression: round(current.buyAggression),
      downsideAtr: round(current.downsideAtr),
      upsideAtr: round(current.upsideAtr),
      newLowProgressAtr: round(current.newLowProgressAtr),
      newHighProgressAtr: round(current.newHighProgressAtr),
      bearishCloseFraction: round(current.bearishCloseFraction),
      bullishCloseFraction: round(current.bullishCloseFraction),
      lowerWickRejection: round(current.lowerWickRejection),
      upperWickRejection: round(current.upperWickRejection),
      absorptionDivergenceDown: round(current.absorptionDivergenceDown),
      absorptionDivergenceUp: round(current.absorptionDivergenceUp),
      nearLow: round(current.nearLow),
      nearHigh: round(current.nearHigh),
      compression: round(current.compression),
      volumeExpansion: round(current.volumeExpansion),
      swingHighBreak: current.swingHighBreak,
      swingLowBreak: current.swingLowBreak,
      positiveDeltaTurn: current.positiveDeltaTurn,
      negativeDeltaTurn: current.negativeDeltaTurn,
      bullishBody: round(current.bullishBody),
      bearishBody: round(current.bearishBody),
      ema7Reclaim: current.ema7Reclaim,
      ema7Loss: current.ema7Loss,
    },
  };
}
