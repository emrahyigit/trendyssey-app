/**
 * Scans the market and maintains one breakout_signals row per
 * (model, symbol, timeframe). Notifications, journey events and outcome
 * snapshots all hang off that row through database triggers, so this job is
 * the single writer for every analysis model.
 *
 * Each model is interpreted by its own algorithm:
 *   - gpt-5-6-sol-v1        → EMA/Donchian engine (_shared/indicators.ts)
 *   - double-bottom-v1/-top → chart-pattern analyzer (_shared/double-pattern.ts),
 *                             the line-for-line port of the on-device Swift code.
 *
 * Before this split every active model row was fed through the EMA engine,
 * which produced identical, EMA-derived "double pattern" signals.
 */
// deno-lint-ignore-file no-explicit-any

import { json, requireCronSecret } from "../_shared/http.ts";
import { adminClient } from "../_shared/supabase.ts";
import { includesCryptoBaseAsset } from "../_shared/asset_universe.ts";
import {
  SCAN_BATCH_SLOTS,
  SCAN_UNIVERSE_SIZE,
  scanBatch,
} from "../_shared/scan_batches.ts";
import {
  analyze,
  atr as calculateATR,
  ema as calculateEMA,
  type MarketCandle,
  parseKlines,
  resolveTimeframeScoringConfiguration,
  rsi as calculateRSI,
} from "../_shared/indicators.ts";
import {
  JOURNEY_HORIZON_CANDLES,
  nextHighWatermark,
  nextSignalState,
  successTier,
} from "../_shared/signal_lifecycle.ts";
import {
  TREND_WEIGHTS,
  type TrendScoreObservation,
  trendScoreObservation,
} from "../_shared/trend_score.ts";
import {
  analyzeLevelBreakout,
  applyBreakoutStateScores,
  type BreakoutEngineKind,
  nextLevelSignalState,
} from "../_shared/breakout-engine.ts";
import {
  analyze as analyzeDoublePattern,
  type Candle as PatternCandle,
  type Direction,
  patternScoreLayers,
} from "../_shared/double-pattern.ts";
import {
  applyDirectionalAdjustment,
  type DirectionalFactor,
  directionalFactors,
} from "../_shared/directional-factors.ts";
import {
  BTC_STRENGTH_MAX_SCORE,
  type BTCStrengthObservation,
  btcStrengthObservation,
  NEUTRAL_BTC_STRENGTH,
  type RelativeStrengthObservation,
  relativeStrengthObservation,
} from "../_shared/relative_strength.ts";
import {
  MARKET_STATE_SCORING_VERSION,
  type MarketState,
  type MarketStateObservation,
  marketStateObservation,
} from "../_shared/market-state.ts";

/**
 * Every metric that carries both a level and a close-to-close delta, as
 * [column, observation key]. Pairs are listed together so an asymmetry in the
 * schema is visible on sight.
 */
const MARKET_STATE_METRICS: Array<
  [column: string, key: keyof MarketStateObservation]
> = [
  ["seller_pressure", "sellerPressure"],
  ["buyer_pressure", "buyerPressure"],
  ["seller_efficiency", "sellerEfficiency"],
  ["buyer_efficiency", "buyerEfficiency"],
  ["downside_response", "downsideResponse"],
  ["upside_response", "upsideResponse"],
  ["buy_side_absorption", "buySideAbsorption"],
  ["sell_side_absorption", "sellSideAbsorption"],
  ["bullish_confirmation", "bullishConfirmation"],
  ["bearish_confirmation", "bearishConfirmation"],
  ["bounce_readiness", "bounceReadiness"],
  ["rollover_readiness", "rolloverReadiness"],
  ["buyer_resilience", "buyerResilience"],
  ["seller_resilience", "sellerResilience"],
];

const MARKET_STATE_SELECT = [
  "state",
  "state_since",
  "state_score",
  "previous_state_score",
  "state_score_change",
  "seller_efficiency_trend",
  "buyer_efficiency_trend",
  "seller_pressure_trend",
  "buyer_pressure_trend",
  "candle_close_time",
  "scoring_version",
  ...MARKET_STATE_METRICS.flatMap((
    [column],
  ) => [column, `${column}_change`]),
].join(",");

const supportedTimeframes = new Set(["15m", "1h", "4h", "1d"]);

const timeframeMilliseconds: Record<string, number> = {
  "15m": 900_000,
  "1h": 3_600_000,
  "4h": 14_400_000,
  "1d": 86_400_000,
};

/** Slugs interpreted by the chart-pattern analyzer instead of the EMA engine. */
const DOUBLE_PATTERN_DIRECTIONS: Record<string, Direction> = {
  "double-bottom-v1": "bullish",
  "double-top-v1": "bearish",
};

const LEVEL_BREAKOUT_ENGINES = new Set<BreakoutEngineKind>([
  "donchian",
  "horizontal_level",
  "consolidation",
]);

/**
 * 502 candles: the pattern analyzer sees the same ~500-candle window the app
 * uses on the device. The EMA engine keeps its original 302-candle input
 * (see `scanEMA`) so its indicator seeds do not shift.
 */
async function fetchClosedCandles(
  symbol: string,
  timeframe: string,
): Promise<MarketCandle[]> {
  let lastStatus = 0;
  for (let attempt = 0; attempt < 3; attempt += 1) {
    const response = await fetch(
      `https://data-api.binance.vision/api/v3/klines?symbol=${
        encodeURIComponent(symbol)
      }&interval=${timeframe}&limit=502`,
      { signal: AbortSignal.timeout(8_000) },
    );
    if (response.ok) {
      return parseKlines(await response.json()).filter((candle) =>
        candle.closeTime < Date.now()
      );
    }
    lastStatus = response.status;
    if (response.status < 500 && response.status !== 429) break;
    const retryAfterSeconds = Number(response.headers.get("retry-after") ?? 0);
    const delay = response.status === 429 && retryAfterSeconds > 0
      ? Math.min(retryAfterSeconds * 1_000, 5_000)
      : 250 * (attempt + 1);
    await new Promise((resolve) => setTimeout(resolve, delay));
  }
  throw new Error(`Binance candle request failed (${lastStatus}).`);
}

/** Last-candle volume against the 20-candle average, as a 0-100 activity score. */
function patternActivityScore(volumeRatio: number): number {
  return Math.round(Math.min(1, Math.max(0, (volumeRatio - 0.5) / 2.5)) * 100);
}

