/**
 * Double Bottom / Double Top detection, ported line for line from the iOS app
 * (Trendyssey/Services/DoublePatternAnalyzer.swift).
 *
 * The two implementations must stay in step: the app shows a phase and a
 * confidence score computed on the device, and the backend raises the alert for
 * the same journey. If the rules drift apart, a user gets a push that disagrees
 * with what the app shows when they open it.
 *
 * No dependencies, no I/O — feed it closed candles, get journey transitions back.
 */

export type Direction = "bullish" | "bearish";

/** Mirrors the app's SignalStatus, using the values stored in signal_journey_events. */
export type JourneyStatus =
  | "watching"
  | "pre_breakout"
  | "breakout_detected"
  | "confirmed"
  | "retest"
  | "failed"
  | "expired";

export interface Candle {
  openTime: Date;
  closeTime: Date;
  open: number;
  high: number;
  low: number;
  close: number;
  volume: number;
}

export interface JourneyEvent {
  status: JourneyStatus;
  time: Date;
  price: number;
}

export interface DoublePattern {
  firstIndex: number;
  secondIndex: number;
  necklineIndex: number;
  firstPrice: number;
  secondPrice: number;
  neckline: number;
  /** Price difference between the two pivots, as a fraction. */
  difference: number;
  /** Neckline distance from the pivot average, as a fraction. */
  depth: number;
}

export interface JourneyWalk {
  events: JourneyEvent[];
  phase: JourneyStatus;
  breakoutIndex: number | null;
  retestHeld: boolean;
}

export interface ConfidenceFactor {
  key: string;
  score: number;
  maxScore: number;
}

/** Candles required on each side of a pivot before it counts as one. */
export const PIVOT_WINDOW = 3;
/** Candle distance allowed between the two pivots. */
export const MIN_SEPARATION = 5;
export const MAX_SEPARATION = 60;
/** Price difference allowed between the two pivots. */
export const LEVEL_TOLERANCE = 0.02;
/** Minimum neckline distance from the pivots; flatter shapes are noise. */
export const MIN_DEPTH = 0.015;
/** Clearance a close needs beyond the neckline to count as a break. */
export const BREAKOUT_BUFFER = 0.001;
/** Distance from the neckline that counts as approaching it. */
export const APPROACH_BAND = 0.015;
/** Move back through a level that counts as a real violation, not noise. */
export const INVALIDATION_BAND = 0.005;
/** Candles searched before the first pivot for the trend being reversed. */
export const CONTEXT_WINDOW = 60;

/** The level that has to hold for the pattern to stay valid. */
export function patternBase(pattern: DoublePattern, direction: Direction): number {
  return direction === "bullish"
    ? Math.min(pattern.firstPrice, pattern.secondPrice)
    : Math.max(pattern.firstPrice, pattern.secondPrice);
}

/**
 * Indices whose low (bullish) or high (bearish) is the extreme of the
 * surrounding PIVOT_WINDOW candles on both sides.
 */
export function pivotIndices(candles: Candle[], direction: Direction): number[] {
  if (candles.length <= PIVOT_WINDOW * 2) return [];
  const indices: number[] = [];
  for (let index = PIVOT_WINDOW; index < candles.length - PIVOT_WINDOW; index++) {
    let isPivot = true;
    for (let other = index - PIVOT_WINDOW; other <= index + PIVOT_WINDOW; other++) {
      if (other === index) continue;
      const holds = direction === "bullish"
        ? candles[other].low >= candles[index].low
        : candles[other].high <= candles[index].high;
      if (!holds) {
        isPivot = false;
        break;
      }
    }
    if (isPivot) indices.push(index);
  }
  return indices;
}

