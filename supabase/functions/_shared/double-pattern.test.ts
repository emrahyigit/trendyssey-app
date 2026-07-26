/**
 * Parity fixtures shared with the iOS harness. The expected values below were
 * produced by the Swift implementation (DoublePatternAnalyzer); if a change to
 * either side makes these fail, the app and the backend have drifted and users
 * will get pushes that disagree with what the app shows.
 *
 * Run with: deno test supabase/functions/_shared/double-pattern.test.ts
 */
import { analyze, type Candle, type Direction, patterns } from "./double-pattern.ts";

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
    shapes: "57-80",
    phase: "confirmed",
    confidence: 76,
    events: "pre_breakout>breakout_detected>confirmed",
  },
  {
    name: "a genuine retest scores higher than a straight breakout",
    closes: [...bottomPath, ...ramp(89.4, 86.3, 5), ...ramp(87.5, 93, 6)],
    direction: "bullish",
    shapes: "57-80",
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
    shapes: "57-80,110-133",
    phase: "confirmed",
    confidence: 76,
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
    shapes: "57-80",
    phase: "confirmed",
    confidence: 76,
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

function assertEqual(actual: unknown, expected: unknown, label: string): void {
  if (actual !== expected) {
    throw new Error(`${label}: expected ${JSON.stringify(expected)}, got ${JSON.stringify(actual)}`);
  }
}
