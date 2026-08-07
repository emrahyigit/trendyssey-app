/**
 * Fixtures for the pattern analyzer. The confidence values reflect the server
 * weights (volume 15, prior trend 5) after the strength-vs-BTC factor moved 10
 * points into the backend-appended ingredient list; the on-device Swift
 * analyzer keeps the old weights and is used only for the offline replay.
 *
 * Run with: deno test supabase/functions/_shared/double-pattern.test.ts
 */
import {
  analyze,
  type Candle,
  type Direction,
  patterns,
  patternScoreLayers,
} from "./double-pattern.ts";

function ramp(from: number, to: number, count: number): number[] {
  if (count <= 1) return [to];
  const step = (to - from) / (count - 1);
  return Array.from({ length: count }, (_, i) => from + step * i);
}

function makeCandles(closes: number[], wick = 0.2): Candle[] {
  const start = 1_700_000_000_000;
  return closes.map((close, index) => {
    const open = index === 0 ? close : closes[index - 1];
    return {
      openTime: new Date(start + index * 900_000),
      closeTime: new Date(start + index * 900_000 + 899_000),
      open,
      high: Math.max(open, close) + wick,
      low: Math.min(open, close) - wick,
      close,
      volume: 1000,
    };
  });
}

const bottomPath = [
  ...ramp(100, 84, 50),
  ...ramp(83.2, 78, 8),
  ...ramp(78.6, 86, 13),
  ...ramp(85.1, 78.3, 10),
  ...ramp(79.6, 90, 10),
];

const cases: Array<{
  name: string;
  closes: number[];
  direction: Direction;
  shapes: string;
  phase: string;
  confidence: number;
  events: string;
}> = [
  {
    name: "double bottom completes",
    closes: bottomPath,
    direction: "bullish",
    shapes: "57-81",
    phase: "confirmed",
    confidence: 74,
    events: "pre_breakout>breakout_detected>confirmed",
  },
  {
    name: "a genuine retest scores higher than a straight breakout",
    closes: [...bottomPath, ...ramp(89.4, 86.3, 5), ...ramp(87.5, 93, 6)],
    direction: "bullish",
    shapes: "57-81",
    phase: "confirmed",
    confidence: 83,
    events: "pre_breakout>breakout_detected>confirmed>retest>confirmed",
  },
  {
    name: "history keeps both shapes",
    closes: [
      ...bottomPath,
      ...ramp(89, 80, 12),
      ...ramp(79.4, 75, 8),
      ...ramp(75.6, 83, 13),
      ...ramp(82.1, 75.3, 10),
      ...ramp(76.6, 88, 10),
    ],
    direction: "bullish",
    shapes: "57-81,110-134",
    phase: "confirmed",
    confidence: 74,
    events:
      "pre_breakout>breakout_detected>confirmed>retest>failed>pre_breakout>breakout_detected>confirmed",
  },
  {
    name: "double top completes downward",
    closes: [
      ...ramp(80, 96, 50),
      ...ramp(96.8, 102, 8),
      ...ramp(101.4, 94, 13),
      ...ramp(94.9, 101.7, 10),
      ...ramp(100.4, 90, 10),
    ],
    direction: "bearish",
    shapes: "57-81",
    phase: "confirmed",
    confidence: 74,
    events: "pre_breakout>breakout_detected>confirmed",
  },
  {
    name: "a steady trend has no double bottom",
    closes: ramp(50, 90, 90),
    direction: "bullish",
    shapes: "",
    phase: "watching",
    confidence: 0,
    events: "",
  },
];

for (const testCase of cases) {
  Deno.test(testCase.name, () => {
    const candles = makeCandles(testCase.closes);
    const shapes = patterns(candles, testCase.direction)
      .map((p) => `${p.firstIndex}-${p.secondIndex}`)
      .join(",");
    const result = analyze(candles, testCase.direction);
    const events = result.events.map((e) => e.status).join(">");

    assertEqual(shapes, testCase.shapes, "patterns");
    assertEqual(result.phase, testCase.phase, "phase");
    assertEqual(result.confidence, testCase.confidence, "confidence");
    assertEqual(events, testCase.events, "events");
  });
}

Deno.test("pattern scores answer four independent lifecycle questions", () => {
  const candles = makeCandles(bottomPath);
  const complete = analyze(candles, "bullish");
  const preEvent = complete.events.find((event) => event.status === "pre_breakout")!;
  const breakoutEvent = complete.events.find((event) => event.status === "breakout_detected")!;
  const preIndex = candles.findIndex((candle) => candle.closeTime.getTime() === preEvent.time.getTime());
  const breakoutIndex = candles.findIndex((candle) => candle.closeTime.getTime() === breakoutEvent.time.getTime());

  const preCandles = candles.slice(0, preIndex + 1);
  const breakoutCandles = candles.slice(0, breakoutIndex + 1);
  const pre = patternScoreLayers(preCandles, analyze(preCandles, "bullish"), "bullish", 12);
  const breakout = patternScoreLayers(
    breakoutCandles,
    analyze(breakoutCandles, "bullish"),
    "bullish",
    12,
  );
  const confirmed = patternScoreLayers(candles, complete, "bullish", 12);

  assert(pre.readinessScore > 0, "a formed pattern must have readiness");
  assertEqual(pre.breakoutQualityScore, 0, "quality before trigger");
  assertEqual(pre.confirmationScore, 0, "confirmation before trigger");
  assert(breakout.breakoutQualityScore > 0, "the trigger candle must produce quality");
  assert(breakout.confirmationScore > 0, "the first held close starts confirmation");
  assert(
    confirmed.confirmationScore > breakout.confirmationScore,
    "post-trigger holding must raise confirmation",
  );
});

Deno.test("Double Top treats weakness versus BTC as directional alignment", () => {
  const closes = [
    ...ramp(80, 96, 50),
    ...ramp(96.8, 102, 8),
    ...ramp(101.4, 94, 13),
    ...ramp(94.9, 101.7, 10),
    ...ramp(100.4, 90, 10),
  ];
  const candles = makeCandles(closes);
  const result = analyze(candles, "bearish");
  const aligned = patternScoreLayers(candles, result, "bearish", 12);
  const opposed = patternScoreLayers(candles, result, "bearish", 3);
  assert(aligned.regimeScore > opposed.regimeScore, "bearish alignment must improve regime");
  assert(
    aligned.breakoutQualityScore > opposed.breakoutQualityScore,
    "bearish alignment must improve quality",
  );
});

function assertEqual(actual: unknown, expected: unknown, label: string): void {
  if (actual !== expected) {
    throw new Error(`${label}: expected ${JSON.stringify(expected)}, got ${JSON.stringify(actual)}`);
  }
}

function assert(condition: boolean, label: string): void {
  if (!condition) throw new Error(label);
}