function candidatePatterns(candles: Candle[], direction: Direction): DoublePattern[] {
  const pivots = pivotIndices(candles, direction);
  if (pivots.length < 2) return [];
  const found: DoublePattern[] = [];

  for (let a = 0; a < pivots.length; a++) {
    const first = pivots[a];
    for (let b = a + 1; b < pivots.length; b++) {
      const second = pivots[b];
      const separation = second - first;
      if (separation < MIN_SEPARATION || separation > MAX_SEPARATION) continue;

      const firstPrice = direction === "bullish" ? candles[first].low : candles[first].high;
      const secondPrice = direction === "bullish" ? candles[second].low : candles[second].high;
      if (firstPrice <= 0) continue;
      const difference = Math.abs(secondPrice - firstPrice) / firstPrice;
      if (difference > LEVEL_TOLERANCE) continue;

      const between: number[] = [];
      for (let i = first + 1; i < second; i++) between.push(i);
      if (between.length === 0) continue;

      let necklineIndex = between[0];
      for (const i of between) {
        const better = direction === "bullish"
          ? candles[i].high > candles[necklineIndex].high
          : candles[i].low < candles[necklineIndex].low;
        if (better) necklineIndex = i;
      }
      const neckline = direction === "bullish"
        ? candles[necklineIndex].high
        : candles[necklineIndex].low;

      // The pivots must be the extremes of the shape: nothing between them may
      // run past the level they define.
      const extremeBetween = direction === "bullish"
        ? Math.min(...between.map((i) => candles[i].low))
        : Math.max(...between.map((i) => candles[i].high));
      const holdsShape = direction === "bullish"
        ? extremeBetween >= Math.min(firstPrice, secondPrice) * (1 - INVALIDATION_BAND)
        : extremeBetween <= Math.max(firstPrice, secondPrice) * (1 + INVALIDATION_BAND);
      if (!holdsShape) continue;

      const average = (firstPrice + secondPrice) / 2;
      if (average <= 0) continue;
      const depth = direction === "bullish"
        ? (neckline - average) / average
        : (average - neckline) / average;
      if (depth < MIN_DEPTH) continue;

      found.push({
        firstIndex: first,
        secondIndex: second,
        necklineIndex,
        firstPrice,
        secondPrice,
        neckline,
        difference,
        depth,
      });
    }
  }
  return found;
}

/**
 * Every pattern in the candle history, oldest first and non-overlapping.
 * Overlapping candidates collapse to the most symmetric one so a single shape is
 * not counted several times.
 */
export function patterns(candles: Candle[], direction: Direction): DoublePattern[] {
  const candidates = candidatePatterns(candles, direction).sort((x, y) =>
    x.secondIndex !== y.secondIndex
      ? x.secondIndex - y.secondIndex
      : x.difference - y.difference
  );
  const accepted: DoublePattern[] = [];
  for (const candidate of candidates) {
    const previous = accepted[accepted.length - 1];
    if (!previous || candidate.firstIndex >= previous.secondIndex) accepted.push(candidate);
  }
  return accepted;
}

/**
 * Walks the candles after the second pivot is confirmed. `endIndex` bounds the
 * walk so an older shape cannot keep reporting transitions once a newer one has
 * formed.
 */
