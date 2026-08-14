/**
 * Minimal signed Binance Spot REST client for the trade executor.
 *
 * Testnet by default (testnet.binance.vision — play money, same API surface).
 * The live host only engages when the caller explicitly asks for it AND the
 * LIVE_TRADING_ENABLED env is set to "yes" — a deliberate second switch so a
 * config flag alone can never reach real funds.
 */

const HOSTS = {
  live: "https://api.binance.com",
  testnet: "https://testnet.binance.vision",
} as const;

/**
 * Closed candles from the LIVE market-data host, regardless of trading
 * environment: the testnet's order books are play money and its klines are
 * too thin to measure ATR or highs against. Unsigned, so no keys involved.
 */
export async function fetchClosedKlines(
  symbol: string,
  interval: string,
  options: { startTime?: number; limit?: number } = {},
): Promise<Array<{ high: number; low: number; close: number; closeTime: number }>> {
  const search = new URLSearchParams({ symbol, interval, limit: String(options.limit ?? 500) });
  if (options.startTime) search.set("startTime", String(options.startTime));
  const response = await fetch(`${HOSTS.live}/api/v3/klines?${search}`);
  if (!response.ok) throw new BinanceError(response.status, null, `klines HTTP ${response.status}`);
  const rows: any[][] = await response.json();
  const now = Date.now();
  return rows
    .map((row) => ({ high: Number(row[2]), low: Number(row[3]), close: Number(row[4]), closeTime: Number(row[6]) }))
    .filter((candle) => candle.closeTime <= now);
}

export interface SymbolRules {
  stepSize: number;
  tickSize: number;
  minNotional: number;
}

export class BinanceError extends Error {
  constructor(readonly status: number, readonly code: number | null, message: string) {
    super(message);
  }
}

export class BinanceClient {
  private rulesCache = new Map<string, SymbolRules>();

  constructor(
    private readonly host: string,
    private readonly apiKey: string,
    private readonly apiSecret: string,
  ) {}

  static forEnvironment(useTestnet: boolean): BinanceClient | null {
    if (!useTestnet && Deno.env.get("LIVE_TRADING_ENABLED") !== "yes") return null;
    const apiKey = Deno.env.get(useTestnet ? "BINANCE_TESTNET_API_KEY" : "BINANCE_API_KEY");
    const apiSecret = Deno.env.get(useTestnet ? "BINANCE_TESTNET_API_SECRET" : "BINANCE_API_SECRET");
    if (!apiKey || !apiSecret) return null;
    return new BinanceClient(useTestnet ? HOSTS.testnet : HOSTS.live, apiKey, apiSecret);
  }

  /** LOT_SIZE / PRICE_FILTER / NOTIONAL rules, cached per run. */
  async symbolRules(symbol: string): Promise<SymbolRules> {
    const cached = this.rulesCache.get(symbol);
    if (cached) return cached;
    const info = await this.request("GET", "/api/v3/exchangeInfo", { symbol }, false);
    const filters: Array<Record<string, string>> = info?.symbols?.[0]?.filters ?? [];
    const byType = new Map(filters.map((filter) => [filter.filterType, filter]));
    const rules: SymbolRules = {
      stepSize: Number(byType.get("LOT_SIZE")?.stepSize ?? "0.00000001"),
      tickSize: Number(byType.get("PRICE_FILTER")?.tickSize ?? "0.00000001"),
      minNotional: Number(
        byType.get("NOTIONAL")?.minNotional ?? byType.get("MIN_NOTIONAL")?.minNotional ?? "0",
      ),
    };
    this.rulesCache.set(symbol, rules);
    return rules;
  }

  roundQuantity(quantity: number, rules: SymbolRules): string {
    return floorToIncrement(quantity, rules.stepSize);
  }

  roundPrice(price: number, rules: SymbolRules): string {
    return floorToIncrement(price, rules.tickSize);
  }

  marketBuyWithQuote(symbol: string, quoteAmount: number): Promise<any> {
    return this.request("POST", "/api/v3/order", {
      symbol,
      side: "BUY",
      type: "MARKET",
      quoteOrderQty: quoteAmount.toFixed(2),
    });
  }

