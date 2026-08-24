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

export const MARKET_STATE_SCORING_VERSION = "market-state-v7-behavioral";

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

export type BehavioralSignalKind =
  | "lower_low_failure"
  | "higher_high_failure"
  | "downside_progress_weakening"
  | "upside_progress_weakening"
  | "sell_pressure_downside_divergence"
  | "buy_pressure_upside_divergence"
  | "failed_breakdown"
  | "failed_breakout"
  | "buyer_recovery_strengthening"
  | "seller_recovery_strengthening"
  | "seller_exhaustion"
  | "buyer_exhaustion"
  | "buyer_takeover"
  | "seller_takeover"
  | "spot_futures_divergence";

export interface BehavioralSignal {
  kind: BehavioralSignalKind;
  score: number;
  direction: "bullish" | "bearish" | "neutral";
  status: "developing" | "confirmed";
  trend: "rising" | "falling" | "flat";
  evidence: string[];
}

export interface MarketBehaviorContext {
  regime: "bullish" | "bearish" | "range";
  priceVsEma25: "above" | "below";
  priceVsEma99: "above" | "below";
  ema25Trend: "rising" | "falling" | "flat";
  futuresAvailability: "unavailable";
  summary: string;
}

export interface BehavioralStateScores {
  sellerExhaustion: number;
  buyerExhaustion: number;
  buyerResponse: number;
  sellerResponse: number;
  bullishExpansion: number;
  bearishExpansion: number;
}

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

  // Context, simultaneous behavioral states and transition signals are kept
  // separate. A weak seller is not automatically a strong buyer, and neither
  // condition becomes actionable until structure confirms the handover.
  context: MarketBehaviorContext;
  behavioralScores: BehavioralStateScores;
  behavioralSignals: BehavioralSignal[];

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
    downsideProgressTrend: number;
    upsideProgressTrend: number;
    downsideResponseTrend: number;
    upsideResponseTrend: number;
    buyerRecoveryRatio: number;
    sellerRecoveryRatio: number;
    buyerRecoveryTrend: number;
    sellerRecoveryTrend: number;
    buyerRecoverySpeed: number;
    sellerRecoverySpeed: number;
    lowerLowFailure: number;
    higherHighFailure: number;
    failedBreakdown: number;
    failedBreakout: number;
    ema25Reclaim: boolean;
    ema25Rejection: boolean;
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
  buyerRecoveryRatio: number;
  sellerRecoveryRatio: number;
  buyerRecoverySpeed: number;
  sellerRecoverySpeed: number;
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

  // Recovery is measured from the extreme of the latest directional wave.
  // Magnitude and speed stay separate: reclaiming 60% in two candles carries
  // different information from reclaiming it in twelve.
  const lowOffset = recent.reduce(
    (best, candle, offset) => candle.low < recent[best].low ? offset : best,
    0,
  );
  const highOffset = recent.reduce(
    (best, candle, offset) => candle.high > recent[best].high ? offset : best,
    0,
  );
  const preLowHigh = Math.max(
    ...recent.slice(0, lowOffset + 1).map((candle) => candle.high),
  );
  const postLowHigh = Math.max(
    ...recent.slice(lowOffset).map((candle) => candle.high),
  );
  const sellWave = Math.max(
    preLowHigh - recent[lowOffset].low,
    currentAtr * 0.1,
  );
  const buyerRecoveryRatio = clamp(
    (postLowHigh - recent[lowOffset].low) / sellWave,
  );
  const buyerRecoverySpeed = clamp(
    ((postLowHigh - recent[lowOffset].low) / currentAtr) /
      Math.max(recent.length - lowOffset, 1) / 0.75,
  );
  const preHighLow = Math.min(
    ...recent.slice(0, highOffset + 1).map((candle) => candle.low),
  );
  const postHighLow = Math.min(
    ...recent.slice(highOffset).map((candle) => candle.low),
  );
  const buyWave = Math.max(
    recent[highOffset].high - preHighLow,
    currentAtr * 0.1,
  );
  const sellerRecoveryRatio = clamp(
    (recent[highOffset].high - postHighLow) / buyWave,
  );
  const sellerRecoverySpeed = clamp(
    ((recent[highOffset].high - postHighLow) / currentAtr) /
      Math.max(recent.length - highOffset, 1) / 0.75,
  );

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
    buyerRecoveryRatio,
    sellerRecoveryRatio,
    buyerRecoverySpeed,
    sellerRecoverySpeed,
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
function familyOf(
  state: MarketState | null | undefined,
): "sell" | "buy" | null {
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
/**
 * How far past its own entry bar a reading sits, on a scale every state shares:
 * 50 means it only just qualified, 100 means it cleared every condition by the
 * widest possible margin.
 *
 * The old score took whichever ingredient happened to look best, and each state
 * picked a different ingredient — so the number meant something different in
 * every state. Measured over 14k observations dominance averaged 90 while
 * absorption averaged 65 and could not exceed 93, which meant a single
 * "minimum score" filter admitted nearly every dominance and almost no
 * absorption, even though absorption is the earlier reversal signal. Averaging
 * the margins instead of taking their maximum also stops one strong ingredient
 * from carrying a reading that barely qualified on the rest.
 */
function evidenceScore(margins: number[]): number {
  if (margins.length === 0) return 50;
  const mean = margins.reduce((sum, value) => sum + clamp(value), 0) /
    margins.length;
  return Math.round(50 + 50 * mean);
}

/** Headroom above a floor condition, as a 0-1 fraction of what was available. */
const over = (value: number, floor: number) =>
  clamp((value - floor) / Math.max(100 - floor, 1));

/** Headroom below a ceiling condition. */
const under = (value: number, ceiling: number) =>
  clamp((ceiling - value) / Math.max(ceiling, 1));

/** Headroom past a negative trend threshold, measured over a 40-point span. */
const beyond = (value: number, threshold: number) =>
  clamp((threshold - value) / 40);

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
      stateScore: evidenceScore([
        over(side.counterEfficiency, 55),
        over(side.counterResponse, 45),
        clamp((side.counterEfficiencyTrend - 8) / 40),
        over(side.counterConfirmation, 50),
      ]),
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
      stateScore: evidenceScore([
        beyond(side.pressureTrend, -12),
        under(side.pressure, 45),
        under(side.response, 40),
      ]),
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
      stateScore: evidenceScore([
        over(side.absorbedBy, 55),
        over(side.pressure, 55),
        under(side.efficiency, 45),
      ]),
      rank: 3,
    };
  }
  // Still swinging, no longer landing.
  if (
    side.pressure >= 55 && side.efficiency <= 45 && side.efficiencyTrend <= -8
  ) {
    return {
      state: side.states.impactFading,
      stateScore: evidenceScore([
        over(side.pressure, 55),
        under(side.efficiency, 45),
        beyond(side.efficiencyTrend, -8),
      ]),
      rank: 1,
    };
  }
  if (side.pressure >= 60 && side.response >= 50 && side.efficiency >= 50) {
    return {
      state: side.states.dominance,
      stateScore: evidenceScore([
        over(side.pressure, 60),
        over(side.response, 50),
        over(side.efficiency, 50),
      ]),
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
  const strongestResponse = Math.max(
    metrics.downsideResponse,
    metrics.upsideResponse,
  );
  // Quiet has to mean both things: little flow AND price going nowhere. Judging
  // it on flow alone called PROM "quiet" while price had travelled 48 and
  // buyers were converting at 61 — a thin market can still move, and saying it
  // is asleep contradicts what the same card shows underneath.
  if (strongestPressure < 40 && strongestResponse < 40) {
    return {
      state: "low_participation",
      stateScore: evidenceScore([
        under(strongestPressure, 40),
        under(strongestResponse, 40),
      ]),
    };
  }
  // Balanced argues from two things at once: both sides genuinely present, and
  // neither of them ahead.
  const gap = Math.abs(metrics.sellerPressure - metrics.buyerPressure);
  return {
    state: "balanced",
    stateScore: evidenceScore([
      over(Math.min(metrics.sellerPressure, metrics.buyerPressure), 40),
      under(gap, 40),
    ]),
  };
}

interface BehavioralLayerInput {
  candles: MarketCandle[];
  window: number;
  sellerPressure: number;
  buyerPressure: number;
  sellerEfficiency: number;
  buyerEfficiency: number;
  downsideResponse: number;
  upsideResponse: number;
  buySideAbsorption: number;
  sellSideAbsorption: number;
  sellerEfficiencyTrend: number;
  buyerEfficiencyTrend: number;
  sellerPressureTrend: number;
  buyerPressureTrend: number;
  downsideProgressTrend: number;
  upsideProgressTrend: number;
  downsideResponseTrend: number;
  upsideResponseTrend: number;
  buyerRecoveryRatio: number;
  sellerRecoveryRatio: number;
  buyerRecoveryTrend: number;
  sellerRecoveryTrend: number;
  buyerRecoverySpeed: number;
  sellerRecoverySpeed: number;
  bullishConfirmation: number;
  bearishConfirmation: number;
  lowerWickRejection: number;
  upperWickRejection: number;
}

interface BehavioralLayerResult {
  context: MarketBehaviorContext;
  scores: BehavioralStateScores;
  signals: BehavioralSignal[];
  lowerLowFailure: number;
  higherHighFailure: number;
  failedBreakdown: number;
  failedBreakout: number;
  ema25Reclaim: boolean;
  ema25Rejection: boolean;
}

/**
 * Builds the behavioral layer from trajectories and structural events. The
 * final UI numbers are outputs of this layer, never inputs to one another.
 * Futures context is intentionally marked unavailable until the scanner owns a
 * synchronized futures feed; candle volume must not masquerade as OI/funding.
 */
function behavioralLayer(input: BehavioralLayerInput): BehavioralLayerResult {
  const { candles, window } = input;
  const current = candles.at(-1)!;
  const previous = candles.at(-2)!;
  const currentAtr = Math.max(atr(candles), Number.EPSILON);
  const fastCount = Math.max(3, Math.ceil(window / 2));
  const structuralCount = Math.max(20, window * 4);
  const structural = candles.slice(-(structuralCount + fastCount));
  const reference = structural.slice(0, -fastCount);
  const recent = structural.slice(-fastCount);
  const support = Math.min(...reference.map((candle) => candle.low));
  const resistance = Math.max(...reference.map((candle) => candle.high));
  const recentLow = Math.min(...recent.map((candle) => candle.low));
  const recentHigh = Math.max(...recent.map((candle) => candle.high));

  const lowTest = clamp(1 - Math.abs(recentLow - support) / currentAtr / 1.25);
  const highTest = clamp(
    1 - Math.abs(recentHigh - resistance) / currentAtr / 1.25,
  );
  const lowerLowHeld = recentLow >= support - 0.15 * currentAtr ? 1 : 0;
  const higherHighHeld = recentHigh <= resistance + 0.15 * currentAtr ? 1 : 0;
  const lowerLowFailure = score(
    input.sellerPressure / 100 * lowTest *
      (0.45 * lowerLowHeld + 0.30 * clamp(-input.downsideProgressTrend / 35) +
        0.25 * clamp(-input.downsideResponseTrend / 35)),
  );
  const higherHighFailure = score(
    input.buyerPressure / 100 * highTest *
      (0.45 * higherHighHeld + 0.30 * clamp(-input.upsideProgressTrend / 35) +
        0.25 * clamp(-input.upsideResponseTrend / 35)),
  );

  const brokeSupport = recentLow < support - 0.05 * currentAtr;
  const reclaimedSupport = current.close > support;
  const reclaimMagnitude = clamp((current.close - support) / currentAtr / 0.75);
  const closeLocation = clamp(
    (current.close - current.low) /
      Math.max(current.high - current.low, Number.EPSILON),
  );
  const failedBreakdown = brokeSupport && reclaimedSupport
    ? score(
      0.30 * input.sellerPressure / 100 +
        0.25 * reclaimMagnitude +
        0.20 * input.lowerWickRejection +
        0.25 * closeLocation,
    )
    : 0;

  const brokeResistance = recentHigh > resistance + 0.05 * currentAtr;
  const rejectedResistance = current.close < resistance;
  const rejectionMagnitude = clamp(
    (resistance - current.close) / currentAtr / 0.75,
  );
  const bearishCloseLocation = 1 - closeLocation;
  const failedBreakout = brokeResistance && rejectedResistance
    ? score(
      0.30 * input.buyerPressure / 100 +
        0.25 * rejectionMagnitude +
        0.20 * input.upperWickRejection +
        0.25 * bearishCloseLocation,
    )
    : 0;

  const closes = candles.map((candle) => candle.close);
  const ema25Now = ema(closes, 25);
  const ema25Before = ema(closes.slice(0, -1), 25);
  const ema99Now = ema(closes, 99);
  const ema99Before = ema(closes.slice(0, -Math.min(window, 5)), 99);
  const ema25Reclaim = previous.close <= ema25Before &&
    current.close > ema25Now;
  const ema25Rejection = previous.close >= ema25Before &&
    current.close < ema25Now;
  const ema25DeltaAtr = (ema25Now - ema25Before) / currentAtr;
  const ema25Trend: MarketBehaviorContext["ema25Trend"] = ema25DeltaAtr > 0.03
    ? "rising"
    : ema25DeltaAtr < -0.03
    ? "falling"
    : "flat";
  const regime: MarketBehaviorContext["regime"] = current.close > ema25Now &&
      ema25Now > ema99Now && ema99Now >= ema99Before
    ? "bullish"
    : current.close < ema25Now && ema25Now < ema99Now && ema99Now <= ema99Before
    ? "bearish"
    : "range";
  const context: MarketBehaviorContext = {
    regime,
    priceVsEma25: current.close >= ema25Now ? "above" : "below",
    priceVsEma99: current.close >= ema99Now ? "above" : "below",
    ema25Trend,
    futuresAvailability: "unavailable",
    summary: regime === "bullish"
      ? "Price and the medium structure are above EMA99."
      : regime === "bearish"
      ? "Price and the medium structure are below EMA99."
      : "The broader structure is mixed around EMA25 and EMA99.",
  };

  const efficiencyDecay = (trend: number) => score(clamp(-trend / 40));
  const progressDecay = (trend: number) => score(clamp(-trend / 40));
  const pressureDivergence = (
    pressureTrend: number,
    responseTrend: number,
    efficiencyTrend: number,
  ) =>
    score(
      0.45 * clamp(pressureTrend / 35) +
        0.30 * clamp(-responseTrend / 35) +
        0.25 * clamp(-efficiencyTrend / 35),
    );
  const sellerFailureDivergence = pressureDivergence(
    input.sellerPressureTrend,
    input.downsideResponseTrend,
    input.sellerEfficiencyTrend,
  );
  const buyerFailureDivergence = pressureDivergence(
    input.buyerPressureTrend,
    input.upsideResponseTrend,
    input.buyerEfficiencyTrend,
  );
  const downsideProgressWeakening = score(
    input.sellerPressure / 100 * clamp(-input.downsideProgressTrend / 35),
  );
  const upsideProgressWeakening = score(
    input.buyerPressure / 100 * clamp(-input.upsideProgressTrend / 35),
  );
  const buyerRecoveryStrengthening = score(
    0.45 * input.buyerRecoveryRatio / 100 +
      0.30 * clamp(input.buyerRecoveryTrend / 35) +
      0.25 * input.buyerRecoverySpeed / 100,
  );
  const sellerRecoveryStrengthening = score(
    0.45 * input.sellerRecoveryRatio / 100 +
      0.30 * clamp(input.sellerRecoveryTrend / 35) +
      0.25 * input.sellerRecoverySpeed / 100,
  );

  const sellerExhaustion = Math.round(
    0.20 * efficiencyDecay(input.sellerEfficiencyTrend) +
      0.20 * progressDecay(input.downsideProgressTrend) +
      0.15 * sellerFailureDivergence +
      0.15 * lowerLowFailure +
      0.10 * input.buySideAbsorption +
      0.10 * buyerRecoveryStrengthening +
      0.10 * Math.max(failedBreakdown, score(input.lowerWickRejection)),
  );
  const buyerExhaustion = Math.round(
    0.20 * efficiencyDecay(input.buyerEfficiencyTrend) +
      0.20 * progressDecay(input.upsideProgressTrend) +
      0.15 * buyerFailureDivergence +
      0.15 * higherHighFailure +
      0.10 * input.sellSideAbsorption +
      0.10 * sellerRecoveryStrengthening +
      0.10 * Math.max(failedBreakout, score(input.upperWickRejection)),
  );
  const buyerStructure = Math.max(
    failedBreakdown,
    input.bullishConfirmation,
    ema25Reclaim ? 75 : 0,
  );
  const sellerStructure = Math.max(
    failedBreakout,
    input.bearishConfirmation,
    ema25Rejection ? 75 : 0,
  );
  const buyerResponse = Math.round(
    0.20 * score(clamp(input.buyerPressureTrend / 35)) +
      0.20 * score(clamp(input.buyerEfficiencyTrend / 35)) +
      0.20 * buyerRecoveryStrengthening +
      0.15 * input.buyerRecoverySpeed +
      0.15 * buyerStructure +
      0.10 * input.upsideResponse,
  );
  const sellerResponse = Math.round(
    0.20 * score(clamp(input.sellerPressureTrend / 35)) +
      0.20 * score(clamp(input.sellerEfficiencyTrend / 35)) +
      0.20 * sellerRecoveryStrengthening +
      0.15 * input.sellerRecoverySpeed +
      0.15 * sellerStructure +
      0.10 * input.downsideResponse,
  );
  const bullishExpansion = Math.round(
    0.35 * input.buyerPressure + 0.35 * input.buyerEfficiency +
      0.30 * input.upsideResponse,
  );
  const bearishExpansion = Math.round(
    0.35 * input.sellerPressure + 0.35 * input.sellerEfficiency +
      0.30 * input.downsideResponse,
  );
  const scores: BehavioralStateScores = {
    sellerExhaustion,
    buyerExhaustion,
    buyerResponse,
    sellerResponse,
    bullishExpansion,
    bearishExpansion,
  };

  const signals: BehavioralSignal[] = [];
  const add = (
    kind: BehavioralSignalKind,
    value: number,
    direction: BehavioralSignal["direction"],
    evidence: string[],
    confirmed = false,
  ) => {
    if (value < 45) return;
    signals.push({
      kind,
      score: value,
      direction,
      status: confirmed ? "confirmed" : "developing",
      trend: value >= 65 ? "rising" : "flat",
      evidence,
    });
  };
  add("lower_low_failure", lowerLowFailure, "bullish", [
    "seller_pressure_present",
    "no_meaningful_new_low",
  ]);
  add("higher_high_failure", higherHighFailure, "bearish", [
    "buyer_pressure_present",
    "no_meaningful_new_high",
  ]);
  add("downside_progress_weakening", downsideProgressWeakening, "bullish", [
    "downside_extensions_shrinking",
  ]);
  add("upside_progress_weakening", upsideProgressWeakening, "bearish", [
    "upside_extensions_shrinking",
  ]);
  add("sell_pressure_downside_divergence", sellerFailureDivergence, "bullish", [
    "seller_pressure_rising",
    "downside_response_falling",
  ]);
  add("buy_pressure_upside_divergence", buyerFailureDivergence, "bearish", [
    "buyer_pressure_rising",
    "upside_response_falling",
  ]);
  add("failed_breakdown", failedBreakdown, "bullish", [
    "support_broken",
    "support_reclaimed",
  ], failedBreakdown >= 60);
  add("failed_breakout", failedBreakout, "bearish", [
    "resistance_broken",
    "resistance_rejected",
  ], failedBreakout >= 60);
  add("buyer_recovery_strengthening", buyerRecoveryStrengthening, "bullish", [
    "recovery_ratio_rising",
    "recovery_speed_measured",
  ]);
  add("seller_recovery_strengthening", sellerRecoveryStrengthening, "bearish", [
    "recovery_ratio_rising",
    "recovery_speed_measured",
  ]);
  add("seller_exhaustion", sellerExhaustion, "bullish", [
    "seller_efficiency_falling",
    "downside_progress_falling",
  ]);
  add("buyer_exhaustion", buyerExhaustion, "bearish", [
    "buyer_efficiency_falling",
    "upside_progress_falling",
  ]);
  const buyerTakeover = sellerExhaustion >= 65 && buyerResponse >= 60 &&
    buyerStructure >= 50;
  const sellerTakeover = buyerExhaustion >= 65 && sellerResponse >= 60 &&
    sellerStructure >= 50;
  if (buyerTakeover) {
    add(
      "buyer_takeover",
      Math.round(average([
        sellerExhaustion,
        buyerResponse,
        buyerStructure,
      ])),
      "bullish",
      [
        "seller_exhaustion",
        "buyer_response",
        "structure_reclaimed",
      ],
      true,
    );
  }
  if (sellerTakeover) {
    add(
      "seller_takeover",
      Math.round(average([
        buyerExhaustion,
        sellerResponse,
        sellerStructure,
      ])),
      "bearish",
      [
        "buyer_exhaustion",
        "seller_response",
        "structure_broken",
      ],
      true,
    );
  }
  signals.sort((left, right) =>
    Number(right.status === "confirmed") -
      Number(left.status === "confirmed") ||
    right.score - left.score
  );

  return {
    context,
    scores,
    signals,
    lowerLowFailure,
    higherHighFailure,
    failedBreakdown,
    failedBreakout,
    ema25Reclaim,
    ema25Rejection,
  };
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
  const downsideProgressTrend = bounded(trendOf(
    recentTail.map((item) =>
      rank((value) => value.newLowProgressAtr, item.value.newLowProgressAtr)
    ),
  ));
  const upsideProgressTrend = bounded(trendOf(
    recentTail.map((item) =>
      rank((value) => value.newHighProgressAtr, item.value.newHighProgressAtr)
    ),
  ));
  const downsideResponseTrend = bounded(trendOf(
    recentTail.map((item) =>
      rank((value) => value.downResponseRaw, item.value.downResponseRaw)
    ),
  ));
  const upsideResponseTrend = bounded(trendOf(
    recentTail.map((item) =>
      rank((value) => value.upResponseRaw, item.value.upResponseRaw)
    ),
  ));
  const buyerRecoveryRatio = rank(
    (value) => value.buyerRecoveryRatio,
    current.buyerRecoveryRatio,
  );
  const sellerRecoveryRatio = rank(
    (value) => value.sellerRecoveryRatio,
    current.sellerRecoveryRatio,
  );
  const buyerRecoverySpeed = rank(
    (value) => value.buyerRecoverySpeed,
    current.buyerRecoverySpeed,
  );
  const sellerRecoverySpeed = rank(
    (value) => value.sellerRecoverySpeed,
    current.sellerRecoverySpeed,
  );
  const buyerRecoveryTrend = bounded(trendOf(
    recentTail.map((item) =>
      rank((value) => value.buyerRecoveryRatio, item.value.buyerRecoveryRatio)
    ),
  ));
  const sellerRecoveryTrend = bounded(trendOf(
    recentTail.map((item) =>
      rank((value) => value.sellerRecoveryRatio, item.value.sellerRecoveryRatio)
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
    return score(
      gate * (
        0.35 * (pressure / 100) +
        0.25 * (1 - efficiency / 100) +
        0.20 * clamp(-trend / 35) +
        0.12 * divergence +
        0.08 * wick
      ),
    );
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

  const behavior = behavioralLayer({
    candles,
    window,
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
    downsideProgressTrend,
    upsideProgressTrend,
    downsideResponseTrend,
    upsideResponseTrend,
    buyerRecoveryRatio,
    sellerRecoveryRatio,
    buyerRecoveryTrend,
    sellerRecoveryTrend,
    buyerRecoverySpeed,
    sellerRecoverySpeed,
    bullishConfirmation,
    bearishConfirmation,
    lowerWickRejection: current.lowerWickRejection,
    upperWickRejection: current.upperWickRejection,
  });

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
  let classification = classifyMarketState(metrics, previousState);
  const confirmedTransition = behavior.signals.find((signal) =>
    signal.status === "confirmed" &&
    (signal.kind === "buyer_takeover" || signal.kind === "seller_takeover")
  );
  if (confirmedTransition?.kind === "buyer_takeover") {
    classification = {
      state: "buyer_takeover",
      stateScore: confirmedTransition.score,
    };
  } else if (confirmedTransition?.kind === "seller_takeover") {
    classification = {
      state: "seller_takeover",
      stateScore: confirmedTransition.score,
    };
  } else if (behavior.scores.sellerExhaustion >= 65) {
    classification = {
      state: "seller_exhaustion",
      stateScore: behavior.scores.sellerExhaustion,
    };
  } else if (behavior.scores.buyerExhaustion >= 65) {
    classification = {
      state: "buyer_exhaustion",
      stateScore: behavior.scores.buyerExhaustion,
    };
  }

  return {
    ...classification,
    ...metrics,
    bounceReadiness,
    rolloverReadiness,
    buyerResilience,
    sellerResilience,
    context: behavior.context,
    behavioralScores: behavior.scores,
    behavioralSignals: behavior.signals,
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
      downsideProgressTrend,
      upsideProgressTrend,
      downsideResponseTrend,
      upsideResponseTrend,
      buyerRecoveryRatio,
      sellerRecoveryRatio,
      buyerRecoveryTrend,
      sellerRecoveryTrend,
      buyerRecoverySpeed,
      sellerRecoverySpeed,
      lowerLowFailure: behavior.lowerLowFailure,
      higherHighFailure: behavior.higherHighFailure,
      failedBreakdown: behavior.failedBreakdown,
      failedBreakout: behavior.failedBreakout,
      ema25Reclaim: behavior.ema25Reclaim,
      ema25Rejection: behavior.ema25Rejection,
    },
  };
}
