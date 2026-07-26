export const ROTATING_UNIVERSE_SIZE = 100;
export const ROTATING_BATCH_SIZE = 25;
export const ROTATING_BATCH_SLOTS = 4;

export function rotatingSlotForUTCMinute(minute: number): number {
  const normalized = ((Math.trunc(minute) % 60) + 60) % 60;
  return ((normalized % ROTATING_BATCH_SLOTS) + ROTATING_BATCH_SLOTS - 1) % ROTATING_BATCH_SLOTS;
}

export function rotatingBatch<T>(values: T[], slot: number): T[] {
  const safeSlot = Math.min(ROTATING_BATCH_SLOTS - 1, Math.max(0, Math.trunc(slot)));
  const start = safeSlot * ROTATING_BATCH_SIZE;
  return values.slice(start, start + ROTATING_BATCH_SIZE);
}
