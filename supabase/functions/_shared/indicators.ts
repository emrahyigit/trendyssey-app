// EMA/Donchian scoring engine, reconstructed from the deployed scan-market
// bundle so the repo owns the source that is running in production.
// deno-lint-ignore-file no-explicit-any

import {
  BTC_STRENGTH_MAX_SCORE,
  NEUTRAL_BTC_STRENGTH,
  WEAK_BTC_CONFIDENCE_CAP,
  WEAK_BTC_STRENGTH,
} from "./relative_strength.ts";

export interface MarketCandle {
  openTime: number;
  open: number;
  high: number;
  low: number;
  close: number;
  volume: number;
  closeTime: number;
  quoteVolume: number;
  trades: number;
  takerBuyBase: number;
  takerBuyQuote: number;
}

export const DEFAULT_SCORING_CONFIGURATION = {
  model: "gpt-5-6-sol-v1",
  donchianPeriod: 20,
  volumePeriod: 20,
  rsiPeriod: 14,
  emaFastPeriod: 20,
  emaSlowPeriod: 50,
  emaLongPeriod: 200,
  adxPeriod: 14,
  thresholds: {
    proximityAtr: 0.35,
    preBreakoutMinimumConfidence: 55,
    minimumLiquidityUsd: 5_000_000,
    strongLiquidityUsd: 50_000_000,
    minimumBreakoutClearanceAtr: 0.10,
    minimumBreakoutVolumeRatio: 1.30,
    minimumBreakoutAdx: 20,
    maximumCrossAge: 40,
    retestToleranceAtr: 0.25,
    maximumRetestAge: 12,
    confirmationMinimumCloseAtr: 0.05,
    confirmationMinimumVolumeRatio: 0.90,
    confirmationMinimumBodyRatio: 0.25,
    confirmationMaximumUpperWickRatio: 0.45,
    maximumDetectionAge: 3,
    maximumJourneyAge: 12,
  },
  weights: {
    location: 15,
    emaTrend: 20,
    emaRetest: 15,
    volume: 25,
    adx: 15,
    rsi: 5,
    confirmation: 5,
  },
  riskWeights: {
    location: 15,
    volume: 18,
    rejection: 10,
    orderFlow: 8,
    adx: 15,
    rsi: 8,
    trend: 10,
    retest: 6,
    liquidity: 4,
    state: 6,
  },
  activityWeights: {
    volume: 25,
    trades: 15,
    range: 20,
    orderImbalance: 15,
    candleBody: 10,
    bandExpansion: 15,
  },
};

export function parseKlines(rows: any[]): MarketCandle[] {
  return rows.map((r) => ({
    openTime: Number(r[0]),
    open: Number(r[1]),
    high: Number(r[2]),
    low: Number(r[3]),
    close: Number(r[4]),
    volume: Number(r[5]),
    closeTime: Number(r[6]),
    quoteVolume: Number(r[7]),
    trades: Number(r[8]),
    takerBuyBase: Number(r[9]),
    takerBuyQuote: Number(r[10]),
  }));
}

const clamp = (value: number, minimum = 0, maximum = 1) => Math.min(maximum, Math.max(minimum, value));
const average = (values: number[]) => values.length === 0 ? 0 : values.reduce((a, b) => a + b, 0) / values.length;
const median = (values: number[]) => {
  if (values.length === 0) return 0;
  const ordered = [...values].sort((a, b) => a - b);
  const middle = Math.floor(ordered.length / 2);
  return ordered.length % 2 === 0 ? (ordered[middle - 1] + ordered[middle]) / 2 : ordered[middle];
};
const normalize = (value: number, low: number, high: number) => high === low ? 0 : clamp((value - low) / (high - low));
const round = (value: number, digits = 4) => Number(value.toFixed(digits));
const score = (value: number) => Math.round(clamp(value, 0, 100));

function mergeNumbers(defaults: Record<string, number>, input: unknown): Record<string, number> {
  if (!input || typeof input !== "object") return { ...defaults };
  const source = input as Record<string, unknown>;
  return Object.fromEntries(
    Object.entries(defaults).map(([key, value]) => [
      key,
      Number.isFinite(Number(source[key])) ? Number(source[key]) : value,
    ]),
  );
}