/**
 * Records the model-independent state once per symbol/timeframe. The current
 * row is product-facing; the immutable per-candle row is for validation only.
 * Re-running a candle is idempotent through both tables' conflict keys.
 */
async function persistMarketState(
  supabase: any,
  symbolID: string,
  timeframe: string,
  candles: MarketCandle[],
  quoteVolume24h: number,
): Promise<MarketStateObservation | null> {
  const { data: previous, error: previousError } = await supabase
    .from("market_state_current")
    .select(
      MARKET_STATE_SELECT,
    )
    .eq("symbol_id", symbolID)
    .eq("timeframe", timeframe)
    .maybeSingle();
  if (previousError) throw previousError;

  const isNewScoringVersion = previous?.scoring_version !==
    MARKET_STATE_SCORING_VERSION;
  // On a scoring rollout, derive the prior candle with the new rules too. This
  // keeps both classification context and every change badge apples-to-apples.
  const twoCandlesAgo = isNewScoringVersion && candles.length > 2
    ? marketStateObservation(candles.slice(0, -2), timeframe)
    : null;
  const rescoredPrior = isNewScoringVersion && candles.length > 1
    ? marketStateObservation(
      candles.slice(0, -1),
      timeframe,
      twoCandlesAgo?.state ?? null,
    )
    : null;
  const previousState = isNewScoringVersion
    ? rescoredPrior?.state
    : previous?.state as MarketState | undefined;
  const observation = marketStateObservation(candles, timeframe, previousState);
  if (!observation) return null;
  const candleClose = new Date(observation.candleCloseTime).toISOString();
  const isNewCandle = !previous?.candle_close_time ||
    new Date(previous.candle_close_time).toISOString() !== candleClose;
  const previousStateScore = isNewScoringVersion
    ? (rescoredPrior?.stateScore ?? null)
    : isNewCandle
    ? (previous?.state_score ?? null)
    : (previous?.previous_state_score ?? null);
  // Recompute against the frozen previous-candle score even when the same
  // candle is rescanned after a scoring-rule deployment. Reusing the stored
  // delta would leave a corrected state with the old state's change badge.
  const stateScoreChange = previousStateScore !== null
    ? observation.stateScore - Number(previousStateScore)
    : null;
  const closeChange = (
    current: number | null,
    previousValue: unknown,
    storedChange: unknown,
    rescoredPreviousValue: number | null | undefined,
  ) => {
    // A withheld metric (price resilience under an untested market) has no
    // delta to report, and neither does a close it cannot be compared against.
    if (current === null) return null;
    if (rescoredPreviousValue === null) return null;
    if (isNewScoringVersion) {
      return rescoredPreviousValue === undefined
        ? null
        : current - rescoredPreviousValue;
    }
    if (previousValue === undefined || previousValue === null) return null;
    if (isNewCandle) return current - Number(previousValue);
    if (storedChange === undefined || storedChange === null) return null;
    return Number(storedChange);
  };
  const componentChanges: Record<string, number | null> = {};
  const scores: Record<string, unknown> = {
    state: observation.state,
    state_score: observation.stateScore,
    previous_state_score: previousStateScore,
    state_score_change: stateScoreChange,
    // Trends are already a slope over the recent series, so a close-to-close
    // delta on top of them would describe the same movement twice.
    seller_efficiency_trend: observation.sellerEfficiencyTrend,
    buyer_efficiency_trend: observation.buyerEfficiencyTrend,
    seller_pressure_trend: observation.sellerPressureTrend,
    buyer_pressure_trend: observation.buyerPressureTrend,
    scoring_version: observation.scoringVersion,
    raw_features: observation.features,
    close_price: candles.at(-1)?.close ?? null,
    quote_volume_24h: quoteVolume24h,
  };
  for (const [column, key] of MARKET_STATE_METRICS) {
    const value = observation[key] as number | null;
    scores[column] = value;
    componentChanges[`${column}_change`] = closeChange(
      value,
      previous?.[column],
      previous?.[`${column}_change`],
      rescoredPrior?.[key] as number | null | undefined,
    );
  }
  Object.assign(scores, componentChanges);

  const stateSince = previous?.state === observation.state &&
      previous?.state_since
    ? String(previous.state_since)
    : candleClose;

  const historyResult = await supabase.from("market_state_history").upsert({
    symbol_id: symbolID,
    timeframe,
    candle_close_time: candleClose,
    ...scores,
  }, {
    onConflict: "symbol_id,timeframe,candle_close_time,scoring_version",
  });
  if (historyResult.error) throw historyResult.error;

  const currentResult = await supabase.from("market_state_current").upsert({
    symbol_id: symbolID,
    timeframe,
    state_since: stateSince,
    candle_close_time: candleClose,
    updated_at: new Date().toISOString(),
    ...scores,
  }, {
    onConflict: "symbol_id,timeframe",
  });
  if (currentResult.error) throw currentResult.error;
  return observation;
}

/** The strength-vs-BTC ingredient, shared by every model on this symbol. */
interface BTCStrengthInput {
  score: number;
  observation: BTCStrengthObservation | null;
  /** Detail of the ~24h excess-return read; null when unmeasurable. */
  relativeStrength: RelativeStrengthObservation | null;
  /**
   * The scalar the database ranks into the 0-100 percentile: excess log
   * return vs BTC. Exactly 0 for BTC itself; null only when candles could
   * not be aligned. The percentile is NOT computed here — one batch cannot
   * see the whole universe, refresh_relative_strength() can.
   */
  relativeStrengthRaw: number | null;
}

/** Evidence block explaining the relative-strength scalar. */
function relativeStrengthFacts(btc: BTCStrengthInput): Record<string, unknown> {
  return {
    excessReturn: btc.relativeStrengthRaw,
    winRate: btc.relativeStrength?.winRate ?? null,
    coinReturn: btc.relativeStrength?.coinReturn ?? null,
    btcReturn: btc.relativeStrength?.btcReturn ?? null,
    windowCandles: btc.relativeStrength?.windowCandles ?? null,
    samples: btc.relativeStrength?.samples ?? 0,
    unmeasured: btc.relativeStrengthRaw === null,
  };
}

/** Evidence block explaining the btcStrength factor, or why it is neutral. */
function btcStrengthFacts(btc: BTCStrengthInput): Record<string, unknown> {
  return {
    score: btc.score,
    maxScore: BTC_STRENGTH_MAX_SCORE,
    coinReturn: btc.observation?.coinReturn ?? null,
    btcReturn: btc.observation?.btcReturn ?? null,
    excessReturn: btc.observation?.excessReturn ?? null,
    resilience: btc.observation?.resilience ?? null,
    samples: btc.observation?.samples ?? 0,
    neutral: btc.observation === null,
  };
}

