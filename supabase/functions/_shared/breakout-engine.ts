// Shared level-breakout engine. Detection answers "which level is being
// watched?" while the four scores answer four different product questions:
// regime, readiness, breakout quality and post-breakout confirmation.
// deno-lint-ignore-file no-explicit-any

import {
  analyze,
  atr,
  type MarketCandle,
  resolveTimeframeScoringConfiguration,
} from "./indicators.ts";
import {
  NEUTRAL_BTC_STRENGTH,
  WEAK_BTC_CONFIDENCE_CAP,
  WEAK_BTC_STRENGTH,
} from "./relative_strength.ts";

export type BreakoutEngineKind =
  | "donchian"
  | "horizontal_level"
  | "consolidation";

export interface BreakoutScores {
  regimeScore: number;
  readinessScore: number;
  breakoutQualityScore: number;
  confirmationScore: number;
  breakoutTriggered: boolean;
}

export interface LevelBreakoutAnalysis extends Record<string, any> {
  engineKind: BreakoutEngineKind;
  level: number;
  levelQuality: number;
  levelTouches: number;
  scores: BreakoutScores;
}

const clamp = (value: number, minimum = 0, maximum = 1) =>
  Math.min(maximum, Math.max(minimum, value));
const points = (value: number, maximum: number) =>
  Math.round(clamp(value) * maximum);

interface LevelCandidate {
  level: number;
  quality: number;
  touches: number;
  valid: boolean;
}

function donchianLevel(
  candles: MarketCandle[],
  period: number,
): LevelCandidate {
  const history = candles.slice(0, -1).slice(-period);
  const level = Math.max(...history.map((candle) => candle.high));
  const currentATR = Math.max(atr(candles), Number.EPSILON);
  const tolerance = currentATR * 0.25;
  const touches =
    history.filter((candle) => Math.abs(candle.high - level) <= tolerance)
      .length;
  return {
    level,
    touches,
    valid: true,
    quality: Math.min(
      100,
      45 + Math.min(touches, 4) * 10 + Math.min(period, 50) * 0.3,
    ),
  };
}

function pivotHighs(
  candles: MarketCandle[],
  window = 3,
): Array<{ index: number; price: number }> {
  const history = candles.slice(0, -1);
  const pivots: Array<{ index: number; price: number }> = [];
  for (let index = window; index < history.length - window; index += 1) {
    const price = history[index].high;
    const isPivot = history
      .slice(index - window, index + window + 1)
      .every((candle, offset) => offset === window || candle.high <= price);
    if (isPivot) pivots.push({ index, price });
  }
  return pivots;
}

function horizontalLevel(candles: MarketCandle[]): LevelCandidate {
  const current = candles.at(-1)!;
  const currentATR = Math.max(atr(candles), Number.EPSILON);
  const tolerance = currentATR * 0.35;
  const candidates = pivotHighs(candles).filter((pivot) =>
    pivot.price >= current.close - currentATR * 0.50
  );
  if (candidates.length === 0) {
    return {
      ...donchianLevel(candles, 20),
      quality: 0,
      touches: 0,
      valid: false,
    };
  }

  let best: LevelCandidate & { lastIndex: number } | null = null;
  for (const pivot of candidates) {
    const cluster = candidates.filter((other) =>
      Math.abs(other.price - pivot.price) <= tolerance
    );
    const level = cluster.reduce((sum, item) => sum + item.price, 0) /
      cluster.length;
    const dispersion = cluster.reduce((sum, item) =>
      sum + Math.abs(item.price - level), 0) /
      Math.max(cluster.length, 1);
    const quality = Math.min(
      100,
      30 + Math.min(cluster.length, 5) * 13 +
        points(1 - dispersion / tolerance, 20),
    );
    const lastIndex = Math.max(...cluster.map((item) => item.index));
    if (
      !best || quality > best.quality ||
      (quality === best.quality && lastIndex > best.lastIndex)
    ) {
      best = {
        level,
        quality,
        touches: cluster.length,
        valid: cluster.length >= 2,
        lastIndex,
      };
    }
  }
  return best ??
    { ...donchianLevel(candles, 20), quality: 0, touches: 0, valid: false };
}

