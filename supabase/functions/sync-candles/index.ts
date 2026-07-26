/**
 * Phase 1: fills the candle store, so the server derives from the same history
 * the app sees instead of from whatever a single API call happened to return.
 *
 * Only closed candles are written. An open candle would let a phase flip back
 * and forth inside one bar, which is exactly the repainting the closed-candle
 * principle exists to prevent.
 *
 * Deploy:
 *   supabase functions deploy sync-candles
 *
 * Schedule with pg_cron. Each timeframe only needs sweeping about as often as
 * its candles close, so give them separate schedules rather than sweeping all
 * seven every run:
 *
 *   15m -> every 5 min      2h -> every 30 min
 *   30m -> every 10 min     4h, 6h -> hourly
 *   1h  -> every 15 min     1d -> every 6 hours
 *
 *   select cron.schedule('candles-15m', '*∕5 * * * *', $$
 *     select net.http_post(
 *       url := 'https://<project>.supabase.co/functions/v1/sync-candles',
 *       headers := '{"Authorization":"Bearer <service-role-key>","Content-Type":"application/json"}'::jsonb,
 *       body := '{"timeframes":["15m"]}'::jsonb
 *     ) $$);
 *
 * Measured: a full sweep of 470 USDT pairs across all seven timeframes is about
 * 3300 requests, roughly 4 minutes at concurrency 40, and uses a small fraction
 * of Binance's 6000/minute weight budget. Weight is not the constraint; latency
 * is. Incremental sweeps (the default `limit` below) are far cheaper again.
 */

import { requireCronSecret } from "../_shared/http.ts";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

const BINANCE_KLINES = "https://data-api.binance.vision/api/v3/klines";

const TIMEFRAMES = ["15m", "30m", "1h", "2h", "4h", "6h", "1d"];

/** Every enabled pair is swept; the limit is just a sane upper bound. */
const SYMBOL_LIMIT = 600;
/**
 * Candles fetched per symbol. Enough to close a gap left by a missed run without
 * re-downloading history that is already stored. Raise it once, via the request
 * body, to seed a new timeframe.
 */
const DEFAULT_LIMIT = 50;
/** Symbols in flight at once. Measured: throughput saturates around here. */
const CONCURRENCY = 40;

interface SymbolRow {
  id: string;
  symbol: string;
}

Deno.serve(async (request) => {
  const unauthorized = requireCronSecret(request);
  if (unauthorized) return unauthorized;
  try {
    const body = request.method === "POST"
      ? await request.json().catch(() => ({}) as Record<string, unknown>)
      : {};
    const timeframes = Array.isArray(body.timeframes) ? body.timeframes as string[] : TIMEFRAMES;
    const limit = typeof body.limit === "number" ? Math.min(Math.max(body.limit, 2), 1000) : DEFAULT_LIMIT;
    const symbolLimit = typeof body.symbolLimit === "number" ? body.symbolLimit : SYMBOL_LIMIT;

    const symbols = await loadSymbols(symbolLimit);
    if (symbols.length === 0) return json({ error: "no enabled USDT symbols" }, 500);

    let written = 0;
    const failed: string[] = [];

    for (const timeframe of timeframes) {
      for (let start = 0; start < symbols.length; start += CONCURRENCY) {
        const batch = symbols.slice(start, start + CONCURRENCY);
        const results = await Promise.all(
          batch.map(async (row) => {
            try {
              return { row, candles: await fetchCandles(row.symbol, timeframe, limit) };
            } catch {
              failed.push(`${row.symbol} ${timeframe}`);
              return { row, candles: [] };
            }
          }),
        );
        const payload = results.flatMap(({ row, candles }) =>
          candles.map((c) => ({ symbol_id: row.id, timeframe, ...c }))
        );
        if (payload.length > 0) written += await upsertCandles(payload);
      }
    }

    return json({
      timeframes,
      symbols: symbols.length,
      candlesPerSymbol: limit,
      written,
      failed: failed.slice(0, 20),
      failedCount: failed.length,
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

async function loadSymbols(limit: number): Promise<SymbolRow[]> {
  const response = await fetch(
    `${SUPABASE_URL}/rest/v1/symbols?select=id,symbol&is_enabled=eq.true&quote_asset=eq.USDT` +
      `&order=quote_volume_24h.desc&limit=${limit}`,
    { headers: serviceHeaders() },
  );
  if (!response.ok) throw new Error(`symbols: ${response.status} ${await response.text()}`);
  return await response.json();
}

interface CandleRow {
  open_time: string;
  close_time: string;
  open: number;
  high: number;
  low: number;
  close: number;
  volume: number;
  quote_volume: number;
  trade_count: number;
  taker_buy_base_volume: number;
  taker_buy_quote_volume: number;
}

async function fetchCandles(symbol: string, interval: string, limit: number): Promise<CandleRow[]> {
  const url = `${BINANCE_KLINES}?symbol=${symbol.toUpperCase()}&interval=${interval}&limit=${limit}`;
  const response = await fetch(url);
  if (!response.ok) throw new Error(`binance ${symbol} ${interval}: ${response.status}`);
  const rows = await response.json() as unknown[][];
  const now = Date.now();

  return rows
    // Closed candles only.
    .filter((row) => Number(row[6]) < now)
    .map((row) => ({
      open_time: new Date(Number(row[0])).toISOString(),
      close_time: new Date(Number(row[6])).toISOString(),
      open: Number(row[1]),
      high: Number(row[2]),
      low: Number(row[3]),
      close: Number(row[4]),
      volume: Number(row[5]),
      quote_volume: Number(row[7]),
      trade_count: Number(row[8]),
      taker_buy_base_volume: Number(row[9]),
      taker_buy_quote_volume: Number(row[10]),
    }));
}

/**
 * Re-sweeping the same range is normal, so conflicts are expected rather than
 * exceptional: an already-stored candle is immutable and simply kept.
 *
 * Chunked: a deep seed produces tens of thousands of rows per batch, and one
 * PostgREST call that large times out at the gateway (504).
 */
async function upsertCandles(payload: unknown[]): Promise<number> {
  const chunkSize = 2_000;
  for (let start = 0; start < payload.length; start += chunkSize) {
    const chunk = payload.slice(start, start + chunkSize);
    const response = await fetch(
      `${SUPABASE_URL}/rest/v1/candles?on_conflict=symbol_id,timeframe,open_time`,
      {
        method: "POST",
        headers: serviceHeaders({
          Prefer: "resolution=ignore-duplicates,return=minimal",
        }),
        body: JSON.stringify(chunk),
      },
    );
    if (!response.ok) throw new Error(`candles upsert: ${response.status} ${await response.text()}`);
  }
  return payload.length;
}

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body, null, 2), {
    status,
    headers: { "Content-Type": "application/json" },
  });
}
