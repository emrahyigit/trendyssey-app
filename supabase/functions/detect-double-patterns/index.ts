/**
 * Detects Double Bottom / Double Top journeys and records their transitions in
 * `signal_journey_events`, so the existing notification pipeline can alert on
 * them the same way it already does for the EMA model.
 *
 * IMPORTANT — this defaults to a dry run.
 *
 * It was written against the columns the iOS app reads, which is a partial view
 * of the schema: NOT NULL columns the app never selects, defaults and the
 * `journey_id` lifecycle could not be inspected. So the first run must be a dry
 * run: it does every read and every computation, reports exactly what it would
 * insert, and writes nothing. Check that output against your table before
 * enabling writes.
 *
 *   Dry run (safe):   POST { }                       or ?dryRun=true
 *   Real run:         POST { "dryRun": false }
 *
 * Deploy:
 *   supabase functions deploy detect-double-patterns
 * Schedule (every 5 minutes) with pg_cron, or call it from whatever already
 * schedules the EMA detection job.
 */

import { analyze, type Candle, type Direction, type JourneyStatus } from "../_shared/double-pattern.ts";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
// Provided to deployed functions automatically; never hard-code a key here.
const SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

const BINANCE_KLINES = "https://data-api.binance.vision/api/v3/klines";

/** Must match JourneyModel.serverSlug in the iOS app. */
const MODELS: Array<{ slug: string; direction: Direction }> = [
  { slug: "double-bottom-v1", direction: "bullish" },
  { slug: "double-top-v1", direction: "bearish" },
];

/** Timeframes the app offers. */
const TIMEFRAMES = ["15m", "30m", "1h", "2h", "4h", "6h", "1d"];

/** Candles per symbol. Detection needs at least 17; more history means more context. */
const CANDLE_LIMIT = 300;
/** Highest-volume symbols scanned per run. */
const SYMBOL_LIMIT = 100;
/** Symbols fetched from Binance at once. */
const BATCH_SIZE = 8;
/**
 * How far back a transition may be and still be recorded, as a multiple of the
 * timeframe's own candle length.
 *
 * This is deliberately tight. Every row written here becomes a notification, and
 * a notification is a push: recording a transition that closed hours ago sends an
 * alert about a move the user has already missed, timestamped now. Two candles
 * covers a missed run without ever reaching back into stale history.
 */
const REPLAY_CANDLES = 2;

const TIMEFRAME_MINUTES: Record<string, number> = {
  "15m": 15, "30m": 30, "1h": 60, "2h": 120, "4h": 240, "6h": 360, "1d": 1440,
};

function replayWindowMs(timeframe: string): number {
  return (TIMEFRAME_MINUTES[timeframe] ?? 15) * 60 * 1000 * REPLAY_CANDLES;
}

interface PlannedEvent {
  symbolId: string;
  symbol: string;
  modelSlug: string;
  timeframe: string;
  status: JourneyStatus;
  candleCloseTime: string;
  price: number;
  confidence: number;
  volumeRatio: number;
}

Deno.serve(async (request) => {
  try {
    const url = new URL(request.url);
    let body: Record<string, unknown> = {};
    if (request.method === "POST") {
      body = await request.json().catch(() => ({}));
    }
    // Writing is opt-in: an accidental call must not mutate anything.
    const dryRun = body.dryRun === false || url.searchParams.get("dryRun") === "false" ? false : true;
    const timeframes = Array.isArray(body.timeframes) ? body.timeframes as string[] : TIMEFRAMES;

    const models = await loadModels();
    const missing = MODELS.filter((m) => !models[m.slug]);
    if (missing.length > 0) {
      return json({
        error: "analysis_models rows are missing",
        missingSlugs: missing.map((m) => m.slug),
        hint: "Apply supabase/migrations/20260725_add_double_pattern_models.sql first.",
      }, 412);
    }

    const symbols = await loadSymbols();
    if (symbols.length === 0) {
      return json({ error: "no active symbols returned from the symbols table" }, 500);
    }

    const planned: PlannedEvent[] = [];
    const skipped: string[] = [];
    let staleSkipped = 0;

    for (const timeframe of timeframes) {
      const since = Date.now() - replayWindowMs(timeframe);
      for (let start = 0; start < symbols.length; start += BATCH_SIZE) {
        const batch = symbols.slice(start, start + BATCH_SIZE);
        const candlesBySymbol = await Promise.all(
          batch.map(async (row) => ({
            row,
            candles: await fetchCandles(row.symbol, timeframe).catch(() => null),
          })),
        );

        for (const { row, candles } of candlesBySymbol) {
          if (!candles || candles.length === 0) {
            skipped.push(`${row.symbol} ${timeframe}`);
            continue;
          }
          for (const model of MODELS) {
            const result = analyze(candles, model.direction);
            for (const event of result.events) {
              if (event.time.getTime() < since) {
                staleSkipped += 1;
                continue;
              }
              planned.push({
                symbolId: row.id,
                symbol: row.symbol,
                modelSlug: model.slug,
                timeframe,
                status: event.status,
                candleCloseTime: event.time.toISOString(),
                price: event.price,
                confidence: result.confidence,
                volumeRatio: result.volumeRatio,
              });
            }
          }
        }
      }
    }

    if (dryRun) {
      return json({
        dryRun: true,
        wrote: 0,
        wouldInsert: planned.length,
        symbolsScanned: symbols.length,
        timeframes,
        skipped: skipped.slice(0, 20),
        staleSkipped,
        sample: planned.slice(0, 10),
        note:
          "Nothing was written. Compare `sample` against your signal_journey_events columns, then call again with {\"dryRun\": false}.",
      });
    }

    const inserted = await insertEvents(planned, models);
    return json({
      dryRun: false,
      wrote: inserted,
      considered: planned.length,
      symbolsScanned: symbols.length,
      timeframes,
      skipped: skipped.slice(0, 20),
    });
  } catch (error) {
    return json({ error: String(error) }, 500);
  }
});

