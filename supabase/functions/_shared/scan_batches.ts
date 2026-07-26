/** The scan covers exactly the 100 highest-volume USDT pairs. */
export const SCAN_UNIVERSE_SIZE = 100;
export const SCAN_BATCH_SIZE = 25;
export const SCAN_BATCH_SLOTS = 4;

export function scanBatch<T>(values: T[], slot: number): T[] {
  const safeSlot = Math.min(SCAN_BATCH_SLOTS - 1, Math.max(0, Math.trunc(slot)));
  const start = safeSlot * SCAN_BATCH_SIZE;
  return values.slice(start, start + SCAN_BATCH_SIZE);
}
