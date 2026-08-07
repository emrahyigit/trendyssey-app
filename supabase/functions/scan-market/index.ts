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
  applySignalState,
  atr as calculateATR,
  ema as calculateEMA,
  emaConfidenceFactors,
  type MarketCandle,
  parseKlines,
  resolveTimeframeScoringConfiguration,
  rsi as calculateRSI,
} from "../_shared/indicators.ts";
import { nextSignalState } from "../_shared/signal_lifecycle.ts";
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
} from "../_shared/relative_strength.ts";

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
async function fetchClosedCandles(symbol: string, timeframe: string): Promise<MarketCandle[]> {
  let lastStatus = 0;
  for (let attempt = 0; attempt < 3; attempt += 1) {
    const response = await fetch(
      `https://data-api.binance.vision/api/v3/klines?symbol=${encodeURIComponent(symbol)}&interval=${timeframe}&limit=502`,
      { signal: AbortSignal.timeout(8_000) },
    );
    if (response.ok) {
      return parseKlines(await response.json()).filter((candle) => candle.closeTime < Date.now());
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

/** The strength-vs-BTC ingredient, shared by every model on this symbol. */
interface BTCStrengthInput {
  score: number;
  observation: BTCStrengthObservation | null;
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
  const digest = new Uint8Array(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(seed)));
  const hex = Array.from(digest.slice(0, 16), (byte) => byte.toString(16).padStart(2, "0")).join("");
  return `${hex.slice(0, 8)}-${hex.slice(8, 12)}-${hex.slice(12, 16)}-${hex.slice(16, 20)}-${hex.slice(20, 32)}`;
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
    .select("id,status,breakout_level,candle_close_time,explanation_facts,journey_id")
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
    ? `${patternCandles[result.pattern.secondIndex].closeTime.toISOString()}|${result.pattern.neckline}`
    : null;
  const samePattern = patternKey !== null && previousFacts.patternKey === patternKey;
  const journeyID = samePattern && previous?.journey_id ? String(previous.journey_id) : crypto.randomUUID();

  const neckline = result.pattern?.neckline ?? Number(previous?.breakout_level ?? 0);
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
      ? `neckline ${result.pattern.neckline}, depth ${(result.pattern.depth * 100).toFixed(1)}%, pivot difference ${(result.pattern.difference * 100).toFixed(2)}%. `
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
    breakout_triggered: scoreLayers.breakoutTriggered,
    scoring_version: scoreLayers.scoringVersion,
    false_breakout_risk: risk,
    market_activity_score: patternActivityScore(result.volumeRatio),
    volume_ratio: result.volumeRatio,
    // The app decodes these two as required on every model, so they must never
    // be null even though the pattern analyzer itself does not use them.
    estimated_volume_delta: current.takerBuyQuote - (current.quoteVolume - current.takerBuyQuote),
    taker_buy_ratio: current.quoteVolume > 0 ? current.takerBuyQuote / current.quoteVolume : 0.5,
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
      firstPivotOpenTime: result.pattern ? patternCandles[result.pattern.firstIndex].openTime.toISOString() : null,
      necklineOpenTime: result.pattern ? patternCandles[result.pattern.necklineIndex].openTime.toISOString() : null,
      secondPivotOpenTime: result.pattern ? patternCandles[result.pattern.secondIndex].openTime.toISOString() : null,
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
      scoreLayers,
      confidenceFactors: factors,
    },
  };

  const signal = previous?.id
    ? await supabase.from("breakout_signals").update(payload).eq("id", previous.id).select("id").single()
    : await supabase.from("breakout_signals").insert(payload).select("id").single();
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
      const walkKey = `${patternCandles[walkPattern.secondIndex].closeTime.toISOString()}|${walkPattern.neckline}`;
      const isCurrent = index === result.walks.length - 1;
      const walkJourneyID = isCurrent
        ? journeyID
        : await deterministicJourneyID(`${model.id}|${symbol.id}|${timeframe}|${dbDirection}|${walkKey}`);
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
          false_breakout_risk: Math.max(0, 100 - eventScores.breakoutQualityScore),
          volume_ratio: eventResult.volumeRatio,
          regime_score: eventScores.regimeScore,
          readiness_score: eventScores.readinessScore,
          breakout_quality_score: eventScores.breakoutQualityScore,
          confirmation_score: eventScores.confirmationScore,
          breakout_triggered: eventScores.breakoutTriggered,
          scoring_version: eventScores.scoringVersion,
          notifiable: false,
          quote_volume_24h: Number(symbol.quote_volume_24h ?? 0),
        });
      }
    }
    if (eventRows.length > 0) {
      // ignoreDuplicates keeps history immutable: once an event is written its
      // scores never change, so scenario replays see the same past every day.
      // (Without it, every scan re-scored old events against a sliding candle
      // window and past entries drifted in and out of score filters.)
      const eventsResult = await supabase.from("signal_journey_events").upsert(eventRows, {
        onConflict: "breakout_signal_id,journey_id,status,candle_close_time",
        ignoreDuplicates: true,
      });
      if (eventsResult.error) {
        console.error("journey_events_backfill_failed", {
          model: model.slug,
          symbol: symbol.symbol,
          message: eventsResult.error.message,
        });
      }
    }
  }

  if (status !== "watching" && signal.data?.id) {
    const rows = [
      ["regime", scoreLayers.regimeScore],
      ["readiness", scoreLayers.readinessScore],
      ["quality", scoreLayers.breakoutQualityScore],
      ["confirmation", scoreLayers.confirmationScore],
    ].map(([key, value]) => ({
      breakout_signal_id: signal.data.id,
      component_key: `layer.${key}`,
      component_name: key,
      raw_value: value,
      normalized_value: Number(value) / 100,
      score_contribution: value,
      maximum_score: 100,
      explanation: `Independent Double-pattern ${key} layer, scored ${value}/100.`,
    }));
    const componentResult = await supabase.from("signal_score_components").upsert(rows, {
      onConflict: "breakout_signal_id,component_key",
    });
    if (componentResult.error) {
      console.error("score_components_failed", {
        model: model.slug,
        symbol: symbol.symbol,
        message: componentResult.error.message,
      });
    }
  }
}