export function resolveScoringConfiguration(input: unknown): any {
  if (!input || typeof input !== "object") {
    return structuredClone(DEFAULT_SCORING_CONFIGURATION);
  }
  const source = input as Record<string, unknown>;
  return {
    model: typeof source.model === "string" ? source.model : DEFAULT_SCORING_CONFIGURATION.model,
    donchianPeriod: Math.max(10, Math.round(Number(source.donchianPeriod) || DEFAULT_SCORING_CONFIGURATION.donchianPeriod)),
    volumePeriod: Math.max(10, Math.round(Number(source.volumePeriod) || DEFAULT_SCORING_CONFIGURATION.volumePeriod)),
    rsiPeriod: Math.max(7, Math.round(Number(source.rsiPeriod) || DEFAULT_SCORING_CONFIGURATION.rsiPeriod)),
    emaFastPeriod: Math.max(5, Math.round(Number(source.emaFastPeriod) || DEFAULT_SCORING_CONFIGURATION.emaFastPeriod)),
    emaSlowPeriod: Math.max(10, Math.round(Number(source.emaSlowPeriod) || DEFAULT_SCORING_CONFIGURATION.emaSlowPeriod)),
    emaLongPeriod: Math.max(50, Math.round(Number(source.emaLongPeriod) || DEFAULT_SCORING_CONFIGURATION.emaLongPeriod)),
    adxPeriod: Math.max(7, Math.round(Number(source.adxPeriod) || DEFAULT_SCORING_CONFIGURATION.adxPeriod)),
    thresholds: mergeNumbers(DEFAULT_SCORING_CONFIGURATION.thresholds, source.thresholds),
    weights: mergeNumbers(DEFAULT_SCORING_CONFIGURATION.weights, source.weights),
    riskWeights: mergeNumbers(DEFAULT_SCORING_CONFIGURATION.riskWeights, source.riskWeights),
    activityWeights: mergeNumbers(DEFAULT_SCORING_CONFIGURATION.activityWeights, source.activityWeights),
  };
}

const TIMEFRAME_THRESHOLD_OVERRIDES: Record<string, Record<string, number>> = {
  "15m": {
    minimumBreakoutClearanceAtr: 0.12,
    minimumBreakoutVolumeRatio: 1.40,
    minimumBreakoutAdx: 21,
    confirmationMinimumVolumeRatio: 1.00,
    maximumDetectionAge: 4,
    maximumJourneyAge: 16,
  },
  "1h": {},
  "4h": {
    proximityAtr: 0.30,
    minimumBreakoutClearanceAtr: 0.08,
    minimumBreakoutVolumeRatio: 1.20,
    minimumBreakoutAdx: 18,
    confirmationMinimumVolumeRatio: 0.80,
    maximumRetestAge: 10,
    maximumJourneyAge: 8,
  },
  "1d": {
    proximityAtr: 0.25,
    minimumBreakoutClearanceAtr: 0.07,
    minimumBreakoutVolumeRatio: 1.15,
    minimumBreakoutAdx: 17,
    confirmationMinimumVolumeRatio: 0.75,
    maximumRetestAge: 6,
    maximumJourneyAge: 6,
  },
};

export function resolveTimeframeScoringConfiguration(input: unknown, timeframe: string): any {
  const base = resolveScoringConfiguration(input);
  return {
    ...base,
    thresholds: {
      ...base.thresholds,
      ...(TIMEFRAME_THRESHOLD_OVERRIDES[timeframe] ?? {}),
    },
  };
}

export function ema(values: number[], period: number): number {
  if (values.length === 0) return 0;
  const k = 2 / (period + 1);
  return values.slice(1).reduce((value, next) => next * k + value * (1 - k), values[0]);
}

function emaSeries(values: number[], period: number): number[] {
  if (values.length === 0) return [];
  const multiplier = 2 / (period + 1);
  const result = [values[0]];
  for (const value of values.slice(1)) {
    result.push(value * multiplier + result.at(-1)! * (1 - multiplier));
  }
  return result;
}

