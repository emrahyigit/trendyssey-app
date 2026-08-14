/**
 * Runs the Market State Scenario rules against a real exchange — Spot Testnet by
 * default. Fired by cron every minute; each run is one reconciliation pass:
 *
 *   1. Open positions: did the OCO exit fill? Did the holding limit expire?
 *   2. Legacy pending entries: filled → place the exit OCO;
 *      still unfilled by the next pass → cancel. The entry either fills within
 *      one cycle or the trade is skipped; a partial fill keeps the filled part
 *      as the position and cancels the rest.
 *   3. Fresh Market State transitions that pass the same filters as the
 *      scenario page (state, state score, 24h volume, slots) open a
 *      new position immediately at market.
 *      A coin never carries two active positions and never re-enters on the
 *      same UTC day, mirroring the scenario page's one-position-per-coin rule.
 *
 * Long-only: spot cannot short, so bearish signals never trade. All decisions
 * and errors are written to live_trades; the executor never throws a run away
 * over one bad symbol.
 */

import { json, requireCronSecret } from "../_shared/http.ts";
import { adminClient } from "../_shared/supabase.ts";
import { BinanceClient, fetchClosedKlines } from "../_shared/binance.ts";

interface TradeConfig {
  enabled: boolean;
  use_testnet: boolean;
  timeframe: string;
  model_slug: string;
  profit_target_percent: number;
  stop_loss_percent: number;
  max_open_hours: number;
  max_slots: number;
  quote_per_trade: number;
  minimum_signal_strength: number;
  minimum_success_rate: number;
  minimum_quote_volume: number;
  /// Both trend fields ship in 20260811160000; until that migration runs the
  /// row has no such keys and the filters read as off.
  minimum_trend_score?: number;
  require_trend_entry?: boolean;
  allowed_market_states?: string[];
  minimum_state_score?: number;
  /// Chandelier fields ship in 20260811180000; absent keys read as off.
  use_chandelier_exit?: boolean;
  chandelier_atr_multiplier?: number;
  reset_requested: boolean;
}

/** ATR(14) over closed candles, same recurrence as _shared/indicators.ts. */
function atrFromKlines(candles: Array<{ high: number; low: number; close: number }>, period = 14): number {
  if (candles.length < 2) return 0;
  let value = 0;
  const seed: number[] = [];
  for (let i = 1; i < candles.length; i++) {
    const range = Math.max(
      candles[i].high - candles[i].low,
      Math.abs(candles[i].high - candles[i - 1].close),
      Math.abs(candles[i].low - candles[i - 1].close),
    );
    if (seed.length < period) {
      seed.push(range);
      value = seed.reduce((a, b) => a + b, 0) / seed.length;
    } else {
      value = (value * (period - 1) + range) / period;
    }
  }
  return value;
}

Deno.serve(async (req) => {
  const unauthorized = requireCronSecret(req);
  if (unauthorized) return unauthorized;

  const supabase = adminClient();
  const { data: config } = await supabase
    .from("trade_config")
    .select("*")
    .eq("id", true)
    .maybeSingle();
  if (!config || !(config as TradeConfig).enabled) {
    return json({ data: { skipped: "disabled" } });
  }
  const cfg = config as TradeConfig;

  const binance = BinanceClient.forEnvironment(cfg.use_testnet);
  if (!binance) {
    return json({ data: { skipped: cfg.use_testnet ? "testnet keys missing" : "live trading not armed" } });
  }

  const summary = { closed: 0, entered: 0, pendingFilled: 0, canceled: 0, errors: [] as string[] };

  if (cfg.reset_requested) {
    await resetLedger(supabase, binance, cfg, summary);
    return json({ data: { reset: true, errors: summary.errors } });
  }

  await reconcileOpenTrades(supabase, binance, cfg, summary);
  await reconcilePendingEntries(supabase, binance, cfg, summary);
  await openNewTrades(supabase, binance, cfg, summary);

  return json({ data: summary });
});

/** Unwinds every position and starts the ledger over: cancels open orders,
 * sells holdings back to the quote asset, deletes the environment's rows and
 * clears the flag. Cancel failures are logged but never block the wipe. */
