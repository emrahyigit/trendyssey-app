/**
 * Phase 0: reconciles journeys instead of detecting deltas.
 *
 * The job this replaces asked "what changed since I last looked" and wrote that.
 * A missed run lost the transition permanently, while the app — deriving the same
 * journey from candles — still showed it. That asymmetry is what made a coin
 * appear in the app and be absent from every server-backed screen.
 *
 * This one re-derives a whole window from the stored candles every run and
 * upserts. Running it once, ten times, or missing it entirely and running it
 * later all converge on the same rows, so a missed run costs nothing.
 *
 * Two rules make that safe:
 *
 *   1. Conflicts are ignored, not merged. A transition already recorded keeps the
 *      row it was first written with, including its `notifiable` value.
 *   2. Only transitions from the last few candles are notifiable. Everything the
 *      reconciliation reaches further back is recorded silently, so rebuilding
 *      history never turns into a burst of alerts about moves already missed.
 *
 * Reads candles from the database, not from Binance: that is the whole point —
 * the server and the app must derive from the same input.
 *
 * Deploy:
 *   supabase functions deploy derive-journeys
 * Schedule it a few minutes after sync-candles for the same timeframe.
 *
 * Replaces `detect-double-patterns`, which can be removed once this is running.
 */

import { analyze, type Candle, type Direction } from "../_shared/double-pattern.ts";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

/** Must match JourneyModel.serverSlug in the iOS app. */
const MODELS: Array<{ slug: string; direction: Direction }> = [
  { slug: "double-bottom-v1", direction: "bullish" },
  { slug: "double-top-v1", direction: "bearish" },
];

const TIMEFRAMES = ["15m", "30m", "1h", "2h", "4h", "6h", "1d"];

/** Candles read per symbol. The window the run reconciles. */
const WINDOW = 300;
/** Highest-volume pairs reconciled. */
const SYMBOL_LIMIT = 200;
const CONCURRENCY = 20;

/**
 * A transition may raise a push only if its candle closed within this many
 * candle-lengths. Everything older is recorded with notifiable = false.
 */
const NOTIFIABLE_CANDLES = 2;

const TIMEFRAME_MINUTES: Record<string, number> = {
  "15m": 15, "30m": 30, "1h": 60, "2h": 120, "4h": 240, "6h": 360, "1d": 1440,
};

interface PlannedEvent {
  symbol_id: string;
  analysis_model_id: string;
  timeframe: string;
  status: string;
  candle_close_time: string;
  price: number;
  confidence: number;
  volume_ratio: number;
  false_breakout_risk: number;
  notifiable: boolean;
}

