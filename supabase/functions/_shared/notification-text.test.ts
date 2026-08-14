import {
  composeNotification,
  formatPrice,
  formatVolume,
} from "./notification-text.ts";

function assertEqual(actual: unknown, expected: unknown, label: string): void {
  if (actual !== expected) {
    throw new Error(
      `${label}: expected ${JSON.stringify(expected)}, got ${
        JSON.stringify(actual)
      }`,
    );
  }
}

Deno.test("volume reads in dollars, not as a multiple", () => {
  assertEqual(formatVolume(1_234_567_890), "$1.23B", "billions");
  assertEqual(formatVolume(12_345_678), "$12.3M", "tens of millions");
  assertEqual(formatVolume(456_789_012), "$457M", "hundreds of millions");
  assertEqual(formatVolume(8_500), "$8.50K", "thousands");
  assertEqual(formatVolume(0), "$0", "zero");
});

Deno.test("price keeps precision for cheap coins", () => {
  assertEqual(formatPrice(64_231.5), "$64231.5", "large");
  assertEqual(formatPrice(0.00004212), "$0.000042", "sub-cent");
});

Deno.test("body carries market state and 24h volume, nothing else", () => {
  const { title, body } = composeNotification({
    baseAsset: "SOL",
    status: "breakout_detected",
    marketState: "buy_side_absorption",
    stateScore: 74,
    stateScoreChange: 6,
    quoteVolume24h: 1_234_567_890,
    price: 167.42,
    direction: "bullish",
    language: "tr",
  });
  assertEqual(title, "SOL · Alıcı absorpsiyonu", "title");
  assertEqual(body, "Güç 74/100 · Değişim +6 · 24s hacim $1.23B", "body");
  if (/risk/i.test(body)) throw new Error("risk must not appear in the body");
  if (/Rejim|Hazırlık|Kalite|Teyit/.test(body)) {
    throw new Error("legacy score layers must not appear in the body");
  }
});

Deno.test("the english body uses the same format", () => {
  const { body } = composeNotification({
    baseAsset: "SOL",
    status: "breakout_detected",
    marketState: "seller_impact_fading",
    stateScore: 68,
    stateScoreChange: -4,
    quoteVolume24h: 4_130_000,
    price: 0.001812,
    direction: "bullish",
    language: "en",
  });
  assertEqual(
    body,
    "Strength 68/100 · Change -4 · 24h volume $4.13M",
    "en body",
  );
});

Deno.test("an unmeasured state says it is updating", () => {
  const { body } = composeNotification({
    baseAsset: "SOL",
    status: "breakout_detected",
    marketState: null,
    stateScore: null,
    stateScoreChange: null,
    quoteVolume24h: 4_130_000,
    price: 0.001812,
    direction: "bullish",
    language: "tr",
  });
  assertEqual(
    body,
    "Güç ölçülüyor · İlk ölçüm · 24s hacim $4.13M",
    "unmeasured body",
  );
});

Deno.test("the title names the current state", () => {
  const { title } = composeNotification({
    baseAsset: "AVAX",
    status: "breakout_detected",
    marketState: "breakdown_risk",
    stateScore: 82,
    stateScoreChange: 9,
    quoteVolume24h: 42_000_000,
    price: 23.48,
    direction: "bearish",
    language: "en",
  });
  assertEqual(title, "AVAX · Breakdown risk", "state title");
});
