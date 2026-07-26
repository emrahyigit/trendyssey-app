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
  ROTATING_BATCH_SLOTS,
  ROTATING_UNIVERSE_SIZE,
  rotatingBatch,
  rotatingSlotForUTCMinute,
} from "../_shared/scan_batches.ts";
import {
  analyze,
  applySignalState,
  type MarketCandle,
  parseKlines,
  resolveTimeframeScoringConfiguration,
} from "../_shared/indicators.ts";
import { nextSignalState } from "../_shared/signal_lifecycle.ts";
import {
  analyze as analyzeDoublePattern,
  type Candle as PatternCandle,
  type Direction,
} from "../_shared/double-pattern.ts";

const supportedTimeframes = new Set(["15m", "30m", "1h", "2h", "4h", "6h", "1d"]);

const timeframeMilliseconds: Record<string, number> = {
  "15m": 900_000,
  "30m": 1_800_000,
  "1h": 3_600_000,
  "2h": 7_200_000,
  "4h": 14_400_000,
  "6h": 21_600_000,
  "1d": 86_400_000,
};

/** Slugs interpreted by the chart-pattern analyzer instead of the EMA engine. */
const DOUBLE_PATTERN_DIRECTIONS: Record<string, Direction> = {
  "double-bottom-v1": "bullish",
  "double-top-v1": "bearish",
};

/**
 * The whole enabled universe is covered by two lanes. The fast lane is the
 * existing candle-close-aligned crons over the highest-volume pairs, keeping
 * push latency where it was. Sweep runs (`{"sweep": true}`) rotate through
 * everything below the fast lane in fixed batches: the slot advances with
 * wall-clock time at each timeframe's sweep cadence, so a full rotation always
 * completes within one candle period and a missed run self-heals on the next.
 */
const FAST_LANE_SIZE = 50;
const SWEEP_BATCH_SIZE = 45;
/** Must match the sweep crons' firing cadence, or slots repeat instead of rotating. */
const SWEEP_CADENCE_MINUTES: Record<string, number> = {
  "15m": 1, "30m": 2, "1h": 3, "2h": 6, "4h": 12, "6h": 18, "1d": 30,
};

function sweepSlot(timeframe: string, poolSize: number, explicit?: unknown): number {
  const slots = Math.max(1, Math.ceil(poolSize / SWEEP_BATCH_SIZE));
  if (Number.isInteger(explicit)) return Math.min(slots - 1, Math.max(0, Number(explicit)));
  const cadence = SWEEP_CADENCE_MINUTES[timeframe] ?? 6;
  return Math.floor(Date.now() / 60_000 / cadence) % slots;
}

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

/**
 * The candle store is the single input the app and the server both read. The
 * scan writes the tail of exactly the candles it analyzed, so the store can
 * never lag behind a signal it produced; sync-candles sweeps wider and deeper
 * on its own schedule.
 */
const STORE_TAIL_CANDLES = 3;

