/**
 * Composes the title and body stored on `notifications`, which is what the user
 * reads on the lock screen.
 *
 * The app cannot fix this text: it only renders `notifications.title` and
 * `notifications.body` as the backend wrote them. So whichever job inserts those
 * rows has to use this, or the push will keep saying something different from
 * what the app shows.
 *
 * The body exposes exactly two facts — the named current market state and 24h
 * dollar volume — so a lock-screen alert can be understood without opening
 * the detail screen.
 */

export type Direction = "bullish" | "bearish";

export interface NotificationInput {
  /** Base asset, e.g. "BTC" — not the pair. */
  baseAsset: string;
  /** Journey status, as stored in signal_journey_events. */
  status: string;
  /** market_state_current.state; null while not yet measured. */
  marketState: string | null;
  stateScore: number | null;
  stateScoreChange: number | null;
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
  confirmed: { bullish: "Kırılım tuttu", bearish: "Düşüş tuttu" },
  failed: {
    bullish: "Sinyal geçersiz (-%5)",
    bearish: "Sinyal geçersiz (+%5)",
  },
  expired: { bullish: "Takip tamamlandı", bearish: "Takip tamamlandı" },
};

const PHASE_EN: Record<string, { bullish: string; bearish: string }> = {
  pre_breakout: {
    bullish: "Waiting for breakout",
    bearish: "Waiting for breakdown",
  },
  breakout_detected: {
    bullish: "Breakout started",
    bearish: "Breakdown started",
  },
  confirmed: {
    bullish: "Breakout held",
    bearish: "Breakdown held",
  },
  failed: {
    bullish: "Signal invalidated (-5%)",
    bearish: "Signal invalidated (+5%)",
  },
  expired: { bullish: "Tracking complete", bearish: "Tracking complete" },
};

const MARKET_STATE_TR: Record<string, string> = {
  neutral: "Nötr",
  selling_dominant: "Satış baskın",
  seller_impact_fading: "Satıcı etkisi zayıflıyor",
  buy_side_absorption: "Alıcı absorpsiyonu",
  bounce_attempt: "Tepki denemesi",
  bullish_confirmation: "Yukarı yönlü teyit",
  bullish_momentum: "Güçlü yükseliş momentumu",
  breakdown_risk: "Aşağı kırılım riski",
};

const MARKET_STATE_EN: Record<string, string> = {
  neutral: "Neutral",
  selling_dominant: "Selling dominant",
  seller_impact_fading: "Seller impact fading",
  buy_side_absorption: "Buy-side absorption",
  bounce_attempt: "Bounce attempt",
  bullish_confirmation: "Bullish confirmation",
  bullish_momentum: "Strong bullish momentum",
  breakdown_risk: "Breakdown risk",
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
      return `$${
        scaled.toFixed(scaled >= 100 ? 0 : scaled >= 10 ? 1 : 2)
      }${suffix}`;
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

export function composeNotification(
  input: NotificationInput,
): { title: string; body: string } {
  const stateTable = input.language === "tr"
    ? MARKET_STATE_TR
    : MARKET_STATE_EN;
  const state = input.marketState === null
    ? (input.language === "tr" ? "Durum güncelleniyor" : "State updating")
    : (stateTable[input.marketState] ?? input.marketState);
  const title = `${input.baseAsset} · ${state}`;
  const volume = formatVolume(input.quoteVolume24h);
  const strength = input.marketState === "neutral"
    ? (input.language === "tr" ? "Aktif durum yok" : "No active state")
    : input.stateScore === null
    ? (input.language === "tr" ? "Güç ölçülüyor" : "Strength updating")
    : (input.language === "tr"
      ? `Güç ${Math.round(input.stateScore)}/100`
      : `Strength ${Math.round(input.stateScore)}/100`);
  const change = input.stateScoreChange === null
    ? (input.language === "tr" ? "İlk ölçüm" : "First reading")
    : input.stateScoreChange === 0
    ? (input.language === "tr" ? "Değişim yok" : "No change")
    : (input.language === "tr" ? "Değişim " : "Change ") +
      `${input.stateScoreChange > 0 ? "+" : ""}${
        Math.round(input.stateScoreChange)
      }`;
  const body = input.language === "tr"
    ? `${strength} · ${change} · 24s hacim ${volume}`
    : `${strength} · ${change} · 24h volume ${volume}`;

  return { title, body };
}