async function resetLedger(supabase: any, binance: BinanceClient, cfg: TradeConfig, summary: any) {
  const { data: active } = await supabase
    .from("live_trades")
    .select("*")
    .in("status", ["open", "pending_entry"])
    .eq("is_testnet", cfg.use_testnet);
  for (const trade of active ?? []) {
    try {
      if (trade.status === "open") {
        if (trade.oco_order_list_id) await binance.cancelOrderList(trade.symbol, trade.oco_order_list_id);
        if (trade.exit_order_id) await binance.cancelOrder(trade.symbol, trade.exit_order_id);
        if (trade.entry_quantity) await binance.marketSell(trade.symbol, trade.entry_quantity);
      } else if (trade.entry_order_id) {
        await binance.cancelOrder(trade.symbol, trade.entry_order_id);
      }
    } catch (error) {
      summary.errors.push(`reset ${trade.symbol}: ${message(error)}`);
    }
  }
  await supabase.from("live_trades").delete().eq("is_testnet", cfg.use_testnet);
  await supabase.from("trade_config").update({
    reset_requested: false,
    updated_at: new Date().toISOString(),
  }).eq("id", true);
}

async function reconcileOpenTrades(supabase: any, binance: BinanceClient, cfg: TradeConfig, summary: any) {
  const { data: open } = await supabase
    .from("live_trades")
    .select("*")
    .eq("status", "open")
    .eq("is_testnet", cfg.use_testnet);
  for (const trade of open ?? []) {
    try {
      // Chandelier positions carry a single ratcheting stop instead of an OCO.
      if (trade.exit_order_id) {
        await reconcileChandelierTrade(supabase, binance, cfg, trade, summary);
        continue;
      }
      const list = await binance.orderList(trade.oco_order_list_id);
      if (list.listOrderStatus === "ALL_DONE") {
        let exitPrice: number | null = null;
        let reason: string | null = null;
        for (const item of list.orders ?? []) {
          const order = await binance.order(trade.symbol, String(item.orderId));
          if (order.status === "FILLED" && Number(order.executedQty) > 0) {
            exitPrice = Number(order.cummulativeQuoteQty) / Number(order.executedQty);
            reason = order.type === "LIMIT_MAKER" ? "target" : "stop_loss";
          }
        }
        await closeTrade(supabase, trade, exitPrice, reason ?? "error", summary);
        continue;
      }
      const deadline = new Date(trade.entered_at).getTime() + cfg.max_open_hours * 3_600_000;
      if (Date.now() >= deadline) {
        await binance.cancelOrderList(trade.symbol, trade.oco_order_list_id);
        const sale = await binance.marketSell(trade.symbol, trade.entry_quantity);
        const exitPrice = Number(sale.executedQty) > 0
          ? Number(sale.cummulativeQuoteQty) / Number(sale.executedQty)
          : null;
        await closeTrade(supabase, trade, exitPrice, "time_limit", summary);
      }
    } catch (error) {
      await recordError(supabase, trade.id, error, summary);
    }
  }
}

async function reconcilePendingEntries(supabase: any, binance: BinanceClient, cfg: TradeConfig, summary: any) {
  const { data: pending } = await supabase
    .from("live_trades")
    .select("*")
    .eq("status", "pending_entry")
    .eq("is_testnet", cfg.use_testnet);
  for (const trade of pending ?? []) {
    try {
      const order = await binance.order(trade.symbol, trade.entry_order_id);
      if (order.status === "FILLED") {
        const entryPrice = Number(order.cummulativeQuoteQty) / Number(order.executedQty);
        await placeExitAndOpen(supabase, binance, cfg, trade, entryPrice, order.executedQty);
        summary.pendingFilled += 1;
        continue;
      }
      if (order.status === "CANCELED" || order.status === "EXPIRED" || order.status === "REJECTED") {
        await supabase.from("live_trades").update({
          status: "canceled",
          error_message: `entry order ${order.status.toLowerCase()}`,
          updated_at: new Date().toISOString(),
        }).eq("id", trade.id);
        summary.canceled += 1;
        continue;
      }
      // One cycle to fill, no more: the entry chases a breakout, and a
      // breakout that has not followed through by the next pass is not the
      // move we priced. The 45s floor only protects freshly placed orders
      // from overlapping or manual runs — a normal cron pass always sees
      // pending rows at least one minute old.
      if (Date.now() < new Date(trade.created_at).getTime() + 45_000) continue;
      let canceled: any;
      try {
        canceled = await binance.cancelOrder(trade.symbol, trade.entry_order_id);
      } catch (_error) {
        // Most likely the order filled between the status read and the
        // cancel; the next pass will see FILLED and open it normally.
        continue;
      }
      const partialQty = Number(canceled?.executedQty ?? order.executedQty ?? 0);
      if (partialQty > 0) {
        // Part of the entry filled before the cancel: that part is a real
        // position and still needs its exit OCO.
        const quote = Number(canceled?.cummulativeQuoteQty ?? order.cummulativeQuoteQty ?? 0);
        const entryPrice = quote > 0 ? quote / partialQty : Number(trade.entry_trigger_price);
        await placeExitAndOpen(supabase, binance, cfg, trade, entryPrice, String(partialQty));
        summary.pendingFilled += 1;
        continue;
      }
      await supabase.from("live_trades").update({
        status: "canceled",
        error_message: "not filled within one cycle",
        updated_at: new Date().toISOString(),
      }).eq("id", trade.id);
      summary.canceled += 1;
    } catch (error) {
      await recordError(supabase, trade.id, error, summary);
    }
  }
}