export function directionalIndex(candles: MarketCandle[], period = 14) {
  if (candles.length < period * 2 + 1) return { adx: 0, plusDI: 0, minusDI: 0 };
  const trueRanges: number[] = [];
  const plusDM: number[] = [];
  const minusDM: number[] = [];
  for (let index = 1; index < candles.length; index += 1) {
    const current = candles[index];
    const previous = candles[index - 1];
    const upMove = current.high - previous.high;
    const downMove = previous.low - current.low;
    trueRanges.push(Math.max(current.high - current.low, Math.abs(current.high - previous.close), Math.abs(current.low - previous.close)));
    plusDM.push(upMove > downMove && upMove > 0 ? upMove : 0);
    minusDM.push(downMove > upMove && downMove > 0 ? downMove : 0);
  }
  let smoothedTR = trueRanges.slice(0, period).reduce((sum, value) => sum + value, 0);
  let smoothedPlus = plusDM.slice(0, period).reduce((sum, value) => sum + value, 0);
  let smoothedMinus = minusDM.slice(0, period).reduce((sum, value) => sum + value, 0);
  const dxValues: number[] = [];
  let plusDI = smoothedTR > 0 ? 100 * smoothedPlus / smoothedTR : 0;
  let minusDI = smoothedTR > 0 ? 100 * smoothedMinus / smoothedTR : 0;
  dxValues.push(plusDI + minusDI > 0 ? 100 * Math.abs(plusDI - minusDI) / (plusDI + minusDI) : 0);
  for (let index = period; index < trueRanges.length; index += 1) {
    smoothedTR = smoothedTR - smoothedTR / period + trueRanges[index];
    smoothedPlus = smoothedPlus - smoothedPlus / period + plusDM[index];
    smoothedMinus = smoothedMinus - smoothedMinus / period + minusDM[index];
    plusDI = smoothedTR > 0 ? 100 * smoothedPlus / smoothedTR : 0;
    minusDI = smoothedTR > 0 ? 100 * smoothedMinus / smoothedTR : 0;
    dxValues.push(plusDI + minusDI > 0 ? 100 * Math.abs(plusDI - minusDI) / (plusDI + minusDI) : 0);
  }
  const seed = dxValues.slice(0, period);
  let adx = average(seed);
  for (const dx of dxValues.slice(period)) {
    adx = (adx * (period - 1) + dx) / period;
  }
  return { adx, plusDI, minusDI };
}

export function rsi(values: number[], period = 14): number {
  if (values.length < 2) return 50;
  const changes = values.slice(1).map((value, index) => value - values[index]);
  const seed = changes.slice(0, Math.min(period, changes.length));
  let averageGain = average(seed.map((value) => Math.max(value, 0)));
  let averageLoss = average(seed.map((value) => Math.max(-value, 0)));
  for (const change of changes.slice(seed.length)) {
    averageGain = (averageGain * (period - 1) + Math.max(change, 0)) / period;
    averageLoss = (averageLoss * (period - 1) + Math.max(-change, 0)) / period;
  }
  if (averageGain === 0 && averageLoss === 0) return 50;
  if (averageLoss === 0) return 100;
  return 100 - 100 / (1 + averageGain / averageLoss);
}

export function atr(candles: MarketCandle[], period = 14): number {
  if (candles.length < 2) return 0;
  const ranges = candles.slice(1).map((candle, index) => {
    const previousClose = candles[index].close;
    return Math.max(candle.high - candle.low, Math.abs(candle.high - previousClose), Math.abs(candle.low - previousClose));
  });
  const seed = ranges.slice(0, Math.min(period, ranges.length));
  let value = average(seed);
  for (const range of ranges.slice(seed.length)) {
    value = (value * (period - 1) + range) / period;
  }
  return value;
}

function bollingerBandWidth(values: number[], period = 20): number {
  const sample = values.slice(-period);
  const mean = average(sample);
  if (sample.length === 0 || mean === 0) return 0;
  const variance = average(sample.map((value) => (value - mean) ** 2));
  return 4 * Math.sqrt(variance) / Math.abs(mean);
}

function component(metric: string, key: string, name: string, rawValue: number, contribution: number, maximumScore: number, explanation: string) {
  return {
    metric,
    key,
    name,
    rawValue: round(rawValue),
    normalizedValue: maximumScore === 0 ? 0 : round(contribution / maximumScore),
    contribution: round(contribution),
    maximumScore,
    explanation,
  };
}