function consolidationLevel(
  candles: MarketCandle[],
  period = 20,
): LevelCandidate {
  const history = candles.slice(0, -1).slice(-period);
  const high = Math.max(...history.map((candle) => candle.high));
  const low = Math.min(...history.map((candle) => candle.low));
  const currentATR = Math.max(atr(candles), Number.EPSILON);
  const widthATR = (high - low) / currentATR;
  const tolerance = currentATR * 0.25;
  const touches =
    history.filter((candle) => Math.abs(candle.high - high) <= tolerance)
      .length;
  // A compact range with repeated tests receives the best level score.
  const compactness = 1 - clamp((widthATR - 2) / 6);
  return {
    level: high,
    touches,
    valid: widthATR <= 6 && touches >= 2,
    quality: Math.min(100, points(compactness, 60) + Math.min(touches, 4) * 10),
  };
}

function detectLevel(
  candles: MarketCandle[],
  engineKind: BreakoutEngineKind,
  period: number,
): LevelCandidate {
  switch (engineKind) {
    case "donchian":
      return donchianLevel(candles, period);
    case "horizontal_level":
      return horizontalLevel(candles);
    case "consolidation":
      return consolidationLevel(candles, period);
  }
}

export function nextLevelSignalState(
  previous: string,
  analysis: LevelBreakoutAnalysis,
  trackedLevel: number,
  journeyAge: number,
  isNewCandle: boolean,
): string {
  if (!isNewCandle) return previous;
  const current = analysis.current as MarketCandle;
  const previousCandle = analysis.previousCandle as MarketCandle;
  const currentATR = Math.max(Number(analysis.atr), Number.EPSILON);
  const inJourney = previous === "breakout_detected" || previous === "retest" ||
    previous === "confirmed";
  const failed = current.close < trackedLevel - currentATR * 0.15 &&
    previousCandle.close < trackedLevel - currentATR * 0.15;
  const testing = current.low <= trackedLevel + currentATR * 0.20;
  const held = current.close > trackedLevel + currentATR * 0.05;

  if (inJourney) {
    if (failed) return "failed";
    if (
      journeyAge > Number(analysis.configuration.thresholds.maximumJourneyAge)
    ) {
      return "expired";
    }
    if (previous === "retest" && held && current.close > current.open) {
      return "confirmed";
    }
    if (previous !== "retest" && testing) return "retest";
    if (previous === "breakout_detected" && journeyAge >= 3 && held) {
      return "confirmed";
    }
    return previous;
  }

  const crossedNow = analysis.setupValid &&
    previousCandle.close <= trackedLevel &&
    current.close >=
      trackedLevel +
        currentATR *
          analysis.configuration.thresholds.minimumBreakoutClearanceAtr;
  if (crossedNow) return "breakout_detected";
  return analysis.nearBreakout ? "pre_breakout" : "watching";
}

function scoresFor(
  analysis: any,
  status: string,
  levelQuality: number,
  levelTouches: number,
  btcScore: number,
): BreakoutScores {
  const current = analysis.current as MarketCandle;
  const trendAlignment = clamp(
    (current.close > analysis.emaFast ? 0.18 : 0) +
      (analysis.emaFast > analysis.emaSlow ? 0.22 : 0) +
      (analysis.emaSlow > analysis.emaLong ? 0.20 : 0) +
      clamp((analysis.emaFastSlope + 0.02) / 0.10) * 0.15 +
      clamp((analysis.emaSlowSlope + 0.01) / 0.05) * 0.10 +
      clamp((analysis.adx - 15) / 20) * 0.15,
  );
  const regimeScore = points(trendAlignment, 100);

  const proximity = analysis.priceBrokeOut ? 1 : 1 -
    clamp(
      analysis.distanceToLevelAtr /
        Math.max(analysis.configuration.thresholds.proximityAtr, 0.01),
    );
  const contraction = 1 -
    clamp((analysis.volumeContractionRatio - 0.65) / 0.55);
  const bandCompression = 1 -
    clamp((analysis.bollingerBandWidthChange + 5) / 25);
  const testQuality = clamp(levelTouches / 4);
  let readinessScore = Math.round(
    points(proximity, 35) + points(contraction, 20) +
      points(bandCompression, 15) +
      points(testQuality, 15) + points(trendAlignment, 15),
  );
  if (!analysis.setupValid) readinessScore = Math.min(readinessScore, 39);

  const bullishClose = current.close > current.open ? 1 : 0;
  const clearance = clamp((analysis.breakoutClearanceAtr - 0.05) / 0.65);
  const volume = clamp((analysis.volumeRatio - 0.8) / 1.7);
  const body = clamp((analysis.bodyRatio - 0.25) / 0.50);
  const wick = 1 - clamp((analysis.upperWickRatio - 0.10) / 0.35);
  const market = clamp(btcScore / 15);
  // A green close is nearly binary and partly overlaps the body component, so
  // it carries 15 rather than 20; the freed points go to market alignment —
  // in crypto, strength versus BTC is one of the best follow-through filters.
  let breakoutQualityScore = analysis.priceBrokeOut && analysis.setupValid
    ? points(bullishClose, 15) + points(clearance, 15) + points(volume, 15) +
      points(body, 10) + points(wick, 10) + points(trendAlignment, 10) +
      points(levelQuality / 100, 10) + points(market, 15)
    : 0;
  if (btcScore <= WEAK_BTC_STRENGTH) {
    breakoutQualityScore = Math.min(
      breakoutQualityScore,
      WEAK_BTC_CONFIDENCE_CAP,
    );
  }

  const aboveLevel = current.close > analysis.level ? 1 : 0;
  const heldCloses = Number(analysis.heldAboveLevelCloses ?? 0);
  const confirmationScore = status === "failed"
    ? 0
    : status === "watching" || status === "pre_breakout"
    ? 0
    : Math.min(
      100,
      points(aboveLevel, 30) + points(clamp(heldCloses / 3), 30) +
        (status === "retest" ? 20 : status === "confirmed" ? 30 : 10) +
        points(volume, 10),
    );

  return {
    regimeScore,
    readinessScore: Math.min(100, readinessScore),
    breakoutQualityScore: Math.min(100, breakoutQualityScore),
    confirmationScore,
    breakoutTriggered: status === "breakout_detected" || status === "retest" ||
      status === "confirmed",
  };
}