async function openNewTrades(supabase: any, binance: BinanceClient, cfg: TradeConfig, summary: any) {
  const { count: activeCount } = await supabase
    .from("live_trades")
    .select("id", { count: "exact", head: true })
    .in("status", ["open", "pending_entry"])
    .eq("is_testnet", cfg.use_testnet);
  let freeSlots = cfg.max_slots - (activeCount ?? 0);
  if (freeSlots <= 0) return;

  // The named Market State transition is the entry event. Older transitions
  // were already seen (or predate the executor) and cannot open stale trades.
  const { data: stateEvents, error: stateEventError } = await supabase
    .from("market_state_current")
    .select("symbol_id,state,state_score,state_score_change,state_since,candle_close_time,close_price,quote_volume_24h,symbols!inner(symbol,quote_volume_24h)")
    .eq("timeframe", cfg.timeframe)
    .in("state", cfg.allowed_market_states ?? ["bullish_confirmation"])
    .gte("state_since", new Date(Date.now() - 30 * 60_000).toISOString())
    .order("state_score", { ascending: false });
  if (stateEventError) {
    summary.errors.push(`market-state entries: ${stateEventError.message}`);
    return;
  }

  // Same-day re-entry guard uses the UTC day, matching the scenario page.
  const utcDayStart = new Date(Date.now() - (Date.now() % 86_400_000)).toISOString();

  for (const stateEvent of stateEvents ?? []) {
    if (freeSlots <= 0) break;
    try {
      const quoteVolume = Number(
        stateEvent.quote_volume_24h ?? stateEvent.symbols?.quote_volume_24h ?? 0,
      );
      if (quoteVolume < cfg.minimum_quote_volume) continue;
      if (Number(stateEvent.state_score ?? 0) < Number(cfg.minimum_state_score ?? 0)) continue;
      const symbol = stateEvent.symbols.symbol as string;

      // One position per state transition, ever. Re-scanning the same candle
      // must not pyramid into the same market observation.
      const { count: seen } = await supabase
        .from("live_trades")
        .select("id", { count: "exact", head: true })
        .eq("symbol", symbol)
        .eq("entry_timeframe", cfg.timeframe)
        .eq("market_state_since", stateEvent.state_since)
        .eq("is_testnet", cfg.use_testnet);
      if ((seen ?? 0) > 0) continue;

      // One position per coin: never a second entry while the coin has an
      // active position, and never a re-entry on the same UTC day — a new
      // journey on the same coin is still the same exposure. Canceled rows
      // never opened a position, so they don't block a later entry.
      const { count: sameCoin, error: sameCoinError } = await supabase
        .from("live_trades")
        .select("id", { count: "exact", head: true })
        .eq("symbol", symbol)
        .eq("is_testnet", cfg.use_testnet)
        .or(`status.in.(open,pending_entry),and(created_at.gte.${utcDayStart},status.neq.canceled)`);
      if (sameCoinError) {
        summary.errors.push(`${symbol}: same-coin check failed: ${sameCoinError.message}`);
        continue;
      }
      if ((sameCoin ?? 0) > 0) continue;

      let signalPrice = Number(stateEvent.close_price ?? 0);
      if (!(signalPrice > 0)) {
        const latest = await fetchClosedKlines(symbol, cfg.timeframe, { limit: 2 });
        signalPrice = Number(latest.at(-1)?.close ?? 0);
      }
      const snapshot = {
        signal_price: signalPrice > 0 ? signalPrice : null,
        entry_quote_volume: quoteVolume,
        entry_market_state: stateEvent.state,
        entry_market_state_score: stateEvent.state_score,
        entry_market_state_change: stateEvent.state_score_change,
        entry_timeframe: cfg.timeframe,
        market_state_since: stateEvent.state_since,
      };

      const rules = await binance.symbolRules(symbol);
      if (cfg.quote_per_trade < rules.minNotional) {
        summary.errors.push(`${symbol}: quote_per_trade below minNotional ${rules.minNotional}`);
        continue;
      }

      const order = await binance.marketBuyWithQuote(symbol, cfg.quote_per_trade);
      const executedQty = Number(order.executedQty);
      if (!(executedQty > 0)) throw new Error("market buy filled zero quantity");
      const entryPrice = Number(order.cummulativeQuoteQty) / executedQty;
      const { data: inserted } = await supabase.from("live_trades").insert({
        symbol,
        status: "open",
        entry_order_id: String(order.orderId),
        entry_price: entryPrice,
        entry_quantity: order.executedQty,
        entered_at: new Date().toISOString(),
        is_testnet: cfg.use_testnet,
        ...snapshot,
      }).select("*").single();
      await placeExitAndOpen(supabase, binance, cfg, inserted, entryPrice, order.executedQty);
      summary.entered += 1;
      freeSlots -= 1;
    } catch (error) {
      summary.errors.push(`${stateEvent.symbols?.symbol ?? stateEvent.symbol_id}: ${message(error)}`);
    }
  }
}