// MARK: - Supabase reads and writes

function serviceHeaders(): HeadersInit {
  return {
    apikey: SERVICE_ROLE_KEY,
    Authorization: `Bearer ${SERVICE_ROLE_KEY}`,
    "Content-Type": "application/json",
  };
}

async function loadModels(): Promise<Record<string, string>> {
  const response = await fetch(
    `${SUPABASE_URL}/rest/v1/analysis_models?select=id,slug&is_active=eq.true`,
    { headers: serviceHeaders() },
  );
  if (!response.ok) throw new Error(`analysis_models: ${response.status} ${await response.text()}`);
  const rows = await response.json() as Array<{ id: string; slug: string }>;
  return Object.fromEntries(rows.map((row) => [row.slug, row.id]));
}

async function loadSymbols(): Promise<Array<{ id: string; symbol: string }>> {
  const response = await fetch(
    `${SUPABASE_URL}/rest/v1/symbols?select=id,symbol,quote_volume_24h&order=quote_volume_24h.desc&limit=${SYMBOL_LIMIT}`,
    { headers: serviceHeaders() },
  );
  if (!response.ok) throw new Error(`symbols: ${response.status} ${await response.text()}`);
  return await response.json();
}

/**
 * Inserts the transitions that are not already recorded. `on_conflict` needs a
 * unique constraint covering (symbol_id, analysis_model_id, timeframe, status,
 * candle_close_time); without one, re-running would duplicate rows, so the
 * insert is deliberately split per row and existing rows are filtered first.
 */
async function insertEvents(
  planned: PlannedEvent[],
  models: Record<string, string>,
): Promise<number> {
  if (planned.length === 0) return 0;
  const fresh = await filterExisting(planned, models);
  if (fresh.length === 0) return 0;

  const payload = fresh.map((event) => ({
    symbol_id: event.symbolId,
    analysis_model_id: models[event.modelSlug],
    timeframe: event.timeframe,
    status: event.status,
    candle_close_time: event.candleCloseTime,
    price: event.price,
    confidence: event.confidence,
    volume_ratio: event.volumeRatio,
    // The EMA pipeline also records a false-breakout risk. These models score
    // confidence only, so risk is reported as its complement rather than being
    // invented; adjust if your scoring configuration defines it differently.
    false_breakout_risk: Math.max(0, 100 - event.confidence),
  }));

  const response = await fetch(`${SUPABASE_URL}/rest/v1/signal_journey_events`, {
    method: "POST",
    headers: { ...serviceHeaders(), Prefer: "return=minimal" },
    body: JSON.stringify(payload),
  });
  if (!response.ok) {
    throw new Error(`signal_journey_events insert: ${response.status} ${await response.text()}`);
  }
  return payload.length;
}

/** Drops transitions already stored, so repeated runs are idempotent. */
async function filterExisting(
  planned: PlannedEvent[],
  models: Record<string, string>,
): Promise<PlannedEvent[]> {
  const earliest = planned
    .map((event) => event.candleCloseTime)
    .sort()[0];
  const modelIds = Object.values(models).filter(Boolean);
  const response = await fetch(
    `${SUPABASE_URL}/rest/v1/signal_journey_events` +
      `?select=symbol_id,analysis_model_id,timeframe,status,candle_close_time` +
      `&candle_close_time=gte.${encodeURIComponent(earliest)}` +
      `&analysis_model_id=in.(${modelIds.join(",")})`,
    { headers: serviceHeaders() },
  );
  if (!response.ok) {
    throw new Error(`signal_journey_events read: ${response.status} ${await response.text()}`);
  }
  const rows = await response.json() as Array<Record<string, string>>;
  const seen = new Set(
    rows.map((row) =>
      [row.symbol_id, row.analysis_model_id, row.timeframe, row.status, row.candle_close_time].join("|")
    ),
  );
  return planned.filter((event) =>
    !seen.has(
      [
        event.symbolId,
        models[event.modelSlug],
        event.timeframe,
        event.status,
        event.candleCloseTime,
      ].join("|"),
    )
  );
}

// MARK: - Candles

async function fetchCandles(symbol: string, interval: string): Promise<Candle[]> {
  const url = `${BINANCE_KLINES}?symbol=${symbol.toUpperCase()}&interval=${interval}&limit=${CANDLE_LIMIT}`;
  const response = await fetch(url);
  if (!response.ok) throw new Error(`binance ${symbol} ${interval}: ${response.status}`);
  const rows = await response.json() as unknown[][];
  const now = Date.now();

  return rows
    .map((row) => ({
      openTime: new Date(Number(row[0])),
      closeTime: new Date(Number(row[6])),
      open: Number(row[1]),
      high: Number(row[2]),
      low: Number(row[3]),
      close: Number(row[4]),
      volume: Number(row[5]),
    }))
    // Closed candles only. An unclosed candle lets a phase flip back and forth
    // inside the same bar, which would send an alert and then contradict it.
    .filter((candle) => candle.closeTime.getTime() < now);
}

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body, null, 2), {
    status,
    headers: { "Content-Type": "application/json" },
  });
}