/**
 * Stable UUID for a past pattern's journey, derived from what identifies the
 * pattern. Re-deriving the same history on every scan must map each walk to the
 * same journey id, so the unique key dedups instead of duplicating.
 */
async function deterministicJourneyID(seed: string): Promise<string> {
  const digest = new Uint8Array(
    await crypto.subtle.digest("SHA-256", new TextEncoder().encode(seed)),
  );
  const hex = Array.from(
    digest.slice(0, 16),
    (byte) => byte.toString(16).padStart(2, "0"),
  ).join("");
  return `${hex.slice(0, 8)}-${hex.slice(8, 12)}-${hex.slice(12, 16)}-${
    hex.slice(16, 20)
  }-${hex.slice(20, 32)}`;
}

/**
 * Maintains the breakout_signals row for one chart-pattern model. The analyzer
 * re-derives the whole journey from candles on every run, so a missed run
 * converges instead of losing a transition; the row update is what fires the
 * journey-recorder and notification-matcher triggers.
 */
async function scanDoublePattern(
  supabase: any,
  model: any,
  symbol: any,
  timeframe: string,
  candles: MarketCandle[],
  btc: BTCStrengthInput,
): Promise<void> {
  const direction = DOUBLE_PATTERN_DIRECTIONS[model.slug];
  const dbDirection = direction === "bullish" ? "up" : "down";
  const patternCandles: PatternCandle[] = candles.map((candle) => ({
    openTime: new Date(candle.openTime),
    closeTime: new Date(candle.closeTime),
    open: candle.open,
    high: candle.high,
    low: candle.low,
    close: candle.close,
    volume: candle.volume,
  }));

  const result = analyzeDoublePattern(patternCandles, direction);
  // Relative strength is directional: strength helps a Double Bottom, while
  // weakness helps a Double Top. The old scorer rewarded strength in both.
  const directionalMarketScore = direction === "bullish"
    ? btc.score
    : BTC_STRENGTH_MAX_SCORE - btc.score;
  const factors = result.factors.length > 0
    ? [...result.factors, {
      key: "btcStrength",
      score: directionalMarketScore,
      maxScore: BTC_STRENGTH_MAX_SCORE,
    }]
    : result.factors;
  const current = candles.at(-1)!;
  const closes = candles.map((candle) => candle.close);
  const technicalRSI = calculateRSI(closes, 14);
  const technicalEMA = calculateEMA(closes, 20);
  const technicalATR = calculateATR(candles, 14);
  const candleClose = new Date(current.closeTime).toISOString();
  const status = result.phase;

  const { data: previous } = await supabase
    .from("breakout_signals")
    .select(
      "id,status,breakout_level,candle_close_time,explanation_facts,journey_id",
    )
    .eq("analysis_model_id", model.id)
    .eq("symbol_id", symbol.id)
    .eq("timeframe", timeframe)
    .eq("direction", dbDirection)
    .order("signal_time", { ascending: false })
    .limit(1)
    .maybeSingle();

  const previousFacts = previous?.explanation_facts ?? {};
  const previousStatus = String(previous?.status ?? "watching");

  // A pattern is identified by its second pivot and neckline; a new shape
  // starts a new journey, the same shape keeps extending the old one.
  const patternKey = result.pattern
    ? `${
      patternCandles[result.pattern.secondIndex].closeTime.toISOString()
    }|${result.pattern.neckline}`
    : null;
  const samePattern = patternKey !== null &&
    previousFacts.patternKey === patternKey;
  const journeyID = samePattern && previous?.journey_id
    ? String(previous.journey_id)
    : crypto.randomUUID();

  const neckline = result.pattern?.neckline ??
    Number(previous?.breakout_level ?? 0);
  const breakoutLevel = neckline > 0 ? neckline : current.close;
  const scoreLayers = patternScoreLayers(
    patternCandles,
    result,
    direction,
    directionalMarketScore,
  );
  // The legacy column mirrors the explicit quality layer for old clients.
  const confidence = scoreLayers.breakoutQualityScore;
  const risk = Math.max(0, Math.min(100, 100 - confidence));

  const stateStartedAt = status === previousStatus && samePattern
    ? String(previousFacts.stateStartedAt ?? candleClose)
    : candleClose;
  const journeyStartedAt = samePattern
    ? String(previousFacts.journeyStartedAt ?? candleClose)
    : candleClose;

  const patternName = direction === "bullish" ? "double bottom" : "double top";
  const explanation =
    `${symbol.symbol} ${timeframe} ${model.display_name}: ${patternName} ` +
    (result.pattern
      ? `neckline ${result.pattern.neckline}, depth ${
        (result.pattern.depth * 100).toFixed(1)
      }%, pivot difference ${(result.pattern.difference * 100).toFixed(2)}%. `
      : `not present. `) +
    `Scores R${scoreLayers.regimeScore}/Rd${scoreLayers.readinessScore}/Q${scoreLayers.breakoutQualityScore}/C${scoreLayers.confirmationScore}, ` +
    `volume ${result.volumeRatio.toFixed(1)}x. State: ${status}.`;

  const payload = {
    analysis_model_id: model.id,
    symbol_id: symbol.id,
    scoring_configuration_id: model.scoring_configuration_id,
    journey_id: journeyID,
    timeframe,
    direction: dbDirection,
    status,
    breakout_level: breakoutLevel,
    signal_price: current.close,
    signal_time: candleClose,
    candle_close_time: candleClose,
    is_candle_closed: true,
    breakout_confidence_score: confidence,
    regime_score: scoreLayers.regimeScore,
    readiness_score: scoreLayers.readinessScore,
    breakout_quality_score: confidence,
    confirmation_score: scoreLayers.confirmationScore,
    relative_strength_raw: btc.relativeStrengthRaw,
    relative_strength_win_rate: symbol.symbol === "BTCUSDT"
      ? 0.5
      : btc.relativeStrength?.winRate ?? null,
    breakout_triggered: scoreLayers.breakoutTriggered,
    scoring_version: scoreLayers.scoringVersion,
    false_breakout_risk: risk,
    market_activity_score: patternActivityScore(result.volumeRatio),
    volume_ratio: result.volumeRatio,
    // The app decodes these two as required on every model, so they must never
    // be null even though the pattern analyzer itself does not use them.
    estimated_volume_delta: current.takerBuyQuote -
      (current.quoteVolume - current.takerBuyQuote),
    taker_buy_ratio: current.quoteVolume > 0
      ? current.takerBuyQuote / current.quoteVolume
      : 0.5,
    atr_change_percent: null,
    rsi: technicalRSI,
    explanation,
    explanation_facts: {
      source: "binance_rest",
      market: "spot",
      model: model.slug,
      modelDisplayName: model.display_name,
      analysisModelID: model.id,
      timeframe,
      candleClosed: true,
      usesLatestClosedCandleOnly: true,
      algorithm: "double_pattern",
      patternDirection: direction,
      patternKey,
      neckline: result.pattern?.neckline ?? null,
      firstPivotPrice: result.pattern?.firstPrice ?? null,
      secondPivotPrice: result.pattern?.secondPrice ?? null,
      patternDepth: result.pattern?.depth ?? null,
      pivotDifference: result.pattern?.difference ?? null,
      // Candle open times of the shape's three anchors, so the app can mark
      // them on the chart without re-deriving the pattern.
      firstPivotOpenTime: result.pattern
        ? patternCandles[result.pattern.firstIndex].openTime.toISOString()
        : null,
      necklineOpenTime: result.pattern
        ? patternCandles[result.pattern.necklineIndex].openTime.toISOString()
        : null,
      secondPivotOpenTime: result.pattern
        ? patternCandles[result.pattern.secondIndex].openTime.toISOString()
        : null,
      stateStartedAt,
      journeyStartedAt,
      previousStatus,
      transition: `${previousStatus}->${status}`,
      volumeRatio: result.volumeRatio,
      quoteVolume24h: Number(symbol.quote_volume_24h ?? 0),
      rsi: technicalRSI,
      emaFast: technicalEMA,
      atr: technicalATR,
      btcStrength: {
        ...btcStrengthFacts(btc),
        directionalScore: directionalMarketScore,
        direction,
      },
      relativeStrength: relativeStrengthFacts(btc),
      scoreLayers,
      confidenceFactors: factors,
    },
  };

  const signal = previous?.id
    ? await supabase.from("breakout_signals").update(payload).eq(
      "id",
      previous.id,
    ).select("id").single()
    : await supabase.from("breakout_signals").insert(payload).select("id")
      .single();
  if (signal.error) throw signal.error;

  // The analyzer re-derives every journey in the window, so its historical
  // transitions are written too — silently (notifiable = false). Without this,
  // the server's history starts the day the model went live and the scenario
  // screens miss transitions the app derives on the device. The unique key
  // (signal, journey, status, close time) makes re-runs converge. Re-runs also
  // upgrade older v1 event scores to the independent v2 pattern layers.
  if (signal.data?.id && result.walks.length > 0) {
    const eventRows: Record<string, unknown>[] = [];
    for (let index = 0; index < result.walks.length; index += 1) {
      const walk = result.walks[index];
      if (walk.events.length === 0) continue;
      const walkPattern = result.patternHistory[index];
      const walkKey = `${
        patternCandles[walkPattern.secondIndex].closeTime.toISOString()
      }|${walkPattern.neckline}`;
      const isCurrent = index === result.walks.length - 1;
      const walkJourneyID = isCurrent
        ? journeyID
        : await deterministicJourneyID(
          `${model.id}|${symbol.id}|${timeframe}|${dbDirection}|${walkKey}`,
        );
      for (const event of walk.events) {
        // Re-score with only the candles that existed at the event close. Using
        // the current scan's score here would leak future candles into backtests.
        const eventIndex = patternCandles.findIndex((candle) =>
          candle.closeTime.getTime() === event.time.getTime()
        );
        const eventCandles = eventIndex >= 0
          ? patternCandles.slice(0, eventIndex + 1)
          : patternCandles;
        const eventResult = eventIndex >= 0
          ? analyzeDoublePattern(eventCandles, direction)
          : result;
        const neutralDirectionalScore = direction === "bullish"
          ? NEUTRAL_BTC_STRENGTH
          : BTC_STRENGTH_MAX_SCORE - NEUTRAL_BTC_STRENGTH;
        const eventScores = patternScoreLayers(
          eventCandles,
          eventResult,
          direction,
          neutralDirectionalScore,
        );
        const stateEventIndex = candles.findIndex((candle) =>
          candle.closeTime === event.time.getTime()
        );
        const stateEventCandles = stateEventIndex >= 0
          ? candles.slice(0, stateEventIndex + 1)
          : candles;
        const priorEventState = stateEventCandles.length > 1
          ? marketStateObservation(stateEventCandles.slice(0, -1), timeframe)
          : null;
        const eventState = marketStateObservation(
          stateEventCandles,
          timeframe,
          priorEventState?.state ?? null,
        );
        eventRows.push({
          analysis_model_id: model.id,
          breakout_signal_id: signal.data.id,
          journey_id: walkJourneyID,
          symbol_id: symbol.id,
          timeframe,
          status: event.status,
          candle_close_time: event.time.toISOString(),
          price: event.price,
          breakout_level: walkPattern.neckline,
          confidence: eventScores.breakoutQualityScore,
          false_breakout_risk: Math.max(
            0,
            100 - eventScores.breakoutQualityScore,
          ),
          volume_ratio: eventResult.volumeRatio,
          regime_score: eventScores.regimeScore,
          readiness_score: eventScores.readinessScore,
          breakout_quality_score: eventScores.breakoutQualityScore,
          confirmation_score: eventScores.confirmationScore,
          breakout_triggered: eventScores.breakoutTriggered,
          scoring_version: eventScores.scoringVersion,
          notifiable: false,
          quote_volume_24h: Number(symbol.quote_volume_24h ?? 0),
          market_state: eventState?.state ?? null,
          market_state_score: eventState?.stateScore ?? null,
          market_state_change: eventState && priorEventState
            ? eventState.stateScore - priorEventState.stateScore
            : null,
        });
      }
    }
    if (eventRows.length > 0) {
      // ignoreDuplicates keeps history immutable: once an event is written its
      // scores never change, so scenario replays see the same past every day.
      // (Without it, every scan re-scored old events against a sliding candle
      // window and past entries drifted in and out of score filters.)
      const eventsResult = await supabase.from("signal_journey_events").upsert(
        eventRows,
        {
          onConflict: "breakout_signal_id,journey_id,status,candle_close_time",
          ignoreDuplicates: true,
        },
      );
      if (eventsResult.error) {
        console.error("journey_events_backfill_failed", {
          model: model.slug,
          symbol: symbol.symbol,
          message: eventsResult.error.message,
        });
      }
    }
  }

  // The old signal_score_components audit rows were dropped in the Aug 2026
  // cleanup: nothing ever read them — the detail page explains scores from
  // explanation_facts.
}