export function analyzeLevelBreakout(
  candles: MarketCandle[],
  engineKind: BreakoutEngineKind,
  inputConfiguration: unknown,
  timeframe: string,
  context: {
    referenceLevel?: number;
    quoteVolume24h?: number;
    btcScore?: number | null;
    status?: string;
    period?: number;
  } = {},
): LevelBreakoutAnalysis {
  const configuration = resolveTimeframeScoringConfiguration(
    inputConfiguration,
    timeframe,
  );
  if (context.period) {
    configuration.donchianPeriod = Math.max(10, Math.round(context.period));
  }
  const candidate = Number.isFinite(context.referenceLevel)
    ? {
      level: Number(context.referenceLevel),
      quality: 70,
      touches: 1,
      valid: true,
    }
    : detectLevel(candles, engineKind, configuration.donchianPeriod);
  const analysis = analyze(candles, configuration, {
    referenceLevel: candidate.level,
    quoteVolume24h: context.quoteVolume24h,
  });
  const heldAboveLevelCloses =
    candles.slice(-3).filter((candle) => candle.close > candidate.level).length;
  const status = context.status ?? "watching";
  const scores = scoresFor(
    { ...analysis, level: candidate.level, heldAboveLevelCloses },
    status,
    candidate.quality,
    candidate.touches,
    context.btcScore ?? NEUTRAL_BTC_STRENGTH,
  );
  return {
    ...analysis,
    previousCandle: candles.at(-2)!,
    engineKind,
    level: candidate.level,
    levelQuality: Math.round(candidate.quality),
    levelTouches: candidate.touches,
    setupValid: candidate.valid,
    heldAboveLevelCloses,
    scores,
  };
}

export function applyBreakoutStateScores(
  analysis: LevelBreakoutAnalysis,
  status: string,
  btcScore?: number | null,
  triggeredBreakoutQuality?: number | null,
): LevelBreakoutAnalysis {
  const scores = scoresFor(
    analysis,
    status,
    analysis.levelQuality,
    analysis.levelTouches,
    btcScore ?? NEUTRAL_BTC_STRENGTH,
  );
  const isActiveJourney = status === "breakout_detected" || status === "retest" ||
    status === "confirmed";
  // Quality belongs to the candle that actually cleared the level. A retest
  // candle often no longer satisfies `priceBrokeOut`; recalculating from that
  // candle would erase the trigger quality to zero. Keep the original quality
  // for the lifetime of the active journey while confirmation remains dynamic.
  if (
    isActiveJourney && Number(triggeredBreakoutQuality ?? 0) > 0
  ) {
    scores.breakoutQualityScore = Math.round(
      Number(triggeredBreakoutQuality),
    );
  }
  return {
    ...analysis,
    scores,
  };
}