/** Scans either the legacy EMA journey or one of the explicit level engines. */
async function scanIndicatorModel(
  supabase: any,
  model: any,
  symbol: any,
  timeframe: string,
  candles: MarketCandle[],
  btc: BTCStrengthInput,
): Promise<void> {
  // The EMA engine has always run on 302 candles; a longer window would shift
  // its EMA/RSI seeds and subtly change scores, so the extra history fetched
  // for the pattern models is trimmed off here.
  candles = candles.slice(-302);
  const timeframeConfiguration = resolveTimeframeScoringConfiguration(model.configuration, timeframe);
  const engineKind = String(model.engine_kind ?? "");
  const { data: previous } = await supabase
    .from("breakout_signals")
    .select("id,status,breakout_level,candle_close_time,explanation_facts,journey_id,breakout_quality_score")
    .eq("analysis_model_id", model.id)
    .eq("symbol_id", symbol.id)
    .eq("timeframe", timeframe)
    .eq("direction", "up")
    .order("signal_time", { ascending: false })
    .limit(1)
    .maybeSingle();
  const previousFacts = previous?.explanation_facts ?? {};
  const previousStatus = String(previous?.status ?? "watching");
  const tracksExistingLevel = previousStatus === "breakout_detected" || previousStatus === "confirmed" || previousStatus === "retest";
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
      referenceLevel: tracksExistingLevel && previousLevel > 0 ? previousLevel : undefined,
      quoteVolume24h: Number(symbol.quote_volume_24h ?? 0),
    })
    : analyzeLevelBreakout(
      candles,
      engineKind as BreakoutEngineKind,
      timeframeConfiguration,
      timeframe,
      {
        referenceLevel: tracksExistingLevel && previousLevel > 0 ? previousLevel : undefined,
        quoteVolume24h: Number(symbol.quote_volume_24h ?? 0),
        btcScore: btc.score,
        status: previousStatus,
        period: Number(timeframeConfiguration.donchianPeriod),
      },
    );
  const candleClose = new Date(a.current.closeTime).toISOString();
  const isNewCandle = !previous?.candle_close_time || new Date(previous.candle_close_time).getTime() !== a.current.closeTime;
  const trackedLevel = tracksExistingLevel && previousLevel > 0 ? previousLevel : a.level;
  const oldStateStartedAt = String(previousFacts.stateStartedAt ?? candleClose);
  const oldJourneyStartedAt = String(
    previousFacts.journeyStartedAt ??
      (previousStatus === "breakout_detected" || previousStatus === "confirmed" || previousStatus === "retest" ? oldStateStartedAt : candleClose),
  );
  const journeyAge = Math.max(0, Math.floor((a.current.closeTime - new Date(oldJourneyStartedAt).getTime()) / timeframeMilliseconds[timeframe]));
  const status = engineKind === "ema_cross"
    ? nextSignalState(previousStatus, a, trackedLevel, journeyAge, isNewCandle)
    : nextLevelSignalState(previousStatus, a, trackedLevel, journeyAge, isNewCandle);
  let directional: DirectionalFactor[] = [];
  if (engineKind === "ema_cross") {
    a = applySignalState(a, status, btc.score);
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
      (status === "breakout_detected" || status === "retest" || status === "confirmed");
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
      regimeScore: a.setupScore,
      readinessScore: a.setupScore,
      breakoutQualityScore: a.confidence,
      confirmationScore: status === "confirmed" ? 100 : status === "retest" ? 60 : status === "breakout_detected" ? 35 : 0,
      breakoutTriggered: status === "breakout_detected" || status === "retest" || status === "confirmed",
    }
    : a.scores;
  const previousWasTerminal = previousStatus === "failed" || previousStatus === "expired";
  const beginsNewJourney = previousWasTerminal && status !== "failed" && status !== "expired";
  const journeyID = beginsNewJourney || !previous?.journey_id ? crypto.randomUUID() : String(previous.journey_id);
  const snapshot = await supabase.from("indicator_snapshots").upsert({
    analysis_model_id: model.id,
    symbol_id: symbol.id,
    timeframe,
    candle_open_time: new Date(a.current.openTime).toISOString(),
    candle_close_time: candleClose,
    close_price: a.current.close,
    volume: a.current.volume,
    quote_volume: a.current.quoteVolume,
    volume_ratio: a.volumeRatio,
    volume_contraction_ratio: a.volumeContractionRatio,
    retest_volume_ratio: a.retestVolumeRatio,
    rsi: a.rsi,
    rsi_delta_3: a.rsiDelta3,
    atr: a.atr,
    atr_change_percent: a.atrChange,
    ema_fast: a.emaFast,
    ema_slow: a.emaSlow,
    ema_long: a.emaLong,
    ema_fast_slope: a.emaFastSlope,
    ema_slow_slope: a.emaSlowSlope,
    ema_cross_age: a.emaCrossAge,
    ema_retest: a.emaRetest,
    ema_retest_age: a.emaRetestAge,
    adx: a.adx,
    adx_delta_3: a.adxDelta3,
    plus_di: a.plusDI,
    minus_di: a.minusDI,
    setup_type: a.setupType,
    setup_score: a.setupScore,
    breakout_qualified: a.brokeOut,
    bollinger_band_width: a.bollingerBandWidth,
    donchian_high: a.donchianLevel,
    estimated_volume_delta: a.estimatedDelta,
    taker_buy_ratio: a.takerBuyRatio,
  }, {
    onConflict: "analysis_model_id,symbol_id,timeframe,candle_close_time",
  });
  if (snapshot.error) throw snapshot.error;
  const stateStartedAt = status === previousStatus ? oldStateStartedAt : candleClose;
  const journeyStartedAt = status === "breakout_detected" && previousStatus !== "breakout_detected"
    ? candleClose
    : status === "confirmed" || status === "retest" || status === "breakout_detected"
    ? oldJourneyStartedAt
    : candleClose;
  const breakoutLevel = tracksExistingLevel ? trackedLevel : a.level;
  const explanation =
    `${symbol.symbol} ${timeframe} ${model.display_name}: setup ${a.setupType} ${a.setupScore}/100, breakout quality ${a.confidence}/100, false-breakout risk ${a.risk}/100. ADX ${a.adx.toFixed(1)}, +DI ${a.plusDI.toFixed(1)}, -DI ${a.minusDI.toFixed(1)}, volume ${a.volumeRatio.toFixed(1)}x. State: ${status}.`;
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
    breakout_triggered: scoreLayers.breakoutTriggered,
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
      scoreLayers: {
        ...scoreLayers,
        scoringVersion: "breakout-scores-v1",
      },
      scoreComponents: a.scoreComponents,
      // The unified score's own ingredients — this list sums to
      // breakout_confidence_score, which is what the detail page explains.
      // Level engines list the directional evidence that adjusted quality.
      confidenceFactors: engineKind === "ema_cross"
        ? emaConfidenceFactors(a, status, btc.score)
        : directional.map(({ key, score, maxScore }) => ({ key, score, maxScore })),
    },
  };
  const signal = previous?.id
    ? await supabase.from("breakout_signals").update(payload).eq("id", previous.id).select("id").single()
    : await supabase.from("breakout_signals").insert(payload).select("id").single();
  if (signal.error) throw signal.error;
  if (status !== "watching" && signal.data?.id) {
    const rows = a.scoreComponents.map((item: any) => ({
      breakout_signal_id: signal.data.id,
      component_key: item.key,
      component_name: item.name,
      raw_value: Number.isFinite(item.rawValue) ? item.rawValue : null,
      normalized_value: item.normalizedValue,
      score_contribution: item.contribution,
      maximum_score: item.maximumScore,
      explanation: item.explanation,
    }));
    const componentResult = await supabase.from("signal_score_components").upsert(rows, {
      onConflict: "breakout_signal_id,component_key",
    });
    if (componentResult.error) {
      console.error("score_components_failed", {
        model: model.slug,
        symbol: symbol.symbol,
        message: componentResult.error.message,
      });
    }
  }
}