/** Watches a chandelier position: closes on a filled stop, enforces the time
 * limit, and otherwise ratchets the stop up with the closed-candle highs. */
async function reconcileChandelierTrade(
  supabase: any,
  binance: BinanceClient,
  cfg: TradeConfig,
  trade: any,
  summary: any,
) {
  const order = await binance.order(trade.symbol, trade.exit_order_id);
  if (order.status === "FILLED" && Number(order.executedQty) > 0) {
    const exitPrice = Number(order.cummulativeQuoteQty) / Number(order.executedQty);
    await closeTrade(supabase, trade, exitPrice, "stop_loss", summary);
    return;
  }
  const deadline = new Date(trade.entered_at).getTime() + cfg.max_open_hours * 3_600_000;
  if (Date.now() >= deadline) {
    await binance.cancelOrder(trade.symbol, trade.exit_order_id);
    const sale = await binance.marketSell(trade.symbol, trade.entry_quantity);
    const exitPrice = Number(sale.executedQty) > 0
      ? Number(sale.cummulativeQuoteQty) / Number(sale.executedQty)
      : null;
    await closeTrade(supabase, trade, exitPrice, "time_limit", summary);
    return;
  }
  // A stop that vanished without filling (manual cancel, exchange expiry)
  // leaves the position unprotected — it must be restored this pass.
  const orderGone = order.status === "CANCELED" || order.status === "EXPIRED" ||
    order.status === "REJECTED";
  const rules = await binance.symbolRules(trade.symbol);
  const atr = Number(trade.atr_at_entry ?? 0);
  const currentStop = Number(trade.stop_price ?? 0);
  if (!(atr > 0)) {
    // No ATR was measurable at entry: the fixed fallback stop never trails.
    if (orderGone) await placeTrailingStop(supabase, binance, trade, currentStop, Number(trade.high_watermark ?? 0), rules);
    return;
  }
  const candles = await fetchClosedKlines(trade.symbol, cfg.timeframe, {
    startTime: new Date(trade.entered_at).getTime(),
    limit: 1000,
  });
  const watermark = Math.max(
    Number(trade.high_watermark ?? 0),
    Number(trade.entry_price ?? 0),
    ...candles.map((candle) => candle.high),
  );
  const multiplier = cfg.chandelier_atr_multiplier ?? 3;
  const nextStop = Number(binance.roundPrice(watermark - multiplier * atr, rules));
  // Ratchet only: the stop rises with the watermark and never comes back down.
  if (!orderGone && nextStop <= currentStop + rules.tickSize / 2) {
    if (watermark > Number(trade.high_watermark ?? 0)) {
      await supabase.from("live_trades").update({
        high_watermark: watermark,
        updated_at: new Date().toISOString(),
      }).eq("id", trade.id);
    }
    return;
  }
  if (!orderGone) {
    try {
      await binance.cancelOrder(trade.symbol, trade.exit_order_id);
    } catch (_error) {
      // Most likely the stop filled between the status read and the cancel;
      // the next pass will see FILLED and close the trade normally.
      return;
    }
  }
  await placeTrailingStop(supabase, binance, trade, Math.max(nextStop, currentStop), watermark, rules);
}