/** Scans either the legacy EMA journey or one of the explicit level engines. */
async function scanIndicatorModel(
  supabase: any,
  model: any,
  symbol: any,
  timeframe: string,
  candles: MarketCandle[],
  btc: BTCStrengthInput,
  trend: TrendScoreObservation | null,
): Promise<void> {
  // The EMA engine has always run on 302 candles; a longer window would shift
  // its EMA/RSI seeds and subtly change scores, so the extra history fetched
  // for the pattern models is trimmed off here.
  candles = candles.slice(-302);
  const timeframeConfiguration = resolveTimeframeScoringConfiguration(
    model.configuration,
    timeframe,
  );
  const engineKind = String(model.engine_kind ?? "");
  const { data: previous } = await supabase
    .from("breakout_signals")
    .select(
      "id,status,breakout_level,candle_close_time,explanation_facts,journey_id,breakout_quality_score,trend_entry",
    )
    .eq("analysis_model_id", model.id)
    .eq("symbol_id", symbol.id)
    .eq("timeframe", timeframe)
    .eq("direction", "up")
    .order("signal_time", { ascending: false })
    .limit(1)
    .maybeSingle();
  const previousFacts = previous?.explanation_facts ?? {};
  const previousStatus = String(previous?.status ?? "watching");
  const tracksExistingLevel = previousStatus === "breakout_detected" ||
    previousStatus === "confirmed";
  const previousLevel = Number(previous?.breakout_level ?? 0);
  let triggeredBreakoutQuality = Number(previous?.breakout_quality_score ?? 0);
  // The live row may have been rescored by an older deployment while it was in
  // retest, which erased its quality. The immutable breakout event is the
  // canonical source for the trigger candle and also repairs those journeys on
  // their next scan.
  if (tracksExistingLevel && previous?.journey_id) {
    const { data: triggerEvent, error: triggerEventError } = await supabase
      .from("signal_journey_events")
      .select("breakout_quality_score")
      .eq("breakout_signal_id", previous.id)
      .eq("journey_id", previous.journey_id)
      .eq("status", "breakout_detected")
      .order("candle_close_time", { ascending: false })
      .limit(1)
      .maybeSingle();
    if (triggerEventError) throw triggerEventError;
    if (Number(triggerEvent?.breakout_quality_score ?? 0) > 0) {
      triggeredBreakoutQuality = Number(triggerEvent.breakout_quality_score);
    }
  }
  let a = engineKind === "ema_cross"
    ? analyze(candles, timeframeConfiguration, {
      referenceLevel: tracksExistingLevel && previousLevel > 0
        ? previousLevel
        : undefined,
      quoteVolume24h: Number(symbol.quote_volume_24h ?? 0),
    })
    : analyzeLevelBreakout(
      candles,
      engineKind as BreakoutEngineKind,
      timeframeConfiguration,
      timeframe,
      {
        referenceLevel: tracksExistingLevel && previousLevel > 0
          ? previousLevel
          : undefined,
        quoteVolume24h: Number(symbol.quote_volume_24h ?? 0),
        btcScore: btc.score,
        status: previousStatus,
        period: Number(timeframeConfiguration.donchianPeriod),
      },
    );
  const candleClose = new Date(a.current.closeTime).toISOString();
  const isNewCandle = !previous?.candle_close_time ||
    new Date(previous.candle_close_time).getTime() !== a.current.closeTime;
  const trackedLevel = tracksExistingLevel && previousLevel > 0
    ? previousLevel
    : a.level;
  const oldStateStartedAt = String(previousFacts.stateStartedAt ?? candleClose);
  const oldJourneyStartedAt = String(
    previousFacts.journeyStartedAt ??
      (previousStatus === "breakout_detected" || previousStatus === "confirmed"
        ? oldStateStartedAt
        : candleClose),
  );
  const journeyAge = Math.max(
    0,
    Math.floor(
      (a.current.closeTime - new Date(oldJourneyStartedAt).getTime()) /
        timeframeMilliseconds[timeframe],
    ),
  );
  // The tournament-winner journey measures from the candle that freshly
  // cleared the 55-high: its close is the entry, its ATR freezes the trail
  // width, and the high watermark ratchets the stop upward scan by scan.
  const inJourney = previousStatus === "breakout_detected" ||
    previousStatus === "confirmed";
  const previousJourneyFacts = {
    entryPrice: inJourney ? Number(previousFacts.entryPrice ?? 0) : 0,
    entryAtr: inJourney ? Number(previousFacts.entryAtr ?? 0) : 0,
    highWatermark: inJourney
      ? Number(previousFacts.highWatermark ?? previousFacts.entryPrice ?? 0)
      : 0,
  };
  const horizonCandles = JOURNEY_HORIZON_CANDLES[timeframe] ?? 288;
  const status = engineKind === "ema_cross"
    ? nextSignalState(
      previousStatus,
      trend,
      previousJourneyFacts,
      a.current,
      journeyAge,
      isNewCandle,
      horizonCandles,
    )
    : nextLevelSignalState(
      previousStatus,
      a,
      trackedLevel,
      journeyAge,
      isNewCandle,
    );
  const beginsBreakout = status === "breakout_detected" &&
    previousStatus !== "breakout_detected";
  const journeyFacts = beginsBreakout
    ? {
      entryPrice: a.current.close,
      // The freshly-broken candle's ATR; a zero ATR can never happen on a
      // candle that just cleared a 55-candle range.
      entryAtr: Number(a.atr ?? 0),
      highWatermark: a.current.close,
    }
    : previousJourneyFacts;
  const entryPrice = journeyFacts.entryPrice;
  const journeySuccessTier = engineKind === "ema_cross" &&
      (status === "confirmed" ||
        (status === "expired" && previousStatus === "confirmed"))
    ? successTier(
      a.current,
      journeyFacts,
      Number(previousFacts.successTier ?? 0),
    )
    : status === "breakout_detected"
    ? 0
    : Number(previousFacts.successTier ?? 0);
  // The current candle survived its own stop check (or just entered); only
  // now may its high raise the trail for the next scan.
  const nextWatermark = status === "breakout_detected" || status === "confirmed"
    ? (beginsBreakout
      ? journeyFacts.highWatermark
      : nextHighWatermark(journeyFacts, a.current))
    : journeyFacts.highWatermark;
  let directional: DirectionalFactor[] = [];
  if (engineKind === "ema_cross") {
    // The tournament model IS the score: confidence equals the trend score,
    // and the old EMA-crossover confidence recipe retired with its engine.
    const trendScore = trend?.score ?? 0;
    a = { ...a, confidence: trendScore, risk: Math.max(0, 100 - trendScore) };
  } else {
    a = applyBreakoutStateScores(
      a,
      status,
      btc.score,
      tracksExistingLevel ? triggeredBreakoutQuality : 0,
    );
    // Bearish deductions subtract from the quality score. An active journey
    // keeps its trigger-candle quality untouched, exactly like the base score
    // does — and the factor rows freeze with it, so the score and the rows
    // that explain it always describe the same candle.
    const qualityPinned = tracksExistingLevel && triggeredBreakoutQuality > 0 &&
      (status === "breakout_detected" || status === "confirmed");
    if (qualityPinned) {
      directional = Array.isArray(previousFacts.confidenceFactors)
        ? previousFacts.confidenceFactors
        : [];
    } else {
      directional = directionalFactors(candles);
      a.scores.breakoutQualityScore = applyDirectionalAdjustment(
        a.scores.breakoutQualityScore,
        directional,
      );
    }
    a = {
      ...a,
      confidence: a.scores.breakoutQualityScore,
      risk: Math.max(0, 100 - a.scores.breakoutQualityScore),
    };
  }
  const scoreLayers = engineKind === "ema_cross"
    ? {
      // Layers are the trend model's own components, rescaled to 0-100.
      regimeScore: trend
        ? Math.round((trend.components.regime / TREND_WEIGHTS.regime) * 100)
        : 0,
      readinessScore: trend
        ? Math.round((trend.components.breakout / TREND_WEIGHTS.breakout) * 100)
        : 0,
      breakoutQualityScore: a.confidence,
      confirmationScore: status === "confirmed"
        ? 100
        : status === "breakout_detected"
        ? 35
        : 0,
      breakoutTriggered: status === "breakout_detected" ||
        status === "confirmed",
    }
    : a.scores;
  const previousWasTerminal = previousStatus === "failed" ||
    previousStatus === "expired";
  const beginsNewJourney = previousWasTerminal && status !== "failed" &&
    status !== "expired";
  const journeyID = beginsNewJourney || !previous?.journey_id
    ? crypto.randomUUID()
    : String(previous.journey_id);
  // A+ is sticky for the life of the ACTIVE journey. The fresh 55-high candle
  // rarely coincides with a phase transition, so a candle-scoped flag almost
  // never reached signal_journey_events — the scenario page, the executor's
  // A+ gate and the A+ push filter all read journey events and silently saw
  // nothing. Carried while the journey runs; a terminal state drops it.
  const journeyIsActive = status === "breakout_detected" ||
    status === "confirmed";
  const aPlusJourney = (trend?.entrySignal ?? false) ||
    (journeyIsActive && !beginsNewJourney && Boolean(previous?.trend_entry));
  // The per-candle indicator_snapshots audit table was dropped in the Aug 2026
  // cleanup: 42k rows and counting with no reader — every value the app needs
  // already travels in explanation_facts on the signal row.
  const stateStartedAt = status === previousStatus
    ? oldStateStartedAt
    : candleClose;
  const journeyStartedAt =
    status === "breakout_detected" && previousStatus !== "breakout_detected"
      ? candleClose
      : status === "confirmed" || status === "breakout_detected"
      ? oldJourneyStartedAt
      : candleClose;
  // The tournament journey tracks the 55-candle high. It freezes on the entry
  // candle (the stored row keeps it) and only re-reads the live level when no
  // journey is running; level engines keep their own convention.
  const breakoutLevel = engineKind === "ema_cross"
    ? (inJourney && !beginsBreakout && previousLevel > 0
      ? previousLevel
      : (trend?.breakoutLevel ?? a.level))
    : (tracksExistingLevel ? trackedLevel : a.level);
  const explanation =
    `${symbol.symbol} ${timeframe} ${model.display_name}: setup ${a.setupType} ${a.setupScore}/100, breakout quality ${a.confidence}/100, false-breakout risk ${a.risk}/100. ADX ${
      a.adx.toFixed(1)
    }, +DI ${a.plusDI.toFixed(1)}, -DI ${a.minusDI.toFixed(1)}, volume ${
      a.volumeRatio.toFixed(1)
    }x. State: ${status}.`;
  const payload = {
    analysis_model_id: model.id,
    symbol_id: symbol.id,
    scoring_configuration_id: model.scoring_configuration_id,
    journey_id: journeyID,
    timeframe,
    direction: "up",
    status,
    breakout_level: breakoutLevel,
    signal_price: a.current.close,
    signal_time: candleClose,
    candle_close_time: candleClose,
    is_candle_closed: true,
    breakout_confidence_score: a.confidence,
    regime_score: scoreLayers.regimeScore,
    readiness_score: scoreLayers.readinessScore,
    breakout_quality_score: scoreLayers.breakoutQualityScore,
    confirmation_score: scoreLayers.confirmationScore,
    relative_strength_raw: btc.relativeStrengthRaw,
    relative_strength_win_rate: symbol.symbol === "BTCUSDT"
      ? 0.5
      : btc.relativeStrength?.winRate ?? null,
    breakout_triggered: scoreLayers.breakoutTriggered,
    trend_score: trend?.score ?? null,
    trend_entry: aPlusJourney,
    scoring_version: "breakout-scores-v1",
    false_breakout_risk: a.risk,
    market_activity_score: a.activity,
    volume_ratio: a.volumeRatio,
    estimated_volume_delta: a.estimatedDelta,
    taker_buy_ratio: a.takerBuyRatio,
    atr_change_percent: a.atrChange,
    rsi: a.rsi,
    explanation,
    explanation_facts: {
      source: "binance_rest",
      market: "spot",
      model: model.slug,
      modelDisplayName: model.display_name,
      engineKind,
      analysisModelID: model.id,
      timeframe,
      candleClosed: true,
      usesLatestClosedCandleOnly: true,
      stateStartedAt,
      journeyStartedAt,
      journeyAge,
      entryPrice: entryPrice > 0 ? entryPrice : null,
      entryAtr: journeyFacts.entryAtr > 0 ? journeyFacts.entryAtr : null,
      highWatermark: nextWatermark > 0 ? nextWatermark : null,
      chandelierStop: journeyFacts.entryAtr > 0 && nextWatermark > 0
        ? nextWatermark - 3 * journeyFacts.entryAtr
        : null,
      successTier: journeySuccessTier,
      previousStatus,
      transition: `${previousStatus}->${status}`,
      nearBreakout: a.nearBreakout,
      priceBrokeOut: a.priceBrokeOut,
      brokeOut: a.brokeOut,
      setupType: a.setupType,
      setupScore: a.setupScore,
      distanceToLevelAtr: a.distanceToLevelAtr,
      breakoutClearanceAtr: a.breakoutClearanceAtr,
      bodyRatio: a.bodyRatio,
      upperWickRatio: a.upperWickRatio,
      tradeRatio: a.tradeRatio,
      volumeContractionRatio: a.volumeContractionRatio,
      retestVolumeRatio: a.retestVolumeRatio,
      rangeAtrRatio: a.rangeAtrRatio,
      atr: a.atr,
      atrChangePercent: a.atrChange,
      rsi: a.rsi,
      rsiDelta3: a.rsiDelta3,
      emaFast: a.emaFast,
      emaSlow: a.emaSlow,
      emaLong: a.emaLong,
      emaFastSlope: a.emaFastSlope,
      emaSlowSlope: a.emaSlowSlope,
      emaCrossAge: a.emaCrossAge,
      emaRetest: a.emaRetest,
      emaRetestAge: a.emaRetestAge,
      adx: a.adx,
      adxDelta3: a.adxDelta3,
      plusDI: a.plusDI,
      minusDI: a.minusDI,
      bollingerBandWidthChangePercent: a.bollingerBandWidthChange,
      quoteVolume24h: Number(symbol.quote_volume_24h ?? 0),
      btcStrength: btcStrengthFacts(btc),
      relativeStrength: relativeStrengthFacts(btc),
      // The tournament-winning trend model (_shared/trend_score.ts): the
      // component list sums to trend_score exactly, so the detail page can
      // explain it the way confidenceFactors explain the unified score.
      trendScore: trend
        ? {
          score: trend.score,
          entrySignal: trend.entrySignal,
          components: trend.components,
          breakoutLevel: trend.breakoutLevel,
          clearanceAtr: trend.clearanceAtr,
          freshBreakout: trend.freshBreakout,
          regimeAligned: trend.regimeAligned,
          momentumExcess: trend.momentumExcess,
          chandelierStop: trend.chandelierStop,
        }
        : null,
      scoreLayers: {
        ...scoreLayers,
        scoringVersion: "breakout-scores-v1",
      },
      scoreComponents: a.scoreComponents,
      // The score's own ingredients — this list sums to
      // breakout_confidence_score, which is what the detail page explains.
      // The tournament model lists its four components; level engines list
      // the directional evidence that adjusted quality.
      confidenceFactors: engineKind === "ema_cross"
        ? (trend
          ? [
            {
              key: "trend.breakout",
              score: trend.components.breakout,
              maxScore: TREND_WEIGHTS.breakout,
            },
            {
              key: "trend.regime",
              score: trend.components.regime,
              maxScore: TREND_WEIGHTS.regime,
            },
            {
              key: "trend.momentum",
              score: trend.components.momentum,
              maxScore: TREND_WEIGHTS.momentum,
            },
            {
              key: "trend.health",
              score: trend.components.health,
              maxScore: TREND_WEIGHTS.health,
            },
          ]
          : [])
        : directional.map(({ key, score, maxScore }) => ({
          key,
          score,
          maxScore,
        })),
    },
  };
  const signal = previous?.id
    ? await supabase.from("breakout_signals").update(payload).eq(
      "id",
      previous.id,
    ).select("id").single()
    : await supabase.from("breakout_signals").insert(payload).select("id")
      .single();
  if (signal.error) throw signal.error;
  // Score components live on in explanation_facts.scoreComponents; the
  // signal_score_components audit table was dropped in the Aug 2026 cleanup.
}

