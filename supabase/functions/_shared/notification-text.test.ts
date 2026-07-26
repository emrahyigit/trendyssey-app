import { composeNotification, formatPrice, formatVolume } from "./notification-text.ts";

function assertEqual(actual: unknown, expected: unknown, label: string): void {
  if (actual !== expected) {
    throw new Error(`${label}: expected ${JSON.stringify(expected)}, got ${JSON.stringify(actual)}`);
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

Deno.test("body carries strength out of 100, compact volume and labeled price", () => {
  const { title, body } = composeNotification({
    baseAsset: "SOL",
    status: "breakout_detected",
    confidence: 78.4,
    quoteVolume24h: 1_234_567_890,
    price: 167.42,
    direction: "bullish",
    language: "tr",
  });
  assertEqual(title, "SOL · Kırılım başladı", "title");
  assertEqual(body, "Güven 78/100 · Hacim $1.23B · Fiyat $167.42", "body");
  if (/risk/i.test(body)) throw new Error("risk must not appear in the body");
  if (/\dx\b/.test(body)) throw new Error("volume must not be a multiple");
});

Deno.test("the english body uses the same format", () => {
  const { body } = composeNotification({
    baseAsset: "SOL",
    status: "breakout_detected",
    confidence: 60,
    quoteVolume24h: 4_130_000,
    price: 0.001812,
    direction: "bullish",
    language: "en",
  });
  assertEqual(body, "Confidence 60/100 · Vol. $4.13M · Price $0.001812", "en body");
});

Deno.test("a bearish model reads as a breakdown", () => {
  const { title } = composeNotification({
    baseAsset: "AVAX",
    status: "breakout_detected",
    confidence: 61,
    quoteVolume24h: 42_000_000,
    price: 23.48,
    direction: "bearish",
    language: "en",
  });
  assertEqual(title, "AVAX · Breakdown started", "bearish title");
});