export function journey(
  candles: Candle[],
  pattern: DoublePattern,
  direction: Direction,
  endIndex: number,
): JourneyWalk {
  let state: JourneyStatus = "watching";
  const events: JourneyEvent[] = [];
  let breakoutIndex: number | null = null;
  let retestHeld = false;
  let closesBackThrough = 0;
  // A neckline break usually starts right at the neckline, so the candle after it
  // almost always wicks back to that level. Only once price has closed clear of
  // the neckline does a return to it count as a retest.
  let clearedByMargin = false;

  const neckline = pattern.neckline;
  const base = patternBase(pattern, direction);
  const start = pattern.secondIndex + PIVOT_WINDOW;
  if (start >= endIndex) {
    return { events, phase: "watching", breakoutIndex: null, retestHeld: false };
  }

  for (let index = start; index < endIndex; index++) {
    const candle = candles[index];
    const clearedNeckline = direction === "bullish"
      ? candle.close > neckline * (1 + BREAKOUT_BUFFER)
      : candle.close < neckline * (1 - BREAKOUT_BUFFER);
    const closedBackThrough = direction === "bullish"
      ? candle.close < neckline * (1 - INVALIDATION_BAND)
      : candle.close > neckline * (1 + INVALIDATION_BAND);
    const touchedNeckline = direction === "bullish"
      ? candle.low <= neckline * 1.002
      : candle.high >= neckline * 0.998;
    const lostPattern = direction === "bullish"
      ? candle.close < base * (1 - INVALIDATION_BAND)
      : candle.close > base * (1 + INVALIDATION_BAND);
    let newState: JourneyStatus = state;

    if (state === "watching" || state === "pre_breakout") {
      if (clearedNeckline) {
        newState = "breakout_detected";
        breakoutIndex = index;
      } else if (lostPattern) {
        // Price left the shape before it could resolve: this pattern is done.
        newState = "failed";
      } else {
        const distance = direction === "bullish"
          ? (neckline - candle.close) / neckline
          : (candle.close - neckline) / neckline;
        newState = distance >= 0 && distance <= APPROACH_BAND ? "pre_breakout" : "watching";
      }
    } else if (state === "breakout_detected" || state === "retest" || state === "confirmed") {
      if (closedBackThrough) {
        closesBackThrough += 1;
        if (closesBackThrough >= 2) {
          newState = "failed";
          breakoutIndex = null;
        } else if (state !== "retest") {
          newState = "retest";
        }
      } else {
        closesBackThrough = 0;
        if (state === "retest" && clearedNeckline) {
          retestHeld = true;
          newState = "confirmed";
        } else if (state !== "retest" && clearedByMargin && touchedNeckline) {
          // A pullback to the neckline is a retest whether it arrives before or
          // after the move was confirmed.
          newState = "retest";
        } else if (state === "breakout_detected" && breakoutIndex !== null && index - breakoutIndex >= 3) {
          let held = true;
          for (let other = index - 2; other <= index; other++) {
            const stillBeyond = direction === "bullish"
              ? candles[other].close > neckline
              : candles[other].close < neckline;
            if (!stillBeyond) {
              held = false;
              break;
            }
          }
          if (held) newState = "confirmed";
        }
      }
    }

    if (newState !== state) {
      state = newState;
      events.push({ status: state, time: candle.closeTime, price: candle.close });
      // A broken pattern is not re-entered; the next analysis picks up whichever
      // shape forms next.
      if (state === "failed") break;
    }

    const clearanceReached = direction === "bullish"
      ? candle.close > neckline * (1 + INVALIDATION_BAND)
      : candle.close < neckline * (1 - INVALIDATION_BAND);
    if (clearanceReached) clearedByMargin = true;
  }

  return { events, phase: state, breakoutIndex, retestHeld };
}

/** One walk per pattern, each bounded by where the next one begins. */
export function journeys(candles: Candle[], direction: Direction): JourneyWalk[] {
  const history = patterns(candles, direction);
  return history.map((pattern, index) => {
    const nextStart = index + 1 < history.length
      ? history[index + 1].secondIndex + PIVOT_WINDOW
      : candles.length;
    return journey(candles, pattern, direction, Math.min(nextStart, candles.length));
  });
}

export interface AnalysisResult {
  pattern: DoublePattern | null;
  /** Every non-overlapping pattern in the window, oldest first. */
  patternHistory: DoublePattern[];
  /** One walk per pattern, aligned index-by-index with `patternHistory`. */
  walks: JourneyWalk[];
  events: JourneyEvent[];
  phase: JourneyStatus;
  confidence: number;
  factors: ConfidenceFactor[];
  volumeRatio: number;
}

/** Volume of the last closed candle against the 20-candle average. */
export function latestVolumeRatio(candles: Candle[]): number {
  if (candles.length < 2) return 0;
  const history = candles.slice(Math.max(0, candles.length - 21), candles.length - 1);
  const average = history.reduce((sum, c) => sum + c.volume, 0) / Math.max(history.length, 1);
  if (average <= 0) return 0;
  return candles[candles.length - 1].volume / average;
}

function volumeScore(ratio: number, maxScore = 20): number {
  if (ratio >= 2) return maxScore;
  if (ratio >= 1.5) return Math.trunc(maxScore * 0.75);
  if (ratio >= 1) return Math.trunc(maxScore * 0.55);
  if (ratio >= 0.7) return Math.trunc(maxScore * 0.3);
  return Math.trunc(maxScore * 0.1);
}

/**
 * The same seven ingredients the app scores, normalized to 0-100. The
 * higher-timeframe confluence factor is left to the caller: it needs a second
 * candle series, and the backend already fetches those per timeframe.
 */