/** Places (or restores) the chandelier stop and records its new level. */
async function placeTrailingStop(
  supabase: any,
  binance: BinanceClient,
  trade: any,
  stopPrice: number,
  watermark: number,
  rules: any,
) {
  const stopTrigger = binance.roundPrice(Math.max(stopPrice, rules.tickSize), rules);
  const stopLimit = binance.roundPrice(Number(stopTrigger) * 0.995, rules);
  const quantity = binance.roundQuantity(Number(trade.entry_quantity), rules);
  const order = await binance.stopLimitSell(trade.symbol, quantity, stopTrigger, stopLimit);
  await supabase.from("live_trades").update({
    exit_order_id: String(order.orderId),
    stop_price: Number(stopTrigger),
    high_watermark: watermark,
    updated_at: new Date().toISOString(),
  }).eq("id", trade.id);
}

/** Places the exit for a filled entry and marks the trade open: the fixed
 * target+stop OCO, or the chandelier trailing stop when the config asks. */
async function placeExitAndOpen(
  supabase: any,
  binance: BinanceClient,
  cfg: TradeConfig,
  trade: any,
  entryPrice: number,
  executedQty: string,
) {
  const rules = await binance.symbolRules(trade.symbol);
  const quantity = binance.roundQuantity(Number(executedQty), rules);
  if (cfg.use_chandelier_exit ?? false) {
    // Trail width freezes at entry, exactly like the backtest: the stop
    // follows the highs, not later volatility. If ATR cannot be measured the
    // fixed stop-loss percent protects the position without trailing.
    let atr = 0;
    try {
      atr = atrFromKlines(await fetchClosedKlines(trade.symbol, cfg.timeframe, { limit: 120 }));
    } catch (_error) {
      atr = 0;
    }
    const multiplier = cfg.chandelier_atr_multiplier ?? 3;
    const initialStop = atr > 0
      ? entryPrice - multiplier * atr
      : entryPrice * (1 - cfg.stop_loss_percent / 100);
    const stopTrigger = binance.roundPrice(Math.max(initialStop, rules.tickSize), rules);
    const stopLimit = binance.roundPrice(Number(stopTrigger) * 0.995, rules);
    const order = await binance.stopLimitSell(trade.symbol, quantity, stopTrigger, stopLimit);
    await supabase.from("live_trades").update({
      status: "open",
      entry_price: entryPrice,
      entry_quantity: quantity,
      entered_at: trade.entered_at ?? new Date().toISOString(),
      exit_order_id: String(order.orderId),
      stop_price: Number(stopTrigger),
      target_price: null,
      high_watermark: entryPrice,
      atr_at_entry: atr > 0 ? atr : null,
      updated_at: new Date().toISOString(),
    }).eq("id", trade.id);
    return;
  }
  const target = binance.roundPrice(entryPrice * (1 + cfg.profit_target_percent / 100), rules);
  const stopTrigger = binance.roundPrice(entryPrice * (1 - cfg.stop_loss_percent / 100), rules);
  const stopLimit = binance.roundPrice(Number(stopTrigger) * 0.995, rules);
  const oco = await binance.ocoSell(trade.symbol, quantity, target, stopTrigger, stopLimit);
  await supabase.from("live_trades").update({
    status: "open",
    entry_price: entryPrice,
    entry_quantity: quantity,
    entered_at: trade.entered_at ?? new Date().toISOString(),
    oco_order_list_id: String(oco.orderListId),
    target_price: Number(target),
    stop_price: Number(stopTrigger),
    updated_at: new Date().toISOString(),
  }).eq("id", trade.id);
}

async function closeTrade(supabase: any, trade: any, exitPrice: number | null, reason: string, summary: any) {
  const pnl = exitPrice !== null && trade.entry_price
    ? (exitPrice - Number(trade.entry_price)) * Number(trade.entry_quantity)
    : null;
  await supabase.from("live_trades").update({
    status: reason === "error" ? "error" : "closed",
    exit_price: exitPrice,
    exit_reason: reason,
    exited_at: new Date().toISOString(),
    realized_quote_pnl: pnl,
    updated_at: new Date().toISOString(),
  }).eq("id", trade.id);
  summary.closed += 1;
}

async function recordError(supabase: any, tradeId: string, error: unknown, summary: any) {
  summary.errors.push(message(error));
  await supabase.from("live_trades").update({
    error_message: message(error),
    updated_at: new Date().toISOString(),
  }).eq("id", tradeId);
}

function message(error: unknown): string {
  return error instanceof Error ? error.message : String(error);
}