  marketSell(symbol: string, quantity: string): Promise<any> {
    return this.request("POST", "/api/v3/order", {
      symbol,
      side: "SELL",
      type: "MARKET",
      quantity,
    });
  }

  /** Stop-limit BUY that waits for the extra follow-through trigger. */
  stopLimitBuy(symbol: string, quantity: string, stopPrice: string, limitPrice: string): Promise<any> {
    return this.request("POST", "/api/v3/order", {
      symbol,
      side: "BUY",
      type: "STOP_LOSS_LIMIT",
      timeInForce: "GTC",
      quantity,
      stopPrice,
      price: limitPrice,
    });
  }

  /** Stop-limit SELL — the chandelier trailing stop. Re-placed higher as the
   * trade's high watermark rises; never lowered. */
  stopLimitSell(symbol: string, quantity: string, stopPrice: string, limitPrice: string): Promise<any> {
    return this.request("POST", "/api/v3/order", {
      symbol,
      side: "SELL",
      type: "STOP_LOSS_LIMIT",
      timeInForce: "GTC",
      quantity,
      stopPrice,
      price: limitPrice,
    });
  }

  /** Target (limit-maker above) + stop (stop-limit below) exit pair. */
  ocoSell(
    symbol: string,
    quantity: string,
    targetPrice: string,
    stopTrigger: string,
    stopLimit: string,
  ): Promise<any> {
    return this.request("POST", "/api/v3/orderList/oco", {
      symbol,
      side: "SELL",
      quantity,
      aboveType: "LIMIT_MAKER",
      abovePrice: targetPrice,
      belowType: "STOP_LOSS_LIMIT",
      belowStopPrice: stopTrigger,
      belowPrice: stopLimit,
      belowTimeInForce: "GTC",
    });
  }

  order(symbol: string, orderId: string): Promise<any> {
    return this.request("GET", "/api/v3/order", { symbol, orderId });
  }

  orderList(orderListId: string): Promise<any> {
    return this.request("GET", "/api/v3/orderList", { orderListId });
  }

  cancelOrder(symbol: string, orderId: string): Promise<any> {
    return this.request("DELETE", "/api/v3/order", { symbol, orderId });
  }

  cancelOrderList(symbol: string, orderListId: string): Promise<any> {
    return this.request("DELETE", "/api/v3/orderList", { symbol, orderListId });
  }

  private async request(
    method: string,
    path: string,
    params: Record<string, string> = {},
    signed = true,
  ): Promise<any> {
    const search = new URLSearchParams(params);
    if (signed) {
      search.set("timestamp", String(Date.now()));
      search.set("recvWindow", "10000");
      search.set("signature", await this.sign(search.toString()));
    }
    const query = search.toString();
    const url = `${this.host}${path}${query ? `?${query}` : ""}`;
    const response = await fetch(url, {
      method,
      headers: { "X-MBX-APIKEY": this.apiKey },
    });
    const text = await response.text();
    let body: any = null;
    try {
      body = text ? JSON.parse(text) : null;
    } catch {
      body = { msg: text };
    }
    if (!response.ok) {
      throw new BinanceError(response.status, body?.code ?? null, body?.msg ?? `HTTP ${response.status}`);
    }
    return body;
  }

  private async sign(query: string): Promise<string> {
    const encoder = new TextEncoder();
    const key = await crypto.subtle.importKey(
      "raw",
      encoder.encode(this.apiSecret),
      { name: "HMAC", hash: "SHA-256" },
      false,
      ["sign"],
    );
    const signature = await crypto.subtle.sign("HMAC", key, encoder.encode(query));
    return Array.from(new Uint8Array(signature))
      .map((byte) => byte.toString(16).padStart(2, "0"))
      .join("");
  }
}

/** Floors a value to an exchange increment and prints it without float dust. */
function floorToIncrement(value: number, increment: number): string {
  if (increment <= 0) return String(value);
  const decimals = Math.max(0, Math.round(-Math.log10(increment)));
  const floored = Math.floor((value + Number.EPSILON) / increment) * increment;
  return floored.toFixed(decimals);
}