Deno.serve(async (request) => {
  try {
    const body = request.method === "POST"
      ? await request.json().catch(() => ({}) as Record<string, unknown>)
      : {};
    const dryRun = body.dryRun === false ? false : true;
    const timeframes = Array.isArray(body.timeframes) ? body.timeframes as string[] : TIMEFRAMES;

    const models = await loadModels();
    const missing = MODELS.filter((m) => !models[m.slug]);
    if (missing.length > 0) {
      return json({
        error: "analysis_models rows are missing",
        missingSlugs: missing.map((m) => m.slug),
        hint: "Apply migrations/20260725_add_double_pattern_models.sql first.",
      }, 412);
    }

    const symbols = await loadSymbols();
    if (symbols.length === 0) return json({ error: "no enabled USDT symbols" }, 500);

    const planned: PlannedEvent[] = [];
    let notifiableCount = 0;
    const withoutCandles: string[] = [];

    for (const timeframe of timeframes) {
      const freshnessMs = (TIMEFRAME_MINUTES[timeframe] ?? 15) * 60 * 1000 * NOTIFIABLE_CANDLES;
      for (let start = 0; start < symbols.length; start += CONCURRENCY) {
        const batch = symbols.slice(start, start + CONCURRENCY);
        const series = await Promise.all(
          batch.map(async (row) => ({ row, candles: await loadCandles(row.id, timeframe) })),
        );

        for (const { row, candles } of series) {
          if (candles.length === 0) {
            withoutCandles.push(`${row.symbol} ${timeframe}`);
            continue;
          }
          for (const model of MODELS) {
            const result = analyze(candles, model.direction);
            for (const event of result.events) {
              const fresh = Date.now() - event.time.getTime() <= freshnessMs;
              if (fresh) notifiableCount += 1;
              planned.push({
                symbol_id: row.id,
                analysis_model_id: models[model.slug],
                timeframe,
                status: event.status,
                candle_close_time: event.time.toISOString(),
                price: event.price,
                confidence: result.confidence,
                volume_ratio: result.volumeRatio,
                // These models score confidence directly; risk is reported as its
                // complement rather than invented.
                false_breakout_risk: Math.max(0, 100 - result.confidence),
                notifiable: fresh,
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
        wouldUpsert: planned.length,
        ofWhichNotifiable: notifiableCount,
        symbols: symbols.length,
        timeframes,
        seriesWithoutCandles: withoutCandles.slice(0, 20),
        seriesWithoutCandlesCount: withoutCandles.length,
        sample: planned.slice(0, 10),
        note:
          "Nothing was written. `seriesWithoutCandles` should be near zero — if it is not, sync-candles has not filled the store yet. Then call again with {\"dryRun\": false}.",
      });
    }

    const wrote = await upsertEvents(planned);
    return json({
      dryRun: false,
      wrote,
      considered: planned.length,
      ofWhichNotifiable: notifiableCount,
      symbols: symbols.length,
      timeframes,
      seriesWithoutCandlesCount: withoutCandles.length,
    });
  } catch (error) {
    return json({ error: String(error) }, 500);
  }
});

function serviceHeaders(extra: Record<string, string> = {}): HeadersInit {
  return {
    apikey: SERVICE_ROLE_KEY,
    Authorization: `Bearer ${SERVICE_ROLE_KEY}`,
    "Content-Type": "application/json",
    ...extra,
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
    `${SUPABASE_URL}/rest/v1/symbols?select=id,symbol&is_enabled=eq.true&quote_asset=eq.USDT` +
      `&order=quote_volume_24h.desc&limit=${SYMBOL_LIMIT}`,
    { headers: serviceHeaders() },
  );
  if (!response.ok) throw new Error(`symbols: ${response.status} ${await response.text()}`);
  return await response.json();
}

/** Newest `WINDOW` candles, returned oldest first as the analyzers expect. */
async function loadCandles(symbolId: string, timeframe: string): Promise<Candle[]> {
  const response = await fetch(
    `${SUPABASE_URL}/rest/v1/candles?select=open_time,close_time,open,high,low,close,volume` +
      `&symbol_id=eq.${symbolId}&timeframe=eq.${timeframe}` +
      `&order=open_time.desc&limit=${WINDOW}`,
    { headers: serviceHeaders() },
  );
  if (!response.ok) throw new Error(`candles: ${response.status} ${await response.text()}`);
  const rows = await response.json() as Array<Record<string, string | number>>;
  return rows
    .map((row) => ({
      openTime: new Date(row.open_time as string),
      closeTime: new Date(row.close_time as string),
      open: Number(row.open),
      high: Number(row.high),
      low: Number(row.low),
      close: Number(row.close),
      volume: Number(row.volume),
    }))
    .reverse();
}

/**
 * Ignore-duplicates, not merge: a transition already on record keeps the row it
 * was written with. Re-deriving must not flip an alert that already went out
 * back to notifiable = false, nor re-open one that did not.
 */
async function upsertEvents(planned: PlannedEvent[]): Promise<number> {
  if (planned.length === 0) return 0;
  const chunkSize = 500;
  let wrote = 0;
  for (let start = 0; start < planned.length; start += chunkSize) {
    const chunk = planned.slice(start, start + chunkSize);
    const response = await fetch(
      `${SUPABASE_URL}/rest/v1/signal_journey_events` +
        `?on_conflict=symbol_id,analysis_model_id,timeframe,status,candle_close_time`,
      {
        method: "POST",
        headers: serviceHeaders({ Prefer: "resolution=ignore-duplicates,return=minimal" }),
        body: JSON.stringify(chunk),
      },
    );
    if (!response.ok) {
      throw new Error(`signal_journey_events upsert: ${response.status} ${await response.text()}`);
    }
    wrote += chunk.length;
  }
  return wrote;
}

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body, null, 2), {
    status,
    headers: { "Content-Type": "application/json" },
  });
}
