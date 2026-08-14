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

Deno.test("body carries all four score layers", () => {
  const { title, body } = composeNotification({
    baseAsset: "SOL",
    status: "breakout_detected",
    regimeScore: 72,
    readinessScore: 84,
    breakoutQualityScore: 78.4,
    confirmationScore: 35,
    quoteVolume24h: 1_234_567_890,
    price: 167.42,
    direction: "bullish",
    language: "tr",
  });
  assertEqual(title, "SOL · Kırılım başladı", "title");
  assertEqual(
    body,
    "Rejim 72 · Hazırlık 84 · Kalite 78 · Teyit 35",
    "body",
  );
  if (/risk/i.test(body)) throw new Error("risk must not appear in the body");
  if (/\dx\b/.test(body)) throw new Error("volume must not be a multiple");
});

Deno.test("the english body uses the same format", () => {
  const { body } = composeNotification({
    baseAsset: "SOL",
    status: "breakout_detected",
    regimeScore: 55,
    readinessScore: 70,
    breakoutQualityScore: 60,
    confirmationScore: 35,
    quoteVolume24h: 4_130_000,
    price: 0.001812,
    direction: "bullish",
    language: "en",
  });
  assertEqual(
    body,
    "Regime 55 · Ready 70 · Quality 60 · Confirm 35",
    "en body",
  );
});

Deno.test("a bearish model reads as a breakdown", () => {
  const { title } = composeNotification({
    baseAsset: "AVAX",
    status: "breakout_detected",
    regimeScore: 50,
    readinessScore: 66,
    breakoutQualityScore: 61,
    confirmationScore: 35,
    quoteVolume24h: 42_000_000,
    price: 23.48,
    direction: "bearish",
    language: "en",
  });
  assertEqual(title, "AVAX · Breakdown started", "bearish title");
});