function confidenceComponents(metrics: any, config: any) {
  const w = config.weights;
  const readiness = metrics.priceBrokeOut || metrics.nearBreakout ? 1 : 0.35;
  const location = metrics.priceBrokeOut
    ? w.location * normalize(metrics.breakoutClearanceAtr, config.thresholds.minimumBreakoutClearanceAtr, 0.70)
    : metrics.nearBreakout
    ? w.location * (1 - normalize(metrics.distanceToLevelAtr, 0, config.thresholds.proximityAtr))
    : 0;
  const priceAboveFast = metrics.current.close > metrics.emaFast ? 0.25 : 0;
  const ordered = metrics.emaFast > metrics.emaSlow && metrics.emaSlow > metrics.emaLong ? 0.35 : 0;
  const slopes = normalize(metrics.emaFastSlope, -0.02, 0.08) * 0.25 + normalize(metrics.emaSlowSlope, -0.01, 0.04) * 0.15;
  const emaTrend = w.emaTrend * clamp(priceAboveFast + ordered + slopes) * readiness;
  const retestQuality = metrics.emaRetest ? 0.65 + 0.35 * (1 - normalize(metrics.retestVolumeRatio, 0.70, 1.15)) : 0;
  const emaRetest = w.emaRetest * retestQuality * readiness;
  const breakoutVolume = metrics.priceBrokeOut ? normalize(metrics.volumeRatio, 1.10, 2.50) : 0.35;
  const contraction = 1 - normalize(metrics.volumeContractionRatio, 0.72, 1.10);
  const buyerFlow = normalize(metrics.takerBuyRatio, 0.48, 0.62);
  const volume = w.volume * clamp(breakoutVolume * 0.60 + contraction * 0.20 + buyerFlow * 0.20) * readiness;
  const adxStrength = normalize(metrics.adx, 15, 35) * 0.45;
  const adxSlope = normalize(metrics.adxDelta3, -2, 5) * 0.25;
  const diDominance = normalize(metrics.plusDI - metrics.minusDI, -5, 15) * 0.30;
  const adx = w.adx * clamp(adxStrength + adxSlope + diDominance) * readiness;
  const rsiLevel = metrics.rsi >= 52 && metrics.rsi <= 68
    ? 1
    : metrics.rsi >= 45 && metrics.rsi < 52
    ? normalize(metrics.rsi, 45, 52)
    : metrics.rsi > 68 && metrics.rsi < 78
    ? 1 - normalize(metrics.rsi, 68, 78)
    : 0;
  const rsiMomentum = normalize(metrics.rsiDelta3, -3, 4);
  const rsi = w.rsi * (rsiLevel * 0.75 + rsiMomentum * 0.25) * readiness;
  const bullish = metrics.current.close > metrics.current.open;
  const candleMultiplier = bullish
    ? 0.55 + 0.25 * normalize(metrics.bodyRatio, 0.35, 0.70) + 0.20 * (1 - normalize(metrics.upperWickRatio, 0.15, 0.40))
    : 0.35;
  return [
    component("confidence", "confidence.location", "Breakout structure", metrics.priceBrokeOut ? metrics.breakoutClearanceAtr : metrics.distanceToLevelAtr, location * candleMultiplier, w.location, "ATR-normalized level clearance combined with candle body and rejection quality."),
    component("confidence", "confidence.emaTrend", "EMA trend structure", metrics.emaFastSlope, emaTrend, w.emaTrend, "EMA20/50/200 ordering and ATR-normalized EMA slopes."),
    component("confidence", "confidence.emaRetest", "EMA retest quality", metrics.retestVolumeRatio, emaRetest, w.emaRetest, "Hold of the EMA20-EMA50 zone with contracting pullback volume."),
    component("confidence", "confidence.volume", "Volume journey", metrics.volumeRatio, volume, w.volume, "Retest contraction, breakout relative volume and taker-buy participation."),
    component("confidence", "confidence.adx", "ADX trend strength", metrics.adx, adx, w.adx, "ADX strength and slope combined with +DI dominance."),
    component("confidence", "confidence.rsi", "RSI momentum regime", metrics.rsi, rsi, w.rsi, "RSI level and three-candle momentum without exhaustion."),
    component("confidence", "confidence.confirmation", "Level confirmation", 0, 0, w.confirmation, "A later close holding the tracked breakout level."),
  ];
}