Deno.serve(async (req) => {
  const unauthorized = requireCronSecret(req);
  if (unauthorized) return unauthorized;
  const supabase = adminClient();
  try {
    const body = await req.json().catch(() => ({}));
    const timeframe = body.timeframe ?? "15m";
    if (!supportedTimeframes.has(timeframe)) {
      return json({ error: { code: "INVALID_TIMEFRAME", message: "Desteklenmeyen zaman dilimi." } }, 400);
    }
    const { data: modelRows, error: modelError } = await supabase
      .from("analysis_models")
      .select("id,slug,display_name,engine_kind,scoring_configuration_id")
      .eq("is_active", true)
      .order("sort_order");
    if (modelError) throw modelError;
    if (!modelRows?.length) throw new Error("No active analysis model found.");
    const configIDs = modelRows.map((model: any) => model.scoring_configuration_id);
    const { data: configurationRows, error: configurationError } = await supabase
      .from("scoring_configurations")
      .select("id,configuration")
      .in("id", configIDs);
    if (configurationError) throw configurationError;
    const configurations = new Map((configurationRows ?? []).map((configuration: any) => [configuration.id, configuration.configuration]));
    const models = modelRows.map((model: any) => ({
      ...model,
      configuration: configurations.get(model.scoring_configuration_id),
    }));
    if (models.some((model: any) => !model.configuration)) {
      throw new Error("An active analysis model has no scoring configuration.");
    }
    for (const model of models) {
      const engineKind = String(model.engine_kind ?? "");
      const supported = engineKind === "ema_cross" || engineKind === "double_pattern" ||
        LEVEL_BREAKOUT_ENGINES.has(engineKind as BreakoutEngineKind);
      if (!supported) {
        throw new Error(`Unsupported engine_kind '${engineKind}' on model '${model.slug}'.`);
      }
      if (engineKind === "double_pattern" && !DOUBLE_PATTERN_DIRECTIONS[model.slug]) {
        throw new Error(`Double-pattern direction is not declared for '${model.slug}'.`);
      }
    }
    const { data: symbols, error: symbolError } = await supabase
      .from("symbols")
      .select("id,symbol,current_price,price_change_percent_24h,quote_volume_24h")
      .eq("is_enabled", true)
      .eq("quote_asset", "USDT")
      .order("quote_volume_24h", { ascending: false })
      .limit(600);
    if (symbolError) throw symbolError;
    let scanned = 0;
    let signals = 0;
    // Only the 100 highest-volume pairs are analyzed at all; everything below
    // that line is out of the universe and the app reports it as not having
    // enough volume to analyze.
    const universe = (symbols ?? [])
      .filter((symbol: any) => includesCryptoBaseAsset(String(symbol.symbol).replace(/USDT$/, "")))
      .slice(0, SCAN_UNIVERSE_SIZE);
    // At every candle close the crons fire all four slots in parallel, so the
    // whole universe is scanned within the same minute. A run without a slot
    // (manual invocation) walks the full universe by itself.
    let batchSlot: number | null = null;
    let candidates: any[] = universe;
    if (Number.isInteger(body.batchSlot)) {
      batchSlot = Math.min(SCAN_BATCH_SLOTS - 1, Math.max(0, Number(body.batchSlot)));
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
          const btc: BTCStrengthInput = {
            score: observation?.score ?? NEUTRAL_BTC_STRENGTH,
            observation,
          };
          let completedModels = 0;
          for (const model of models) {
            try {
              if (model.engine_kind === "double_pattern") {
                await scanDoublePattern(supabase, model, symbol, timeframe, candles, btc);
              } else if (model.engine_kind === "ema_cross" || LEVEL_BREAKOUT_ENGINES.has(model.engine_kind)) {
                if (candles.length < 250) continue;
                await scanIndicatorModel(supabase, model, symbol, timeframe, candles, btc);
              } else {
                throw new Error(`Unsupported engine_kind '${model.engine_kind}'.`);
              }
              completedModels += 1;
            } catch (error) {
              console.error("scan_model_symbol_failed", {
                model: model.slug,
                symbol: symbol.symbol,
                message: error instanceof Error ? error.message : String(error),
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
          console.error("scan_symbol_failed", {
            symbol: symbol.symbol,
            message: error instanceof Error ? error.message : String(error),
          });
          return 0;
        }
      }));
      scanned += results.filter((count) => count > 0).length;
      signals += results.reduce((total, count) => total + count, 0);
    }
    return json({
      data: {
        market: "spot",
        timeframe,
        models: models.map((model: any) => ({ slug: model.slug, displayName: model.display_name })),
        universe: universe.length,
        batchSize: candidates.length,
        batchSlot,
        scanned,
        signals,
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
