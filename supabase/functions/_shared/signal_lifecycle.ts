// EMA 7/25/99 crossover journey — the exact state machine the app runs on
// device (Swift EMAJourneyAnalyzer), so lists, notifications and the detail
// page always agree on the phase.
// deno-lint-ignore-file no-explicit-any

export function nextSignalState(previous: string, analysis: any, _trackedLevel: number, _journeyAge: number, isNewCandle: boolean): string {
  if (!isNewCandle) return previous;
  const inJourney = previous === "breakout_detected" || previous === "retest" || previous === "confirmed";
  if (inJourney) {
    if (analysis.crossedDown) return "failed";
    if (analysis.closedBelowSupportBand) {
      // Two consecutive closes below the EMA 25 band invalidate the move;
      // a single close counts as the level being tested.
      if (analysis.previousClosedBelowSupportBand) return "failed";
      return previous === "retest" ? previous : "retest";
    }
    if (previous === "breakout_detected" && analysis.touchedSupport) return "retest";
    if (previous === "retest" && analysis.current.close > analysis.emaFast) return "confirmed";
    if (previous === "breakout_detected" && (analysis.emaCrossAge >= 3 || analysis.emaCrossAge < 0) && analysis.heldAboveSupport3) return "confirmed";
    return previous;
  }
  // watching / pre_breakout / failed / expired
  if (analysis.crossedUp) return "breakout_detected";
  if (analysis.emaFast > analysis.emaSlow && analysis.current.close > analysis.emaFast) {
    // The uptrend survived a soft failure without a cross-down; a strong close
    // above both EMAs restarts the journey.
    return "breakout_detected";
  }
  if (analysis.emaFast < analysis.emaSlow) {
    // Enter pre-breakout below a 0.4% narrowing gap; leave only above 0.8%.
    if (previous === "pre_breakout") {
      return analysis.preBreakoutGap > 0.008 ? "watching" : "pre_breakout";
    }
    return analysis.preBreakoutGap < 0.004 && analysis.preBreakoutGap < analysis.previousPreBreakoutGap ? "pre_breakout" : "watching";
  }
  return "watching";
}