function riskComponents(metrics: any, config: any, quoteVolume24h: number) {
  const w = config.riskWeights;
  const location = metrics.priceBrokeOut
    ? w.location * (1 - normalize(metrics.breakoutClearanceAtr, config.thresholds.minimumBreakoutClearanceAtr, 0.55))
    : w.location * (0.48 + 0.52 * normalize(metrics.distanceToLevelAtr, 0, config.thresholds.proximityAtr));
  const volume = w.volume * clamp((1 - normalize(metrics.volumeRatio, 1.0, 2.0)) * 0.70 + normalize(metrics.volumeContractionRatio, 0.80, 1.20) * 0.30);
  const rejection = w.rejection * normalize(metrics.upperWickRatio, 0.12, 0.50);
  const orderFlow = w.orderFlow * (1 - normalize(metrics.takerBuyRatio, 0.42, 0.58));
  const adx = w.adx * clamp((1 - normalize(metrics.adx, 15, 30)) * 0.55 + (1 - normalize(metrics.adxDelta3, -2, 5)) * 0.20 + (1 - normalize(metrics.plusDI - metrics.minusDI, -5, 15)) * 0.25);
  const rsiRisk = metrics.rsi > 72
    ? w.rsi * normalize(metrics.rsi, 72, 85)
    : metrics.rsi < 42
    ? w.rsi * 0.5 * (1 - normalize(metrics.rsi, 30, 42))
    : 0;
  const trend = w.trend * clamp((metrics.emaFast <= metrics.emaSlow ? 0.45 : 0) + (metrics.emaSlow <= metrics.emaLong ? 0.30 : 0) + (metrics.emaFastSlope <= 0 ? 0.15 : 0) + (metrics.emaSlowSlope < 0 ? 0.10 : 0));
  const retest = w.retest * (metrics.emaRetest ? normalize(metrics.retestVolumeRatio, 0.75, 1.25) * 0.35 : 1);
  const liquidity = quoteVolume24h <= 0
    ? w.liquidity
    : w.liquidity * (1 - normalize(Math.log10(Math.max(quoteVolume24h, 1)), Math.log10(config.thresholds.minimumLiquidityUsd), Math.log10(config.thresholds.strongLiquidityUsd)));
  return [
    component("risk", "risk.location", "Level clearance risk", metrics.priceBrokeOut ? metrics.breakoutClearanceAtr : metrics.distanceToLevelAtr, location, w.location, "A marginal close or no close above resistance increases failure risk."),
    component("risk", "risk.volume", "Weak-volume risk", metrics.volumeRatio, volume, w.volume, "Low quote-volume participation reduces persistence."),
    component("risk", "risk.rejection", "Upper-wick rejection", metrics.upperWickRatio, rejection, w.rejection, "A long upper wick indicates rejection above the level."),
    component("risk", "risk.orderFlow", "Seller-pressure risk", metrics.takerBuyRatio, orderFlow, w.orderFlow, "Weak taker-buy share increases false-breakout risk."),
    component("risk", "risk.adx", "ADX weakness risk", metrics.adx, adx, w.adx, "Weak or falling ADX and missing +DI dominance increase failure risk."),
    component("risk", "risk.rsi", "RSI exhaustion risk", metrics.rsi, rsiRisk, w.rsi, "Exhausted or weak RSI conditions add risk."),
    component("risk", "risk.trend", "Trend-conflict risk", metrics.emaFast - metrics.emaSlow, trend, w.trend, "EMA20/50/200 ordering or slope conflicts with an upward breakout."),
    component("risk", "risk.retest", "Missing-retest risk", metrics.retestVolumeRatio, retest, w.retest, "A missing EMA-zone retest or heavy retest volume weakens the setup."),
    component("risk", "risk.liquidity", "Liquidity risk", quoteVolume24h, liquidity, w.liquidity, "Lower 24-hour quote liquidity increases execution and persistence risk."),
    component("risk", "risk.state", "Signal-state risk", 0, 0, w.state, "Lifecycle confirmation can reduce or increase risk."),
  ];
}

function activityComponents(metrics: any, config: any) {
  const w = config.activityWeights;
  return [
    component("activity", "activity.volume", "Volume intensity", metrics.volumeRatio, w.volume * normalize(metrics.volumeRatio, 0.8, 3), w.volume, "Quote-volume intensity versus baseline."),
    component("activity", "activity.trades", "Trade-count intensity", metrics.tradeRatio, w.trades * normalize(metrics.tradeRatio, 0.8, 2.5), w.trades, "Trade count versus the prior closed-candle baseline."),
    component("activity", "activity.range", "Range expansion", metrics.rangeAtrRatio, w.range * normalize(metrics.rangeAtrRatio, 0.7, 2), w.range, "True range relative to previous ATR."),
    component("activity", "activity.orderImbalance", "Taker imbalance", Math.abs(metrics.takerBuyRatio - 0.5), w.orderImbalance * normalize(Math.abs(metrics.takerBuyRatio - 0.5), 0.02, 0.15), w.orderImbalance, "Magnitude of taker imbalance, independent of direction."),
    component("activity", "activity.candleBody", "Candle expansion", metrics.bodyRatio, w.candleBody * normalize(metrics.bodyRatio, 0.2, 0.8), w.candleBody, "Candle-body share of the full range."),
    component("activity", "activity.bandExpansion", "Band expansion", metrics.bollingerBandWidthChange, w.bandExpansion * normalize(metrics.bollingerBandWidthChange, -5, 25), w.bandExpansion, "Bollinger bandwidth expansion versus the prior close."),
  ];
}