export function confidenceFactors(
  candles: Candle[],
  pattern: DoublePattern,
  direction: Direction,
  phase: JourneyStatus,
  breakoutIndex: number | null,
  retestHeld: boolean,
  volumeRatio: number,
): ConfidenceFactor[] {
  const lastIndex = candles.length - 1;
  const factors: ConfidenceFactor[] = [];

  // 1. Pivot symmetry (max 20)
  const symmetry = pattern.difference < 0.005
    ? 20
    : pattern.difference < 0.01
    ? 15
    : pattern.difference < 0.015
    ? 11
    : 7;
  factors.push({ key: "symmetry", score: symmetry, maxScore: 20 });

  // 2. Pattern depth (max 15)
  const depth = pattern.depth >= 0.06 ? 15 : pattern.depth >= 0.035 ? 12 : pattern.depth >= 0.02 ? 8 : 5;
  factors.push({ key: "depth", score: depth, maxScore: 15 });

  // 3. Breakout freshness (max 15)
  let breakout = 0;
  if (breakoutIndex !== null && phase !== "failed" && phase !== "watching" && phase !== "pre_breakout") {
    const age = lastIndex - breakoutIndex;
    breakout = age <= 2 ? 15 : age <= 6 ? 12 : age <= 15 ? 8 : 4;
  } else if (phase === "pre_breakout") {
    breakout = 5;
  }
  factors.push({ key: "breakout", score: breakout, maxScore: 15 });

  // 4. Volume support (max 20)
  factors.push({ key: "volume", score: volumeScore(volumeRatio), maxScore: 20 });

  // 5. Retest confirmation (max 15)
  const retest = retestHeld
    ? 15
    : phase === "retest"
    ? 8
    : phase === "breakout_detected" || phase === "confirmed"
    ? 4
    : 0;
  factors.push({ key: "retest", score: retest, maxScore: 15 });

  // 6. The trend being reversed (max 10)
  const contextStart = Math.max(0, pattern.firstIndex - CONTEXT_WINDOW);
  let priorMove = 0;
  if (contextStart < pattern.firstIndex) {
    const window = candles.slice(contextStart, pattern.firstIndex);
    if (direction === "bullish") {
      const peak = Math.max(...window.map((c) => c.high));
      priorMove = peak > 0 ? (peak - pattern.firstPrice) / peak : 0;
    } else {
      const trough = Math.min(...window.map((c) => c.low));
      priorMove = trough > 0 ? (pattern.firstPrice - trough) / trough : 0;
    }
  }
  const context = priorMove >= 0.1 ? 10 : priorMove >= 0.05 ? 7 : priorMove >= 0.02 ? 4 : 1;
  factors.push({ key: "context", score: context, maxScore: 10 });

  return factors;
}

/** Normalizes scored ingredients onto a 0-100 scale. */
export function confidence(factors: ConfidenceFactor[]): number {
  const achieved = factors.reduce((sum, f) => sum + f.score, 0);
  const achievable = factors.reduce((sum, f) => sum + f.maxScore, 0);
  return Math.min(100, Math.max(0, Math.round((achieved * 100) / Math.max(achievable, 1))));
}

/**
 * Entry point: run one direction over a symbol's closed candles. `candles` must
 * be closed candles only, oldest first — an unclosed candle would let a phase
 * flip back and forth within the same bar.
 */
export function analyze(candles: Candle[], direction: Direction): AnalysisResult {
  const volumeRatio = latestVolumeRatio(candles);
  if (candles.length < MIN_SEPARATION + PIVOT_WINDOW * 2 + 5) {
    return { pattern: null, patternHistory: [], walks: [], events: [], phase: "watching", confidence: 0, factors: [], volumeRatio };
  }
  const history = patterns(candles, direction);
  const pattern = history[history.length - 1] ?? null;
  if (!pattern) {
    return { pattern: null, patternHistory: [], walks: [], events: [], phase: "watching", confidence: 0, factors: [], volumeRatio };
  }

  const walks = journeys(candles, direction);
  const current = walks[walks.length - 1];
  const factors = confidenceFactors(
    candles,
    pattern,
    direction,
    current.phase,
    current.breakoutIndex,
    current.retestHeld,
    volumeRatio,
  );

  return {
    pattern,
    patternHistory: history,
    walks,
    events: walks.flatMap((walk) => walk.events),
    phase: current.phase,
    confidence: confidence(factors),
    factors,
    volumeRatio,
  };
}