async function ingestCandleTail(
  supabase: any,
  symbolID: string,
  timeframe: string,
  candles: MarketCandle[],
): Promise<void> {
  const tail = candles.slice(-STORE_TAIL_CANDLES).map((candle) => ({
    symbol_id: symbolID,
    timeframe,
    open_time: new Date(candle.openTime).toISOString(),
    close_time: new Date(candle.closeTime).toISOString(),
    open: candle.open,
    high: candle.high,
    low: candle.low,
    close: candle.close,
    volume: candle.volume,
    quote_volume: candle.quoteVolume,
    trade_count: candle.trades,
    taker_buy_base_volume: candle.takerBuyBase,
    taker_buy_quote_volume: candle.takerBuyQuote,
  }));
  if (tail.length === 0) return;
  const result = await supabase.from("candles").upsert(tail, {
    onConflict: "symbol_id,timeframe,open_time",
    ignoreDuplicates: true,
  });
  if (result.error) {
    console.error("candle_ingest_failed", { symbolID, timeframe, message: result.error.message });
  }
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
  const current = candles.at(-1)!;
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
  const confidence = result.confidence;
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
    `Confidence ${confidence}/100, volume ${result.volumeRatio.toFixed(1)}x. State: ${status}.`;

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
    false_breakout_risk: risk,
    market_activity_score: patternActivityScore(result.volumeRatio),
    volume_ratio: result.volumeRatio,
    // The app decodes these two as required on every model, so they must never
    // be null even though the pattern analyzer itself does not use them.
    estimated_volume_delta: current.takerBuyQuote - (current.quoteVolume - current.takerBuyQuote),
    taker_buy_ratio: current.quoteVolume > 0 ? current.takerBuyQuote / current.quoteVolume : 0.5,
    atr_change_percent: null,
    rsi: null,
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
      confidenceFactors: result.factors,
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
  // (signal, journey, status, close time) makes re-runs converge, and the
  // live transition recorded by the row-update trigger wins on conflict.
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
          confidence,
          false_breakout_risk: risk,
          volume_ratio: result.volumeRatio,
          notifiable: false,
        });
      }
    }
    if (eventRows.length > 0) {
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

  if (status !== "watching" && signal.data?.id && result.factors.length > 0) {
    const rows = result.factors.map((factor) => ({
      breakout_signal_id: signal.data.id,
      component_key: `confidence.${factor.key}`,
      component_name: factor.key,
      raw_value: factor.score,
      normalized_value: factor.maxScore > 0 ? Number((factor.score / factor.maxScore).toFixed(4)) : 0,
      score_contribution: factor.score,
      maximum_score: factor.maxScore,
      explanation: `Double-pattern factor "${factor.key}", scored ${factor.score}/${factor.maxScore} on the device-parity scale.`,
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

/** The original EMA/Donchian path, unchanged. */
async function scanEMA(
  supabase: any,
  model: any,
  symbol: any,
  timeframe: string,
  candles: MarketCandle[],
): Promise<void> {
  // The EMA engine has always run on 302 candles; a longer window would shift
  // its EMA/RSI seeds and subtly change scores, so the extra history fetched
  // for the pattern models is trimmed off here.
  candles = candles.slice(-302);
  const timeframeConfiguration = resolveTimeframeScoringConfiguration(model.configuration, timeframe);
  const { data: previous } = await supabase
    .from("breakout_signals")
    .select("id,status,breakout_level,candle_close_time,explanation_facts,journey_id")
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
  let a = analyze(candles, timeframeConfiguration, {
    referenceLevel: tracksExistingLevel && previousLevel > 0 ? previousLevel : undefined,
    quoteVolume24h: Number(symbol.quote_volume_24h ?? 0),
  });
  const candleClose = new Date(a.current.closeTime).toISOString();
  const isNewCandle = !previous?.candle_close_time || new Date(previous.candle_close_time).getTime() !== a.current.closeTime;
  const trackedLevel = previousLevel > 0 ? previousLevel : a.level;
  const oldStateStartedAt = String(previousFacts.stateStartedAt ?? candleClose);
  const oldJourneyStartedAt = String(
    previousFacts.journeyStartedAt ??
      (previousStatus === "breakout_detected" || previousStatus === "confirmed" || previousStatus === "retest" ? oldStateStartedAt : candleClose),
  );
  const journeyAge = Math.max(0, Math.floor((a.current.closeTime - new Date(oldJourneyStartedAt).getTime()) / timeframeMilliseconds[timeframe]));
  const status = nextSignalState(previousStatus, a, trackedLevel, journeyAge, isNewCandle);
  a = applySignalState(a, status);
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
  const breakoutLevel = tracksExistingLevel ? trackedLevel : a.donchianLevel;
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
      scoreComponents: a.scoreComponents,
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
      .select("id,slug,display_name,scoring_configuration_id")
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
    const eligible = (symbols ?? [])
      .filter((symbol: any) => includesCryptoBaseAsset(String(symbol.symbol).replace(/USDT$/, "")));
    const sweep = body.sweep === true;
    let batchSlot: number | null = null;
    let candidates: any[];
    if (sweep) {
      // Rotate through everything below the fast lane.
      const pool = eligible.slice(timeframe === "15m" ? ROTATING_UNIVERSE_SIZE : FAST_LANE_SIZE);
      batchSlot = sweepSlot(timeframe, pool.length, body.batchSlot);
      candidates = pool.slice(batchSlot * SWEEP_BATCH_SIZE, (batchSlot + 1) * SWEEP_BATCH_SIZE);
    } else if (timeframe === "15m") {
      const universe = eligible.slice(0, ROTATING_UNIVERSE_SIZE);
      batchSlot = Number.isInteger(body.batchSlot)
        ? Math.min(ROTATING_BATCH_SLOTS - 1, Math.max(0, Number(body.batchSlot)))
        : rotatingSlotForUTCMinute(new Date().getUTCMinutes());
      candidates = rotatingBatch(universe, batchSlot);
    } else {
      candidates = eligible.slice(0, FAST_LANE_SIZE);
    }
    for (let offset = 0; offset < candidates.length; offset += 8) {
      const batch = candidates.slice(offset, offset + 8);
      const results = await Promise.all(batch.map(async (symbol: any) => {
        try {
          const candles = await fetchClosedCandles(symbol.symbol, timeframe);
          if (candles.length < 250) return 0;
          await ingestCandleTail(supabase, symbol.id, timeframe, candles);
          let completedModels = 0;
          for (const model of models) {
            try {
              if (DOUBLE_PATTERN_DIRECTIONS[model.slug]) {
                await scanDoublePattern(supabase, model, symbol, timeframe, candles);
              } else {
                await scanEMA(supabase, model, symbol, timeframe, candles);
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
        universe: eligible.length,
        sweep,
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