export function analyze(candles: MarketCandle[], inputConfiguration: unknown, context: { referenceLevel?: number; quoteVolume24h?: number } = {}): any {
  const configuration = resolveScoringConfiguration(inputConfiguration);
  const minimumCandles = Math.max(configuration.donchianPeriod, configuration.volumePeriod, configuration.rsiPeriod, configuration.emaLongPeriod + 20, configuration.adxPeriod * 2 + 5) + 2;
  if (candles.length < minimumCandles) {
    throw new Error(`At least ${minimumCandles} closed candles are required.`);
  }
  const current = candles.at(-1)!;
  const history = candles.slice(0, -1);
  const donchianWindow = history.slice(-configuration.donchianPeriod);
  const baseline = history.slice(-configuration.volumePeriod);
  const donchianLevel = Math.max(...donchianWindow.map((candle) => candle.high));
  const level = Number.isFinite(context.referenceLevel) ? Number(context.referenceLevel) : donchianLevel;
  const baselineQuoteVolume = Math.max(median(baseline.map((candle) => candle.quoteVolume)), Number.EPSILON);
  const averageTrades = Math.max(average(baseline.map((candle) => candle.trades)), Number.EPSILON);
  const volumeRatio = current.quoteVolume / baselineQuoteVolume;
  const tradeRatio = current.trades / averageTrades;
  const takerBuyRatio = current.quoteVolume > 0 ? clamp(current.takerBuyQuote / current.quoteVolume) : 0.5;
  const estimatedDelta = current.takerBuyQuote - (current.quoteVolume - current.takerBuyQuote);
  const contractionRecent = history.slice(-5).map((candle) => candle.quoteVolume);
  const contractionBaseline = history.slice(-(configuration.volumePeriod + 5), -5).map((candle) => candle.quoteVolume);
  const volumeContractionRatio = median(contractionRecent) / Math.max(median(contractionBaseline.length > 0 ? contractionBaseline : baseline.map((candle) => candle.quoteVolume)), Number.EPSILON);
  const currentATR = atr(candles);
  const previousATR = atr(candles.slice(0, -1));
  const atrChange = previousATR > 0 ? (currentATR / previousATR - 1) * 100 : 0;
  const closes = candles.map((candle) => candle.close);
  const currentRSI = rsi(closes, configuration.rsiPeriod);
  const previousRSI = rsi(closes.slice(0, -3), configuration.rsiPeriod);
  const rsiDelta3 = currentRSI - previousRSI;
  const emaFastSeries = emaSeries(closes, configuration.emaFastPeriod);
  const emaSlowSeries = emaSeries(closes, configuration.emaSlowPeriod);
  const emaLongSeries = emaSeries(closes, configuration.emaLongPeriod);
  const emaFast = emaFastSeries.at(-1)!;
  const emaSlow = emaSlowSeries.at(-1)!;
  const emaLong = emaLongSeries.at(-1)!;
  const slopeLookback = 5;
  const emaFastSlope = currentATR > 0 ? (emaFast - emaFastSeries.at(-(slopeLookback + 1))!) / (slopeLookback * currentATR) : 0;
  const emaSlowSlope = currentATR > 0 ? (emaSlow - emaSlowSeries.at(-(slopeLookback + 1))!) / (slopeLookback * currentATR) : 0;
  let crossIndex = -1;
  const crossStart = Math.max(1, closes.length - 1 - Math.round(configuration.thresholds.maximumCrossAge));
  for (let index = crossStart; index < closes.length; index += 1) {
    if (emaFastSeries[index] > emaSlowSeries[index] && emaFastSeries[index - 1] <= emaSlowSeries[index - 1]) crossIndex = index;
  }
  const emaCrossAge = crossIndex >= 0 ? closes.length - 1 - crossIndex : -1;
  const oldestRecentRetest = Math.max(1, candles.length - 1 - Math.round(configuration.thresholds.maximumRetestAge));
  const retestStart = crossIndex >= 0 ? Math.max(crossIndex + 1, oldestRecentRetest) : oldestRecentRetest;
  let retestIndex = -1;
  for (let index = retestStart; index < candles.length - 1; index += 1) {
    const candle = candles[index];
    const top = Math.max(emaFastSeries[index], emaSlowSeries[index]);
    const bottom = Math.min(emaFastSeries[index], emaSlowSeries[index]);
    const historicalATR = atr(candles.slice(0, index + 1));
    const tolerance = historicalATR * configuration.thresholds.retestToleranceAtr;
    const touchesZone = candle.low <= top + tolerance && candle.high >= bottom - tolerance;
    const holdsSlowEMA = candle.close >= emaSlowSeries[index] - historicalATR * 0.50;
    if (touchesZone && holdsSlowEMA) retestIndex = index;
  }
  const emaRetest = retestIndex >= 0;
  const emaRetestAge = emaRetest ? candles.length - 1 - retestIndex : -1;
  const retestBaseline = emaRetest ? median(candles.slice(Math.max(0, retestIndex - configuration.volumePeriod), retestIndex).map((candle) => candle.quoteVolume)) : 0;
  const retestVolumeRatio = emaRetest ? candles[retestIndex].quoteVolume / Math.max(retestBaseline, Number.EPSILON) : 0;
  // EMA journey fields consumed by the crossover state machine (kept identical
  // to the on-device Swift EMAJourneyAnalyzer so both sides agree).
  const prevFastEMA = emaFastSeries.at(-2)!;
  const prevSlowEMA = emaSlowSeries.at(-2)!;
  const prevClose = history.at(-1)!.close;
  const crossedUp = prevFastEMA <= prevSlowEMA && emaFast > emaSlow;
  const crossedDown = prevFastEMA >= prevSlowEMA && emaFast < emaSlow;
  const supportBreakBand = 1 - 0.002;
  const closedBelowSupportBand = current.close < emaSlow * supportBreakBand;
  const previousClosedBelowSupportBand = prevClose < prevSlowEMA * supportBreakBand;
  const touchedSupport = current.low <= emaSlow * 1.002;
  const preBreakoutGap = emaFast < emaSlow ? (emaSlow - emaFast) / Math.max(current.close, Number.EPSILON) : 0;
  const previousPreBreakoutGap = prevFastEMA < prevSlowEMA ? (prevSlowEMA - prevFastEMA) / Math.max(prevClose, Number.EPSILON) : 0;
  const heldAboveSupport3 = closes.length >= 3 && [1, 2, 3].every((back) => closes.at(-back)! > emaSlowSeries.at(-back)!);
  let closesAboveFastStreak = 0;
  for (let back = 1; back <= closes.length; back += 1) {
    if (closes.at(-back)! > emaFastSeries.at(-back)!) closesAboveFastStreak += 1;
    else break;
  }
  const emaLongRising = emaLong >= emaLongSeries.at(-2)!;
  const alignedTrend = current.close > emaFast && emaFast > emaSlow && emaSlow > emaLong && emaFastSlope > 0 && emaSlowSlope >= 0;
  const setupType = crossIndex >= 0 ? (emaRetest ? "cross_retest" : "cross_pending_retest") : alignedTrend ? "trend_continuation" : "range_breakout";
  const currentDI = directionalIndex(candles, configuration.adxPeriod);
  const previousDI = directionalIndex(candles.slice(0, -3), configuration.adxPeriod);
  const adxDelta3 = currentDI.adx - previousDI.adx;
  const range = Math.max(current.high - current.low, Number.EPSILON);
  const bodyRatio = Math.abs(current.close - current.open) / range;
  const upperWickRatio = Math.max(0, current.high - Math.max(current.open, current.close)) / range;
  const breakoutClearanceAtr = currentATR > 0 ? (current.close - level) / currentATR : 0;
  const distanceToLevelAtr = currentATR > 0 ? Math.max(0, level - current.close) / currentATR : 99;
  const priceBrokeOut = breakoutClearanceAtr >= configuration.thresholds.minimumBreakoutClearanceAtr;
  const nearBreakout = !priceBrokeOut && distanceToLevelAtr <= configuration.thresholds.proximityAtr;
  const trueRange = Math.max(range, Math.abs(current.high - history.at(-1)!.close), Math.abs(current.low - history.at(-1)!.close));
  const rangeAtrRatio = previousATR > 0 ? trueRange / previousATR : 0;
  const bollingerBandWidthCurrent = bollingerBandWidth(closes);
  const bollingerBandWidthPrevious = bollingerBandWidth(closes.slice(0, -1));
  const bollingerBandWidthChange = bollingerBandWidthPrevious > 0 ? (bollingerBandWidthCurrent / bollingerBandWidthPrevious - 1) * 100 : 0;
  const trendSetup = clamp((current.close > emaFast ? 0.25 : 0) + (emaFast > emaSlow ? 0.25 : 0) + (emaSlow > emaLong ? 0.20 : 0) + normalize(emaFastSlope, -0.02, 0.08) * 0.20 + normalize(emaSlowSlope, -0.01, 0.04) * 0.10);
  const retestSetup = emaRetest ? 0.65 + 0.35 * (1 - normalize(retestVolumeRatio, 0.70, 1.15)) : 0;
  const volumeSetup = clamp((1 - normalize(volumeContractionRatio, 0.72, 1.10)) * 0.65 + normalize(takerBuyRatio, 0.48, 0.60) * 0.35);
  const adxSetup = clamp(normalize(currentDI.adx, 15, 30) * 0.45 + normalize(adxDelta3, -2, 5) * 0.25 + normalize(currentDI.plusDI - currentDI.minusDI, -5, 15) * 0.30);
  const rsiSetup = currentRSI >= 45 && currentRSI <= 68
    ? clamp(0.60 + normalize(currentRSI, 45, 60) * 0.40)
    : currentRSI > 68 && currentRSI < 78
    ? 1 - normalize(currentRSI, 68, 78)
    : 0;
  const setupScore = score(trendSetup * 25 + retestSetup * 20 + volumeSetup * 20 + adxSetup * 20 + rsiSetup * 15);
  const metrics = {
    current,
    level,
    donchianLevel,
    priceBrokeOut,
    brokeOut: false,
    nearBreakout,
    volumeRatio,
    tradeRatio,
    takerBuyRatio,
    estimatedDelta,
    volumeContractionRatio,
    retestVolumeRatio,
    atr: currentATR,
    atrChange,
    rangeAtrRatio,
    rsi: currentRSI,
    rsiDelta3,
    emaFast,
    emaSlow,
    emaLong,
    emaFastSlope,
    emaSlowSlope,
    emaCrossAge,
    emaRetest,
    emaRetestAge,
    crossedUp,
    crossedDown,
    closedBelowSupportBand,
    previousClosedBelowSupportBand,
    touchedSupport,
    preBreakoutGap,
    previousPreBreakoutGap,
    heldAboveSupport3,
    closesAboveFastStreak,
    emaLongRising,
    setupType,
    setupScore,
    adx: currentDI.adx,
    adxDelta3,
    plusDI: currentDI.plusDI,
    minusDI: currentDI.minusDI,
    bodyRatio,
    upperWickRatio,
    breakoutClearanceAtr,
    distanceToLevelAtr,
    bollingerBandWidth: bollingerBandWidthCurrent,
    bollingerBandWidthChange,
  };
  const confidenceParts = confidenceComponents(metrics, configuration);
  const riskParts = riskComponents(metrics, configuration, context.quoteVolume24h ?? 0);
  const activityParts = activityComponents(metrics, configuration);
  let confidence = score(confidenceParts.reduce((sum, item) => sum + item.contribution, 0));
  if (!priceBrokeOut) confidence = Math.min(confidence, nearBreakout ? 69 : 39);
  if (priceBrokeOut && volumeRatio < 1.10) {
    confidence = Math.min(confidence, 64);
  }
  if (priceBrokeOut && currentDI.adx < 15) {
    confidence = Math.min(confidence, 59);
  }
  if (priceBrokeOut && currentDI.plusDI <= currentDI.minusDI) {
    confidence = Math.min(confidence, 64);
  }
  if (priceBrokeOut && current.close < emaSlow) {
    confidence = Math.min(confidence, 59);
  }
  const brokeOut = priceBrokeOut && confidence >= 60 && volumeRatio >= configuration.thresholds.minimumBreakoutVolumeRatio && currentDI.adx >= configuration.thresholds.minimumBreakoutAdx && currentDI.plusDI > currentDI.minusDI;
  return {
    ...metrics,
    brokeOut,
    confidence,
    risk: score(riskParts.reduce((sum, item) => sum + item.contribution, 0)),
    activity: score(activityParts.reduce((sum, item) => sum + item.contribution, 0)),
    scoreComponents: [...confidenceParts, ...riskParts, ...activityParts],
    configuration,
  };
}

// The unified EMA-crossover confidence recipe (emaConfidenceFactors /
// emaConfidence / applySignalState) retired in Aug 2026: the tournament
// trend model (_shared/trend_score.ts) is the score now.