Deno.serve(async (req) => {
  const unauthorized = requireCronSecret(req);
  if (unauthorized) return unauthorized;
  const supabase = adminClient();
  try {
    const body = await req.json().catch(() => ({}));
    const timeframe = body.timeframe ?? "15m";
    if (!supportedTimeframes.has(timeframe)) {
      return json({
        error: {
          code: "INVALID_TIMEFRAME",
          message: "Desteklenmeyen zaman dilimi.",
        },
      }, 400);
    }
    const { data: modelRows, error: modelError } = await supabase
      .from("analysis_models")
      .select("id,slug,display_name,engine_kind,scoring_configuration_id")
      .eq("is_active", true)
      .order("sort_order");
    if (modelError) throw modelError;
    if (!modelRows?.length) throw new Error("No active analysis model found.");
    const configIDs = modelRows.map((model: any) =>
      model.scoring_configuration_id
    );
    const { data: configurationRows, error: configurationError } =
      await supabase
        .from("scoring_configurations")
        .select("id,configuration")
        .in("id", configIDs);
    if (configurationError) throw configurationError;
    const configurations = new Map(
      (configurationRows ?? []).map((
        configuration: any,
      ) => [configuration.id, configuration.configuration]),
    );
    const models = modelRows.map((model: any) => ({
      ...model,
      configuration: configurations.get(model.scoring_configuration_id),
    }));
    if (models.some((model: any) => !model.configuration)) {
      throw new Error("An active analysis model has no scoring configuration.");
    }
    for (const model of models) {
      const engineKind = String(model.engine_kind ?? "");
      const supported = engineKind === "ema_cross" ||
        engineKind === "double_pattern" ||
        LEVEL_BREAKOUT_ENGINES.has(engineKind as BreakoutEngineKind);
      if (!supported) {
        throw new Error(
          `Unsupported engine_kind '${engineKind}' on model '${model.slug}'.`,
        );
      }
      if (
        engineKind === "double_pattern" &&
        !DOUBLE_PATTERN_DIRECTIONS[model.slug]
      ) {
        throw new Error(
          `Double-pattern direction is not declared for '${model.slug}'.`,
        );
      }
    }
    const { data: symbols, error: symbolError } = await supabase
      .from("symbols")
      .select(
        "id,symbol,current_price,price_change_percent_24h,quote_volume_24h",
      )
      .eq("is_enabled", true)
      .eq("quote_asset", "USDT")
      .order("quote_volume_24h", { ascending: false })
      .limit(600);
    if (symbolError) throw symbolError;
    let scanned = 0;
    let signals = 0;
    const sampleErrors: string[] = [];
    // Only the 100 highest-volume pairs are analyzed at all; everything below
    // that line is out of the universe and the app reports it as not having
    // enough volume to analyze.
    const universe = (symbols ?? [])
      .filter((symbol: any) =>
        includesCryptoBaseAsset(String(symbol.symbol).replace(/USDT$/, ""))
      )
      .slice(0, SCAN_UNIVERSE_SIZE);
    // At every candle close the crons fire all four slots in parallel, so the
    // whole universe is scanned within the same minute. A run without a slot
    // (manual invocation) walks the full universe by itself.
    let batchSlot: number | null = null;
    let candidates: any[] = universe;
    if (Number.isInteger(body.batchSlot)) {
      batchSlot = Math.min(
        SCAN_BATCH_SLOTS - 1,
        Math.max(0, Number(body.batchSlot)),
      );
      candidates = scanBatch(universe, batchSlot);
    }
    // One BTC series per run feeds every symbol's strength-vs-BTC factor. If
    // the fetch fails, every coin scores the neutral midpoint rather than the
    // whole scan failing over one ingredient.
    let btcCandles: MarketCandle[] = [];
    try {
      btcCandles = await fetchClosedCandles("BTCUSDT", timeframe);
    } catch (error) {
      console.error("btc_candles_failed", {
        timeframe,
        message: error instanceof Error ? error.message : String(error),
      });
    }
    for (let offset = 0; offset < candidates.length; offset += 8) {
      const batch = candidates.slice(offset, offset + 8);
      const results = await Promise.all(batch.map(async (symbol: any) => {
        try {
          const candles = await fetchClosedCandles(symbol.symbol, timeframe);
          // The pattern analyzer works from ~30 candles; only the EMA engine
          // needs deep history. Gating per model keeps recently listed coins
          // covered on the timeframes where 250 candles simply do not exist yet.
          if (candles.length < 30) return 0;
          // BTC is its own benchmark, so it scores the neutral midpoint.
          const observation = symbol.symbol === "BTCUSDT"
            ? null
            : btcStrengthObservation(candles, btcCandles);
          const relativeStrength = symbol.symbol === "BTCUSDT"
            ? null
            : relativeStrengthObservation(candles, btcCandles, timeframe);
          const btc: BTCStrengthInput = {
            score: observation?.score ?? NEUTRAL_BTC_STRENGTH,
            observation,
            relativeStrength,
            // BTC moves one-to-one with itself, so its scalar is exactly 0.
            relativeStrengthRaw: symbol.symbol === "BTCUSDT"
              ? 0
              : relativeStrength?.excessReturn ?? null,
          };
          // Model-independent market structure; computed once per symbol.
          const trend = trendScoreObservation(candles, btcCandles, {
            isBTC: symbol.symbol === "BTCUSDT",
          });
          // The market state is not owned by any breakout model. Calculate
          // and persist it exactly once for this coin/timeframe.
          try {
            await persistMarketState(
              supabase,
              symbol.id,
              timeframe,
              candles,
              Number(symbol.quote_volume_24h ?? 0),
            );
          } catch (error) {
            const message = error instanceof Error
              ? error.message
              : String(error);
            if (sampleErrors.length < 3) {
              sampleErrors.push(`market-state/${symbol.symbol}: ${message}`);
            }
            console.error("market_state_failed", {
              symbol: symbol.symbol,
              timeframe,
              message,
            });
          }
          let completedModels = 0;
          for (const model of models) {
            try {
              if (model.engine_kind === "double_pattern") {
                await scanDoublePattern(
                  supabase,
                  model,
                  symbol,
                  timeframe,
                  candles,
                  btc,
                );
              } else if (
                model.engine_kind === "ema_cross" ||
                LEVEL_BREAKOUT_ENGINES.has(model.engine_kind)
              ) {
                if (candles.length < 250) continue;
                await scanIndicatorModel(
                  supabase,
                  model,
                  symbol,
                  timeframe,
                  candles,
                  btc,
                  trend,
                );
              } else {
                throw new Error(
                  `Unsupported engine_kind '${model.engine_kind}'.`,
                );
              }
              completedModels += 1;
            } catch (error) {
              const message = error instanceof Error
                ? error.message
                : JSON.stringify(error);
              if (sampleErrors.length < 3) {
                sampleErrors.push(`${model.slug}/${symbol.symbol}: ${message}`);
              }
              console.error("scan_model_symbol_failed", {
                model: model.slug,
                symbol: symbol.symbol,
                message,
              });
            }
          }
          if (completedModels > 0) {
            await supabase.from("symbols").update({
              current_price: candles.at(-1)?.close,
              last_scanned_at: new Date().toISOString(),
            }).eq("id", symbol.id);
          }
          return completedModels;
        } catch (error) {
          const message = error instanceof Error
            ? error.message
            : String(error);
          if (sampleErrors.length < 3) {
            sampleErrors.push(`${symbol.symbol}: ${message}`);
          }
          console.error("scan_symbol_failed", {
            symbol: symbol.symbol,
            message,
          });
          return 0;
        }
      }));
      scanned += results.filter((count) => count > 0).length;
      signals += results.reduce((total, count) => total + count, 0);
    }
    // Every batch just wrote its coins' relative-strength scalars; rank the
    // freshest scalar per symbol into the 0-100 percentile the app displays.
    // Parallel batch slots each call this — the last one leaves the final
    // ranking, and re-running it is free.
    const refresh = await supabase.rpc("refresh_relative_strength", {
      p_timeframe: timeframe,
    });
    if (refresh.error) {
      console.error("relative_strength_refresh_failed", {
        timeframe,
        message: refresh.error.message,
      });
    }
    return json({
      data: {
        market: "spot",
        timeframe,
        models: models.map((model: any) => ({
          slug: model.slug,
          displayName: model.display_name,
        })),
        universe: universe.length,
        batchSize: candidates.length,
        batchSlot,
        scanned,
        signals,
        sampleErrors,
        generatedAt: new Date().toISOString(),
      },
    });
  } catch (error) {
    return json({
      error: {
        code: "SCAN_FAILED",
        message: error instanceof Error ? error.message : String(error),
      },
    }, 500);
  }
});
