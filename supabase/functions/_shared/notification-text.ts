/**
 * Composes the title and body stored on `notifications`, which is what the user
 * reads on the lock screen.
 *
 * The app cannot fix this text: it only renders `notifications.title` and
 * `notifications.body` as the backend wrote them. So whichever job inserts those
 * rows has to use this, or the push will keep saying something different from
 * what the app shows.
 *
 * Two rules this encodes, both requested directly:
 *   * Show the signal strength and the 24-hour volume in dollars.
 *   * Do not show false-breakout risk, and do not express volume as a multiple
 *     of the previous candle — "3.2x" says nothing about whether a coin is worth
 *     trading, while "$1.2B" does.
 */

export type Direction = "bullish" | "bearish";

export interface NotificationInput {
  /** Base asset, e.g. "BTC" — not the pair. */
  baseAsset: string;
  /** Journey status, as stored in signal_journey_events. */
  status: string;
  /** 0–100 confidence for this journey. */
  confidence: number;
  /** 24-hour quote volume in USD. */
  quoteVolume24h: number;
  /** Price at the transition. */
  price: number;
  direction: Direction;
  language: "tr" | "en";
}

const PHASE_TR: Record<string, { bullish: string; bearish: string }> = {
  pre_breakout: { bullish: "Kırılım bekleniyor", bearish: "Düşüş bekleniyor" },
  breakout_detected: { bullish: "Kırılım başladı", bearish: "Düşüş başladı" },
  confirmed: { bullish: "Kırılım güçleniyor", bearish: "Düşüş güçleniyor" },
  retest: { bullish: "Seviye test ediliyor", bearish: "Seviye test ediliyor" },
  failed: { bullish: "Sinyal geçersiz oldu", bearish: "Sinyal geçersiz oldu" },
  expired: { bullish: "Takip tamamlandı", bearish: "Takip tamamlandı" },
};

const PHASE_EN: Record<string, { bullish: string; bearish: string }> = {
  pre_breakout: { bullish: "Waiting for breakout", bearish: "Waiting for breakdown" },
  breakout_detected: { bullish: "Breakout started", bearish: "Breakdown started" },
  confirmed: { bullish: "Breakout strengthening", bearish: "Breakdown strengthening" },
  retest: { bullish: "Level being tested", bearish: "Level being tested" },
  failed: { bullish: "Signal invalidated", bearish: "Signal invalidated" },
  expired: { bullish: "Tracking complete", bearish: "Tracking complete" },
};

/** Compact dollar volume: 1_234_567_890 -> "$1.23B". */
export function formatVolume(value: number): string {
  if (!Number.isFinite(value) || value <= 0) return "$0";
  const units: Array<[number, string]> = [
    [1_000_000_000_000, "T"],
    [1_000_000_000, "B"],
    [1_000_000, "M"],
    [1_000, "K"],
  ];
  for (const [size, suffix] of units) {
    if (value >= size) {
      const scaled = value / size;
      return `$${scaled.toFixed(scaled >= 100 ? 0 : scaled >= 10 ? 1 : 2)}${suffix}`;
    }
  }
  return `$${Math.round(value)}`;
}

/** Price with enough precision to be readable for both BTC and a sub-cent coin. */
export function formatPrice(value: number): string {
  if (!Number.isFinite(value)) return "-";
  const decimals = value >= 1000 ? 2 : value >= 1 ? 4 : 6;
  return `$${value.toFixed(decimals).replace(/0+$/, "").replace(/\.$/, "")}`;
}

export function composeNotification(input: NotificationInput): { title: string; body: string } {
  const table = input.language === "tr" ? PHASE_TR : PHASE_EN;
  const phase = table[input.status]?.[input.direction] ?? input.status;
  const strength = Math.round(input.confidence);
  const volume = formatVolume(input.quoteVolume24h);
  const price = formatPrice(input.price);

  const title = `${input.baseAsset} · ${phase}`;
  const body = input.language === "tr"
    ? `Güven ${strength}/100 · Hacim ${volume} · Fiyat ${price}`
    : `Confidence ${strength}/100 · Vol. ${volume} · Price ${price}`;

  return { title, body };
}
